import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../dashboard/main_dashboard.dart' show uiMaps;
import '../l10n.dart';

const _towed = {'semitrailer', 'trailer'};
const openStatuses = {'new', 'accepted', 'in_progress'};

/// Dane warsztatu i analityki: pojazdy firmy, zlecenia modułu Serwis (`null` – moduł nieaktywny),
/// statystyki przejazdów pojazdów (opcjonalnie) i kierowcy modułu Kierowcy (opcjonalnie).
class FleetData {
  FleetData({required this.vehicles, required this.orders, this.stats = const {}, this.drivers});

  final List<Map<String, dynamic>> vehicles;
  final List<Map<String, dynamic>>? orders;

  /// id pojazdu → `VehicleStats` (`/api/vehicles/{id}/stats`).
  final Map<String, Map<String, dynamic>> stats;

  /// Kierowcy z modułu (każdy z polem `stats`); `null` – moduł nieaktywny.
  final List<Map<String, dynamic>>? drivers;

  static Future<FleetData> load(CoreApi api, String? companyId,
      {bool withStats = false, bool withDrivers = false, int months = 6}) async {
    Future<dynamic> optional(String path) async {
      try {
        return await api.get(path);
      } catch (_) {
        return null;
      }
    }

    final vehicles = [
      for (final v in uiMaps(await api.get('/api/vehicles')))
        if (v['company_id'] == companyId) v
    ];
    final ids = {for (final v in vehicles) v['id']};
    final orders = await optional('/api/m/service/orders');
    final stats = <String, Map<String, dynamic>>{};
    if (withStats) {
      final power = [
        for (final v in vehicles)
          if (!_towed.contains(v['kind'])) '${v['id']}'
      ];
      final results = await Future.wait([for (final id in power) optional('/api/vehicles/$id/stats?months=$months')]);
      for (final (i, r) in results.indexed) {
        if (r is Map<String, dynamic>) stats[power[i]] = r;
      }
    }
    List<Map<String, dynamic>>? drivers;
    if (withDrivers && companyId != null) {
      final list = await optional('/api/m/drivers/drivers?company_id=${Uri.encodeQueryComponent(companyId)}');
      if (list is List) {
        drivers = uiMaps(list);
        final results = await Future.wait(
            [for (final d in drivers) optional('/api/m/drivers/drivers/${d['id']}/stats?months=$months')]);
        drivers = [
          for (final (i, d) in drivers.indexed) {...d, 'stats': results[i] is Map ? results[i] : null}
        ];
      }
    }
    return FleetData(
      vehicles: vehicles,
      orders: orders is List
          ? [
              for (final o in uiMaps(orders))
                if (ids.contains(o['vehicle_id'])) o
            ]
          : null,
      stats: stats,
      drivers: drivers,
    );
  }

  List<Map<String, dynamic>> get power => [
        for (final v in vehicles)
          if (!_towed.contains(v['kind'])) v
      ];

  Map<String, dynamic>? vehicle(dynamic id) => vehicles.where((v) => v['id'] == id).firstOrNull;

  List<Map<String, dynamic>> get open => [
        for (final o in orders ?? const [])
          if (openStatuses.contains(o['status'])) o
      ];
  List<Map<String, dynamic>> get done => [
        for (final o in orders ?? const [])
          if (o['status'] == 'done') o
      ];
}

DateTime? day(dynamic s) => s == null ? null : DateTime.tryParse('$s')?.toLocal();

/// Numer zlecenia do pokazania (WO-xxxxxx z id).
String orderNo(Map<String, dynamic> o) => 'WO-${'${o['id']}'.replaceAll('-', '').substring(0, 6).toUpperCase()}';

double partsTotal(Map<String, dynamic> o) => [
      for (final p in uiMaps(o['parts'])) ((p['price'] as num?) ?? 0) * ((p['quantity'] as num?) ?? 1)
    ].fold(0.0, (a, b) => a + b);

double labourTotal(Map<String, dynamic> o) =>
    ((o['labour_hours'] as num?) ?? 0).toDouble() * ((o['labour_rate'] as num?) ?? 0).toDouble();

double orderTotal(Map<String, dynamic> o) => partsTotal(o) + labourTotal(o);

/// Postęp zlecenia według statusu (bez czujników – etapy pracy).
double orderProgress(dynamic status) => switch (status) {
      'new' => 0.1,
      'accepted' => 0.35,
      'in_progress' => 0.65,
      'done' => 1.0,
      _ => 0.0,
    };

String orderStatus(AppLocalizations l, dynamic status) => switch (status) {
      'new' => l.wsStatusNew,
      'accepted' => l.wsStatusAccepted,
      'in_progress' => l.wsStatusProgress,
      'done' => l.wsStatusDone,
      'rejected' => l.wsStatusRejected,
      _ => '$status',
    };

/// Suma kosztów tras ze statystyk (waluta → kwota; pokazujemy PLN, inaczej pierwszą).
double tripCosts(Map<String, dynamic>? stats) {
  final costs = (stats?['costs'] as Map?) ?? const {};
  final pln = costs['PLN'];
  if (pln is num) return pln.toDouble();
  return costs.values.whereType<num>().fold(0.0, (a, b) => a + b);
}

/// Słupki miesięczne (wartości ≥ 0) z podpisami – proste wykresy bez dodatkowych pakietów.
class MiniBars extends StatelessWidget {
  const MiniBars({super.key, required this.labels, required this.series, this.height = 150});

  final List<String> labels;

  /// (kolor, wartości po kolei dla [labels]).
  final List<(Color, List<double>)> series;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final top = [for (final (_, v) in series) ...v].fold(0.0, (a, b) => a > b ? a : b);
    return SizedBox(
      height: height + 22,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final (i, label) in labels.indexed)
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final (color, values) in series)
                  Container(
                    width: 14,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    height: top == 0 ? 2 : (values[i] / top * height).clamp(2, height),
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
                  ),
              ]),
              const SizedBox(height: 4),
              Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
            ]),
          ),
      ]),
    );
  }
}
