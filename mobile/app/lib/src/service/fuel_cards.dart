import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';

/// Wybór pliku CSV: nazwa i zawartość; `null` – anulowano.
typedef CsvPicker = Future<(String, List<int>)?> Function(String label);

Future<(String, List<int>)?> pickCsvFile(String label) async {
  final file = await FileSelectorPlatform.instance.openFile(acceptedTypeGroups: [
    XTypeGroup(label: label, extensions: const ['csv', 'CSV', 'txt', 'TXT']),
  ]);
  if (file == null) return null;
  return (file.name, await file.readAsBytes());
}

/// Tankowania z kart paliwowych (`/api/companies/{id}/fuel-cards/…`).
class FuelCardsApi {
  const FuelCardsApi(this.api, this.companyId);

  final CoreApi api;
  final String companyId;

  String get _base => '/api/companies/${Uri.encodeComponent(companyId)}/fuel-cards';

  Future<Map<String, dynamic>> summary({int months = 3}) async =>
      await api.get('$_base/summary?months=$months') as Map<String, dynamic>;

  Future<Map<String, dynamic>> import(String name, List<int> bytes, {String? vehicleId}) async =>
      await api.post('$_base/import', {
        'name': name,
        'data': base64Encode(bytes),
        if (vehicleId != null) 'vehicle_id': vehicleId,
      }) as Map<String, dynamic>;
}

/// Kwoty w walutach, np. "2 524,56 PLN + 1 050,40 EUR".
String fuelAmounts(AppLocalizations l, Object? amounts) {
  final map = (amounts as Map?)?.cast<String, dynamic>() ?? const {};
  if (map.isEmpty) return '–';
  final format = NumberFormat('#,##0.00', l.localeName);
  return [for (final e in map.entries) '${format.format(e.value as num)} ${e.key}'].join(' + ');
}

/// Wczytanie wyciągu: wybór pliku, wysłanie, komunikat z wynikiem. `true` – wczytano.
Future<bool> importFuelCsv(BuildContext context, CoreApi api, String companyId, {CsvPicker? picker}) async {
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  (String, List<int>)? picked;
  try {
    picked = await (picker ?? pickCsvFile)(l.fuelFileType);
  } catch (_) {
    messenger?.showSnackBar(SnackBar(content: Text(l.fuelPickFailed)));
    return false;
  }
  if (picked == null) return false;
  try {
    final r = await FuelCardsApi(api, companyId).import(picked.$1, picked.$2);
    final unmatched = (r['unmatched'] as List? ?? const []).join(', ');
    messenger?.showSnackBar(SnackBar(
        content: Text([
      l.fuelImported((r['imported'] as num? ?? 0).toInt(), (r['duplicates'] as num? ?? 0).toInt(),
          (r['skipped'] as num? ?? 0).toInt()),
      if (unmatched.isNotEmpty) l.fuelUnmatched(unmatched),
    ].join('\n'))));
    return true;
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('$e')));
    return false;
  }
}

/// Skrót w filtrach TCO: liczba tankowań, litry i kwota z kart z okresu.
class FuelCardsSummary extends StatefulWidget {
  const FuelCardsSummary({
    super.key,
    required this.api,
    required this.companyId,
    required this.months,
    this.stats = const {},
    this.picker,
    this.onChanged,
  });

  final CoreApi api;
  final String? companyId;
  final int months;

  /// Po zamknięciu okna (mógł być import) – np. przeliczenie struktury kosztów.
  final VoidCallback? onChanged;

  /// Statystyki przejazdów pojazdów (`distance_km`) – do spalania l/100 km.
  final Map<String, Map<String, dynamic>> stats;
  final CsvPicker? picker;

  @override
  State<FuelCardsSummary> createState() => _FuelCardsSummaryState();
}

