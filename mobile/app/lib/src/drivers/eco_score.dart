import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';

/// Składnik oceny: `share` – udział (kursy puste, bezczynność) albo spalanie l/100 km.
typedef EcoPart = ({String key, double value, double points, double max});

/// Przybliżona ocena eco 0–100 z przejazdów kierowcy (`/api/m/drivers/drivers/{id}/stats`)
/// i deklarowanego spalania prowadzonych pojazdów – bez telematyki (CAN):
/// kursy puste (40 pkt, 0% → pełne, ≥40% → 0), bezczynność w czasie przejazdów (35 pkt, ≥30% → 0)
/// i spalanie z ładunkiem ważone km (25 pkt, ≤25 l → pełne, ≥40 l → 0). Brak danych składnika –
/// pomijany, wynik przeskalowany. `null` – brak przejazdów.
({int score, List<EcoPart> parts})? ecoScore(Map<String, dynamic> stats, List<Map<String, dynamic>> vehicles) {
  double n(Object? v) => ((v as num?) ?? 0).toDouble();
  double clamp01(double v) => v.clamp(0.0, 1.0).toDouble();
  final km = n(stats['distance_km']);
  if (km <= 0) return null;
  final parts = <EcoPart>[];
  final empty = clamp01(n(stats['empty_km']) / km);
  parts.add((key: 'empty', value: empty, points: 40 * clamp01(1 - empty / 0.4), max: 40));
  final hours = n(stats['hours']);
  if (hours > 0) {
    final idle = clamp01(n(stats['idle_hours']) / hours);
    parts.add((key: 'idle', value: idle, points: 35 * clamp01(1 - idle / 0.3), max: 35));
  }
  var litres = 0.0, burnKm = 0.0;
  for (final s in uiMaps(stats['by_vehicle'])) {
    final v = vehicles.where((v) => v['id'] == s['vehicle_id']).firstOrNull;
    final burn = v?['consumption_loaded'];
    final d = n(s['distance_km']);
    if (burn is num && burn > 0 && d > 0) {
      litres += burn * d;
      burnKm += d;
    }
  }
  if (burnKm > 0) {
    final burn = litres / burnKm;
    parts.add((key: 'fuel', value: burn, points: 25 * clamp01((40 - burn) / 15), max: 25));
  }
  final points = parts.fold(0.0, (a, p) => a + p.points);
  final max = parts.fold(0.0, (a, p) => a + p.max);
  return (score: (100 * points / max).round(), parts: parts);
}

/// Ocena eco kierowcy z rozpisaniem składników i zastrzeżeniem, że to przybliżenie.
class EcoScoreView extends StatelessWidget {
  const EcoScoreView({super.key, required this.stats, required this.vehicles});

  final Map<String, dynamic> stats;
  final List<Map<String, dynamic>> vehicles;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final eco = ecoScore(stats, vehicles);
    final muted = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    String pct(double v) => '${l.number(100 * v, decimals: 0)}%';
    String pts(EcoPart p) => l.number(p.points, decimals: 0);
    return Column(key: const Key('drv-eco'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(l.drvEcoScore, style: theme.textTheme.titleSmall),
        const Spacer(),
        if (eco != null)
          UiTag(l.drvEcoValue(eco.score),
              tone: eco.score >= 75
                  ? 'ok'
                  : eco.score >= 50
                      ? null
                      : 'error'),
      ]),
      const SizedBox(height: Gap.xs),
      if (eco == null)
        Text(l.drvEcoNone, style: theme.textTheme.bodySmall)
      else
        for (final p in eco.parts)
          Text(
              switch (p.key) {
                'empty' => l.drvEcoEmpty(pct(p.value), pts(p), l.number(p.max, decimals: 0)),
                'idle' => l.drvEcoIdle(pct(p.value), pts(p), l.number(p.max, decimals: 0)),
                _ => l.drvEcoFuel(l.number(p.value, decimals: 1), pts(p), l.number(p.max, decimals: 0)),
              },
              style: theme.textTheme.bodySmall),
      const SizedBox(height: Gap.xs),
      Text(l.drvEcoNote, style: muted),
    ]);
  }
}
