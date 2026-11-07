import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import 'body_types.dart';

/// Rodzaje z zabudową (plandeka, chłodnia, cysterna…) – jak na serwerze.
const bodyKinds = {'combination', 'rigid', 'van', 'semitrailer', 'trailer'};

/// Rodzaje z tachografem (dostawczy do 3,5 t go nie ma) – jak na serwerze.
const tachographKinds = {'combination', 'rigid', 'tractor', 'bus'};

/// Rodzaje bez silnika (naczepa, przyczepa) – bez licznika, spalania i OCP.
const towedKinds = {'semitrailer', 'trailer'};

/// Terminy przeglądów i badań (pola na serwerze), w kolejności na ekranie.
const serviceDateKeys = [
  'last_inspection',
  'inspection_until',
  'insurance_until',
  'ac_until',
  'ocp_until',
  'udt_until',
  'tachograph_until',
  'tdt_until',
  'adr_until',
  'atp_until',
  'tachograph_download_until',
  'leasing_until',
];

/// Dane z tachografu pojazdu pobiera się co najmniej co 90 dni.
const tachographDownloadDays = 90;

/// Ile dni przed terminem pokazujemy ostrzeżenie.
const dueSoonDays = 30;

/// Ile km przed serwisem według przebiegu pokazujemy ostrzeżenie.
const serviceSoonKm = 2000;

/// Stan licznika i następny serwis (pola liczbowe obok terminów, tylko pojazdy z silnikiem).
const mileageKeys = ['odometer_km', 'service_due_km'];

String mileageLabel(AppLocalizations l, String key) =>
    key == 'odometer_km' ? l.vehicleOdometer : l.vehicleServiceDueKm;

/// Serwis według przebiegu: ile km zostało (ujemne – po terminie); `null`, gdy daleko albo brak danych.
int? serviceKmLeft(Map<String, dynamic> vehicle) {
  final odometer = vehicle['odometer_km'], due = vehicle['service_due_km'];
  if (odometer is! num || due is! num) return null;
  final left = (due - odometer).round();
  return left > serviceSoonKm ? null : left;
}

String serviceDateLabel(AppLocalizations l, String key) => switch (key) {
      'last_inspection' => l.vehicleLastInspection,
      'inspection_until' => l.vehicleInspectionUntil,
      'insurance_until' => l.vehicleInsuranceUntil,
      'ac_until' => l.vehicleAcUntil,
      'ocp_until' => l.vehicleOcpUntil,
      'udt_until' => l.vehicleUdtUntil,
      'tachograph_until' => l.vehicleTachographUntil,
      'tdt_until' => l.vehicleTdtUntil,
      'atp_until' => l.vehicleAtpUntil,
      'tachograph_download_until' => l.vehicleTachographDownloadUntil,
      'leasing_until' => l.vehicleLeasingUntil,
      _ => l.vehicleAdrUntil,
    };

/// Które terminy dotyczą pojazdu: tachograf – pojazdy z tachografem, TDT – cysterny, ATP – chłodnie, ADR – z ADR.
bool serviceDateApplies(String key, {required String kind, required String body, required bool hazmat}) =>
    switch (key) {
      'tachograph_until' || 'tachograph_download_until' => tachographKinds.contains(kind),
      'atp_until' => bodyKinds.contains(kind) && atpBodies.contains(body),
      'tdt_until' => bodyKinds.contains(kind) && tankBodies.contains(body),
      'adr_until' => hazmat,
      'ocp_until' => !towedKinds.contains(kind),
      _ => true,
    };

DateTime? parseDate(Object? value) => value is String ? DateTime.tryParse(value) : null;

String isoDate(DateTime day) => DateFormat('yyyy-MM-dd').format(day);