class _FuelCardsSummaryState extends State<FuelCardsSummary> {
  Map<String, dynamic>? _summary;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FuelCardsSummary old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId || old.months != widget.months) _load();
  }

  Future<void> _load() async {
    final company = widget.companyId;
    if (company == null) return;
    try {
      final summary = await FuelCardsApi(widget.api, company).summary(months: widget.months);
      if (mounted) setState(() => _summary = summary);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _open() async {
    final company = widget.companyId;
    if (company == null) return;
    await showDialog<void>(
      context: context,
      builder: (context) => _FuelCardsDialog(
        api: widget.api,
        companyId: company,
        months: widget.months,
        stats: widget.stats,
        picker: widget.picker,
        initial: _summary,
      ),
    );
    await _load();
    widget.onChanged?.call();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final s = _summary;
    final count = (s?['count'] as num? ?? 0).toInt();
    final text = _failed || widget.companyId == null
        ? '–'
        : s == null
            ? '…'
            : count == 0
                ? l.fuelNoneShort
                : l.fuelSummary(count, l.number(s['liters'] as num? ?? 0, decimals: 0), fuelAmounts(l, s['amount']));
    return InkWell(
      key: const Key('fuel-cards'),
      onTap: widget.companyId == null ? null : _open,
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

class _FuelCardsDialog extends StatefulWidget {
  const _FuelCardsDialog({
    required this.api,
    required this.companyId,
    required this.months,
    required this.stats,
    this.picker,
    this.initial,
  });

  final CoreApi api;
  final String companyId;
  final int months;
  final Map<String, Map<String, dynamic>> stats;
  final CsvPicker? picker;
  final Map<String, dynamic>? initial;

  @override
  State<_FuelCardsDialog> createState() => _FuelCardsDialogState();
}

class _FuelCardsDialogState extends State<_FuelCardsDialog> {
  late Map<String, dynamic>? _summary = widget.initial;
  bool _busy = false;

  Future<void> _import() async {
    setState(() => _busy = true);
    final done = await importFuelCsv(context, widget.api, widget.companyId, picker: widget.picker);
    if (done) {
      try {
        final summary = await FuelCardsApi(widget.api, widget.companyId).summary(months: widget.months);
        if (mounted) setState(() => _summary = summary);
      } catch (_) {}
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final vehicles = uiMaps(_summary?['vehicles']);
    final day = DateFormat.yMd(l.localeName);
    String consumption(Map<String, dynamic> v) {
      final km = widget.stats['${v['vehicle_id']}']?['distance_km'] as num?;
      final liters = v['liters'] as num? ?? 0;
      if (km == null || km <= 0 || liters <= 0) return '–';
      return l.number(liters / km * 100, decimals: 1);
    }

    return AlertDialog(
      title: Text(l.fuelTitle),
      content: SizedBox(
        width: 720,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(l.fuelFormats, style: theme.textTheme.bodySmall),
            const SizedBox(height: Gap.m),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                key: const Key('fuel-import'),
                onPressed: _busy ? null : _import,
                icon: _busy
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.upload_file_outlined, size: 18),
                label: Text(l.fuelImport),
              ),
            ),
            const SizedBox(height: Gap.m),
            if (vehicles.isEmpty)
              UiEmpty(l.fuelNone)
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(columnSpacing: Gap.l, columns: [
                  DataColumn(label: Text(l.fuelColVehicle)),
                  DataColumn(label: Text(l.fuelColCount), numeric: true),
                  DataColumn(label: Text(l.fuelColLiters), numeric: true),
                  DataColumn(label: Text(l.fuelColAdblue), numeric: true),
                  DataColumn(label: Text(l.fuelColConsumption), numeric: true),
                  DataColumn(label: Text(l.fuelColAmount), numeric: true),
                  DataColumn(label: Text(l.fuelColLast)),
                ], rows: [
                  for (final v in vehicles)
                    DataRow(cells: [
                      DataCell(Text(v['vehicle_id'] == null ? l.fuelNoVehicle : '${v['plate'] ?? '–'}')),
                      DataCell(Text('${v['count']}')),
                      DataCell(Text(l.number(v['liters'] as num? ?? 0, decimals: 1))),
                      DataCell(Text(l.number(v['adblue_liters'] as num? ?? 0, decimals: 1))),
                      DataCell(Text(consumption(v))),
                      DataCell(Text(fuelAmounts(l, v['amount']))),
                      DataCell(Text(DateTime.tryParse('${v['last']}') == null
                          ? '–'
                          : day.format(DateTime.parse('${v['last']}').toLocal()))),
                    ]),
                ]),
              ),
          ]),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(l.fuelClose))],
    );
  }
}
