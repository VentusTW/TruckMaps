import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import '../vehicles/service_dates.dart';

/// Relacja skąd → dokąd z tras wysłanych przez dyspozytora: kursy, km i przychód (PLN).
typedef Corridor = ({String label, int trips, double km, double revenue, double revenueKm});

/// Najczęstsze relacje z `orders` podsumowania przychodów; `vehicleIds` – tylko te pojazdy.
/// Przychód z kwot przeliczonych na PLN (`value`); na km tylko z tras o znanej długości.
List<Corridor> corridorsFrom(List<Map<String, dynamic>> orders, {Set<String>? vehicleIds, int limit = 5}) {
  final groups = <String, ({int trips, double km, double revenue, double revenueKm})>{};
  for (final o in orders) {
    final label = '${o['label'] ?? ''}'.trim();
    if (label.isEmpty || label == '→') continue;
    if (vehicleIds != null && !vehicleIds.contains('${o['vehicle_id']}')) continue;
    final km = ((o['distance_km'] as num?) ?? 0).toDouble();
    final value = ((o['value'] as num?) ?? 0).toDouble();
    final g = groups[label] ?? (trips: 0, km: 0.0, revenue: 0.0, revenueKm: 0.0);
    groups[label] = (
      trips: g.trips + 1,
      km: g.km + km,
      revenue: g.revenue + value,
      revenueKm: g.revenueKm + (km > 0 ? km : 0) * (value > 0 ? 1 : 0),
    );
  }
  final list = [
    for (final e in groups.entries)
      (label: e.key, trips: e.value.trips, km: e.value.km, revenue: e.value.revenue, revenueKm: e.value.revenueKm)
  ]..sort((a, b) => b.trips != a.trips ? b.trips.compareTo(a.trips) : b.revenue.compareTo(a.revenue));
  return list.take(limit).toList();
}

/// Karta „Korytarze tras” w Analityce; `corridors == null` – brak dostępu do zleceń.
class CorridorsCard extends StatelessWidget {
  const CorridorsCard({super.key, required this.corridors});

  final List<Corridor>? corridors;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = corridors;
    final top = items == null || items.isEmpty ? 1 : items.first.trips;
    return UiPanel(
      key: const Key('an-corridors'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.anCorridors, icon: Icons.alt_route_outlined),
        const SizedBox(height: Gap.s),
        Text(l.anCorridorsNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.m),
        if (items == null)
          UiEmpty(l.anRevenueNone)
        else if (items.isEmpty)
          UiEmpty(l.anCorridorsNone)
        else
          for (final c in items) ...[
            Text(c.label, style: theme.textTheme.labelLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: Gap.xs),
            TruckProgressBar(value: c.trips / top, height: 4),
            const SizedBox(height: Gap.xs),
            Text(l.anCorridorTrips(l.number(c.trips), l.number(c.km, decimals: 0)), style: theme.textTheme.bodySmall),
            Text(
                c.revenue <= 0
                    ? l.anCorridorNoRevenue
                    : l.anCorridorRevenue(l.number(c.revenue, decimals: 0),
                        c.revenueKm == 0 ? '–' : l.number(c.revenue / c.revenueKm, decimals: 2)),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            const SizedBox(height: Gap.m),
          ],
      ]),
    );
  }
}

/// Podsumowanie zgodności z modułu Kierowcy (`/api/m/drivers/compliance`); `null` – moduł nieaktywny.
Future<Map<String, dynamic>?> loadCompliance(CoreApi api, String? companyId) async {
  if (companyId == null) return null;
  try {
    final r = await api.get('/api/m/drivers/compliance?company_id=${Uri.encodeComponent(companyId)}');
    return r is Map && r['drivers'] is List ? Map<String, dynamic>.from(r) : null;
  } catch (_) {
    return null;
  }
}

/// Terminy dokumentów pojazdów („ważny do”) po terminie albo w ciągu [dueSoonDays] dni, od najbliższych.
List<({Map<String, dynamic> vehicle, String key, DateTime day})> vehicleDeadlines(List<Map<String, dynamic>> vehicles,
    {DateTime? today}) {
  final now = today ?? DateTime.now();
  final day0 = DateTime(now.year, now.month, now.day);
  final found = [
    for (final v in vehicles)
      for (final key in serviceDateKeys.where((k) => k.endsWith('_until')))
        if (DateTime.tryParse('${v[key]}') case final day? when day.difference(day0).inDays <= dueSoonDays)
          (vehicle: v, key: key, day: day)
  ]..sort((a, b) => a.day.compareTo(b.day));
  return found;
}

/// Karta „Zgodność prawna”: naruszenia 561/2006 z plików tachografu i terminy dokumentów.
class ComplianceCard extends StatelessWidget {
  const ComplianceCard({super.key, required this.compliance, required this.vehicles, this.today});

  /// Odpowiedź `/api/m/drivers/compliance`; `null` – moduł Kierowcy nieaktywny.
  final Map<String, dynamic>? compliance;
  final List<Map<String, dynamic>> vehicles;
  final DateTime? today;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final small = theme.textTheme.bodySmall;
    final muted = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final c = compliance;
    final drivers = uiMaps(c?['drivers']);
    int sum(String key) => drivers.fold(0, (a, d) => a + ((d[key] as num?) ?? 0).toInt());
    final violations = sum('violations');
    final withData = drivers.where((d) => d['has_data'] == true).length;
    final offenders = drivers.where((d) => ((d['violations'] as num?) ?? 0) > 0).length;
    final deadlines = vehicleDeadlines(vehicles, today: today);
    final now = today ?? DateTime.now();
    final day0 = DateTime(now.year, now.month, now.day);
    final overdue = deadlines.where((d) => d.day.isBefore(day0)).length + sum('dues_overdue');
    final soon = deadlines.length + sum('dues_soon') + sum('dues_overdue') - overdue;
    return UiPanel(
      key: const Key('an-compliance'),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.anCompliance, icon: Icons.policy_outlined),
        const SizedBox(height: Gap.s),
        Text(l.anComplianceNote, style: small?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.m),
        if (c == null)
          Text(l.anComplianceNoModule, style: small)
        else if (withData == 0)
          Text(l.anComplianceNoTacho, style: small)
        else ...[
          Text(l.anComplianceViolations(l.number(violations), l.number((c['days'] as num?) ?? 28)),
              style: theme.textTheme.labelLarge?.copyWith(color: violations > 0 ? scheme.error : null)),
          if (violations > 0) ...[
            Text(l.anComplianceSerious(l.number(sum('serious')), l.number(sum('very_serious'))), style: small),
            Text(l.anComplianceDrivers(l.number(offenders), l.number(withData)), style: muted),
          ],
        ],
        const SizedBox(height: Gap.m),
        Text(overdue + soon == 0 ? l.anComplianceDocsOk : l.anComplianceDocs(l.number(overdue), l.number(soon)),
            style: theme.textTheme.labelLarge?.copyWith(color: overdue > 0 ? scheme.error : null)),
        for (final d in deadlines.take(3))
          Text(
              l.anComplianceDue('${d.vehicle['plate'] ?? d.vehicle['name'] ?? ''}', serviceDateLabel(l, d.key),
                  DateFormat.yMd(l.localeName).format(d.day)),
              style: muted?.copyWith(color: d.day.isBefore(day0) ? scheme.error : null)),
      ]),
    );
  }
}
