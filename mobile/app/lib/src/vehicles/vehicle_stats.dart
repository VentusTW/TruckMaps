import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';

/// Statystyki pojazdu z zapisanych przejazdów: razem i w miesiącach (km, godziny, koszt).
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

  Future<dynamic> _load() => widget.api.get('/api/vehicles/${widget.vehicle['id']}/stats?months=$_months');

  String _money(AppLocalizations l, Map<String, dynamic> costs) =>
      costs.isEmpty ? '–' : costs.entries.map((e) => l.money((e.value as num).toDouble(), e.key)).join(' + ');

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    String km(num value) => NumberFormat.decimalPattern(l.localeName).format(value.round());
    return Scaffold(
      appBar: AppBar(title: Text(l.vehicleStatsTitle('${widget.vehicle['name']}'))),
      body: FutureBuilder<dynamic>(
        future: _stats,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${snapshot.error}'),
                TextButton(onPressed: () => setState(() => _stats = _load()), child: Text(l.retry)),
              ]),
            );
          }
          if (!snapshot.hasData) return const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator());
          final s = snapshot.data as Map<String, dynamic>;
          final perKm = (s['cost_per_km'] as Map<String, dynamic>? ?? {});
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
              }),
            ),
            const SizedBox(height: 12),
            if (s['trips'] == 0) Text(l.vehicleStatsEmpty),
            if (s['trips'] != 0) ...[
              Wrap(spacing: 12, runSpacing: 12, children: [
                for (final (label, value) in [
                  (l.vehicleStatsKm, '${km(s['distance_km'] as num)} km'),
                  (l.vehicleStatsTrips, '${s['trips']}'),
                  (l.vehicleStatsHours, l.number(s['hours'] as num, decimals: 1)),
                  (l.vehicleStatsDrivers, '${s['drivers']}'),
                  (l.vehicleStatsCost, _money(l, s['costs'] as Map<String, dynamic>)),
                  if (perKm.isNotEmpty)
                    (
                      l.vehicleStatsCostPerKm,
                      perKm.entries.map((e) => '${l.number(e.value as num, decimals: 2)} ${e.key}').join(' · ')
                    ),
                ])
                  SizedBox(
                    width: 170,
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(label, style: theme.textTheme.bodySmall),
                          Text(value, style: theme.textTheme.titleMedium),
                        ]),
                      ),
                    ),
                  ),
              ]),
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
