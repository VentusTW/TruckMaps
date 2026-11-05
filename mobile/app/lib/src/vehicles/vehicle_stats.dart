import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import 'service_dates.dart' show towedKinds;

/// Statystyki pojazdu z zapisanych przejazdów: razem i w miesiącach (km, puste km, godziny,
/// przestoje, koszt), kierowcy, naczepy (dla naczepy – pojazdy, które ją ciągnęły),
/// porównanie z poprzednim okresem i koszty napraw z modułu Serwis (gdy jest wykupiony).
class VehicleStatsScreen extends StatefulWidget {
  const VehicleStatsScreen({super.key, required this.api, required this.vehicle});

  final CoreApi api;
  final Map<String, dynamic> vehicle;

  @override
  State<VehicleStatsScreen> createState() => _VehicleStatsScreenState();
}

class _VehicleStatsScreenState extends State<VehicleStatsScreen> {
  int _months = 12;
  late Future<dynamic> _stats = _load();
  late Future<List<dynamic>?> _repairs = _loadRepairs();

  Future<dynamic> _load() => widget.api.get('/api/vehicles/${widget.vehicle['id']}/stats?months=$_months');

  /// Koszty napraw z Serwisu w tym samym okresie; bez modułu (albo bez dostępu) – brak.
  Future<List<dynamic>?> _loadRepairs() async {
    final since = DateTime.now().subtract(Duration(days: 31 * _months));
    final day = DateFormat('yyyy-MM-dd').format(since);
    try {
      return await widget.api.get('/api/m/service/costs?vehicle_id=${widget.vehicle['id']}&date_from=$day')
          as List<dynamic>;
    } catch (_) {
      return null;
    }
  }

  String _money(AppLocalizations l, Map<String, dynamic> costs) =>
      costs.isEmpty ? '–' : costs.entries.map((e) => l.money((e.value as num).toDouble(), e.key)).join(' + ');

  /// Zmiana względem poprzedniego okresu: „+12%”, „−5%”.
  String? _change(num now, num? before) {
    if (before == null || before == 0) return null;
    final percent = ((now - before) / before * 100).round();
    return '${percent > 0 ? '+' : percent < 0 ? '−' : '±'}${percent.abs()}%';
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final towed = towedKinds.contains(widget.vehicle['kind']);
    String km(num value) => NumberFormat.decimalPattern(l.localeName).format(value.round());
    Widget card(String label, String value, {String? note}) => SizedBox(
          width: 170,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: theme.textTheme.bodySmall),
                Text(value, style: theme.textTheme.titleMedium),
                if (note != null) Text(note, style: theme.textTheme.bodySmall),
              ]),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: Text(l.vehicleStatsTitle('${widget.vehicle['name']}'))),
      body: FutureBuilder<dynamic>(
        future: _stats,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${snapshot.error}'),
                TextButton(
                    onPressed: () => setState(() {
                          _stats = _load();
                        }),
                    child: Text(l.retry)),
              ]),
            );
          }
          if (!snapshot.hasData) return const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator());
          final s = snapshot.data as Map<String, dynamic>;
          final perKm = (s['cost_per_km'] as Map<String, dynamic>? ?? {});
          final previous = s['previous'] as Map<String, dynamic>?;
          final share = s['empty_share'] as num?;
          final drivers = (s['by_driver'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
          final linked = (s['linked'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
          return ListView(padding: const EdgeInsets.all(16), children: [
            SegmentedButton<int>(
              segments: [
                for (final months in const [3, 12, 36])
                  ButtonSegment(value: months, label: Text(l.vehicleStatsMonths(months))),
              ],
              selected: {_months},
              onSelectionChanged: (value) => setState(() {
                _months = value.first;
                _stats = _load();
                _repairs = _loadRepairs();
              }),
            ),
            const SizedBox(height: 12),
            if (s['trips'] == 0) Text(l.vehicleStatsEmpty),
            if (s['trips'] != 0) ...[
              Wrap(spacing: 12, runSpacing: 12, children: [
                card(l.vehicleStatsKm, '${km(s['distance_km'] as num)} km',
                    note: _change(s['distance_km'] as num, previous?['distance_km'] as num?)
                        ?.let((c) => l.vehicleStatsVsPrevious(c))),
                card(l.vehicleStatsTrips, '${s['trips']}',
                    note: _change(s['trips'] as num, previous?['trips'] as num?)
                        ?.let((c) => l.vehicleStatsVsPrevious(c))),
                card(l.vehicleStatsHours, l.number(s['hours'] as num, decimals: 1)),
                card(l.vehicleStatsEmptyKm, '${km(s['empty_km'] as num? ?? 0)} km',
                    note: share == null ? l.vehicleStatsEmptyUnknown : '${(share * 100).round()}%'),
                card(l.vehicleStatsIdle, l.number(s['idle_hours'] as num? ?? 0, decimals: 1)),
                card(l.vehicleStatsDrivers, '${s['drivers']}'),
                card(l.vehicleStatsCost, _money(l, s['costs'] as Map<String, dynamic>)),
                if (perKm.isNotEmpty)
                  card(l.vehicleStatsCostPerKm,
                      perKm.entries.map((e) => '${l.number(e.value as num, decimals: 2)} ${e.key}').join(' · ')),
              ]),
              FutureBuilder<List<dynamic>?>(
                future: _repairs,
                builder: (context, repairs) {
                  final rows = (repairs.data ?? const []).cast<Map<String, dynamic>>();
                  if (rows.isEmpty) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Wrap(spacing: 12, runSpacing: 12, children: [
                      card(
                        l.vehicleStatsRepairs,
                        rows
                            .map((r) =>
                                l.money(((r['total'] ?? r['parts_total']) as num).toDouble(), '${r['currency'] ?? ''}'))
                            .join(' + '),
                        note: l.vehicleStatsRepairOrders(rows.fold<int>(0, (n, r) => n + (r['orders'] as int))),
                      ),
                    ]),
                  );
                },
              ),
              if (drivers.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(l.vehicleStatsByDriver, style: theme.textTheme.titleSmall),
                for (final d in drivers)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text('${d['name']}'),
                    subtitle: Text(l.vehicleStatsShareLine(km(d['distance_km'] as num), d['trips'] as int)),
                  ),
              ],
              if (linked.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(towed ? l.vehicleStatsTowedBy : l.vehicleStatsTrailers, style: theme.textTheme.titleSmall),
                for (final v in linked)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(towed ? Icons.local_shipping_outlined : Icons.rv_hookup),
                    title: Text('${v['name']}'),
                    subtitle: Text(l.vehicleStatsShareLine(km(v['distance_km'] as num), v['trips'] as int)),
                  ),
              ],
              const SizedBox(height: 16),
              Text(l.vehicleStatsByMonth, style: theme.textTheme.titleSmall),
              for (final m in (s['months'] as List<dynamic>).cast<Map<String, dynamic>>())
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.calendar_month_outlined),
                  title: Text(DateFormat.yMMMM(l.localeName).format(DateTime.parse('${m['month']}-01'))),
                  subtitle: Text(l.vehicleStatsMonthLine(km(m['distance_km'] as num), m['trips'] as int,
                      l.number(m['hours'] as num, decimals: 1), _money(l, m['costs'] as Map<String, dynamic>))),
                ),
            ],
            const SizedBox(height: 8),
            Text(l.vehicleStatsHint, style: theme.textTheme.bodySmall),
          ]);
        },
      ),
    );
  }
}

extension on String {
  T let<T>(T Function(String) f) => f(this);
}