/// Najpilniejszy termin „ważny do” pojazdu: po terminie albo w ciągu [dueSoonDays] dni.
({String key, DateTime day, bool overdue})? mostUrgent(Map<String, dynamic> vehicle, {DateTime? today}) {
  final now = DateUtils.dateOnly(today ?? DateTime.now());
  ({String key, DateTime day, bool overdue})? found;
  for (final key in serviceDateKeys.skip(1)) {
    final day = parseDate(vehicle[key]);
    if (day == null || day.difference(now).inDays > dueSoonDays) continue;
    if (found == null || day.isBefore(found.day)) found = (key: key, day: day, overdue: day.isBefore(now));
  }
  return found;
}

/// Pole daty z kalendarzem i przyciskiem wyczyszczenia.
/// Skrót przy terminie: pobranie danych z tachografu „dziś” → następne za 90 dni.
({String label, DateTime Function() day})? serviceDateShortcut(AppLocalizations l, String key) =>
    key == 'tachograph_download_until'
        ? (
            label: l.vehicleTachographDownloaded,
            day: () => DateUtils.dateOnly(DateTime.now()).add(const Duration(days: tachographDownloadDays)),
          )
        : null;

class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChanged, this.shortcut});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final ({String label, DateTime Function() day})? shortcut;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Future<void> pick() async {
      final now = DateTime.now();
      final chosen = await showDatePicker(
        context: context,
        initialDate: value ?? now,
        firstDate: DateTime(now.year - 30),
        lastDate: DateTime(now.year + 15),
      );
      if (chosen != null) onChanged(chosen);
    }

    final field = InkWell(
      onTap: pick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: value == null
              ? const Icon(Icons.event_outlined)
              : IconButton(tooltip: l.vehicleDateClear, icon: const Icon(Icons.clear), onPressed: () => onChanged(null)),
        ),
        child: Text(value == null ? l.vehicleDateNone : DateFormat.yMd(l.localeName).format(value!)),
      ),
    );
    final quick = shortcut;
    if (quick == null) return field;
    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
      field,
      TextButton.icon(
        onPressed: () => onChanged(quick.day()),
        icon: const Icon(Icons.download_done_outlined, size: 18),
        label: Text(quick.label),
      ),
    ]);
  }
}

/// Same terminy przeglądów i badań – dla mechanika (i każdego, kto może je zmieniać).
class ServiceDatesScreen extends StatefulWidget {
  const ServiceDatesScreen({super.key, required this.api, required this.vehicle});

  final CoreApi api;
  final Map<String, dynamic> vehicle;

  @override
  State<ServiceDatesScreen> createState() => _ServiceDatesScreenState();
}

class _ServiceDatesScreenState extends State<ServiceDatesScreen> {
  late final Map<String, DateTime?> _dates = {for (final k in serviceDateKeys) k: parseDate(widget.vehicle[k])};
  late final Map<String, TextEditingController> _km = {
    for (final k in mileageKeys) k: TextEditingController(text: '${widget.vehicle[k] ?? ''}'),
  };

  @override
  void dispose() {
    for (final c in _km.values) {
      c.dispose();
    }
    super.dispose();
  }
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.api.put('/api/vehicles/${widget.vehicle['id']}/service', {
        for (final e in _dates.entries) e.key: e.value == null ? null : isoDate(e.value!),
        if (!towedKinds.contains(widget.vehicle['kind']))
          for (final e in _km.entries) e.key: int.tryParse(e.value.text),
      });
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = widget.vehicle;
    final keys = [
      for (final k in serviceDateKeys)
        if (serviceDateApplies(k,
            kind: '${v['kind']}', body: '${v['trailer_type']}', hazmat: v['hazmat'] == true))
          k,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l.vehicleDatesTitle('${v['name']}'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final key in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DateField(
              label: serviceDateLabel(l, key),
              value: _dates[key],
              onChanged: (day) => setState(() => _dates[key] = day),
              shortcut: serviceDateShortcut(l, key),
            ),
          ),
        if (!towedKinds.contains(v['kind']))
          for (final key in mileageKeys)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: TextField(
                controller: _km[key],
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                    labelText: mileageLabel(l, key), suffixText: 'km', border: const OutlineInputBorder(), isDense: true),
              ),
            ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_busy ? l.saving : l.save),
        ),
      ]),
    );
  }
}
