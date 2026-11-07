import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import 'service_dates.dart';
import 'vehicle_actions.dart' show vehicleTitle;
import 'vehicle_form.dart' show kindIcon;
import 'vehicle_state.dart';

/// Karty liczb floty z danych serwera (pulpit, ekran Pojazdy): w użyciu, dostępne, w serwisie, terminy.
/// Pasek pod liczbą – udział we flocie.
class FleetKpis extends StatelessWidget {
  const FleetKpis({super.key, required this.vehicles, required this.width, this.onTap, this.extra = const []});

  final List<Map<String, dynamic>> vehicles;

  /// Szerokość jednej karty.
  final double width;
  final VoidCallback? onTap;

  /// Dodatkowe karty na końcu (np. wiadomości na pulpicie).
  final List<Widget> extra;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final total = vehicles.length;
    final states = [for (final v in vehicles) vehicleState(v)];
    int count(VehicleState s) => states.where((x) => x == s).length;
    double share(int n) => total == 0 ? 0 : n / total;
    final inUse = count(VehicleState.inUse);
    final free = count(VehicleState.free);
    final repair = count(VehicleState.repair);
    final reported = count(VehicleState.reported);
    var overdue = 0;
    var soon = 0;
    for (final v in vehicles) {
      final urgent = mostUrgent(v);
      final km = serviceKmLeft(v);
      if ((urgent?.overdue ?? false) || (km != null && km < 0)) {
        overdue++;
      } else if (urgent != null || km != null) {
        soon++;
      }
    }
    final cards = [
      KpiCard(
        label: l.kpiInUseTitle,
        value: l.number(inUse),
        unit: '/ ${l.number(total)}',
        icon: Icons.local_shipping_outlined,
        progress: share(inUse),
        badge: '${l.number(share(inUse) * 100, decimals: 1)}%',
        status: l.kpiShare(l.number(share(inUse) * 100, decimals: 0)),
        tone: StatusTone.info,
        onTap: onTap,
      ),
      KpiCard(
        label: l.kpiAvailable,
        value: l.number(free),
        icon: Icons.check_circle_outline,
        progress: share(free),
        badge: '${l.number(share(free) * 100, decimals: 1)}%',
        status: l.kpiAvailableHint,
        tone: StatusTone.ok,
        onTap: onTap,
      ),
      KpiCard(
        label: l.kpiRepair,
        value: l.number(repair),
        icon: Icons.build_outlined,
        progress: share(repair + reported),
        badge: '${l.number(share(repair + reported) * 100, decimals: 1)}%',
        status: reported > 0 ? l.kpiReported(l.number(reported)) : l.kpiNoReports,
        tone: repair + reported > 0 ? StatusTone.error : StatusTone.ok,
        onTap: onTap,
      ),
      KpiCard(
        label: l.kpiDeadlines,
        value: l.number(overdue + soon),
        icon: Icons.event_note_outlined,
        progress: share(overdue + soon),
        badge: '${l.number(share(overdue + soon) * 100, decimals: 1)}%',
        status: overdue > 0 ? l.kpiOverdue(l.number(overdue)) : (soon > 0 ? l.kpiDueSoon : l.kpiAllFine),
        tone: overdue > 0 ? StatusTone.error : (soon > 0 ? StatusTone.warning : StatusTone.ok),
        onTap: onTap,
      ),
      ...extra,
    ];
    return Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
      for (final card in cards) SizedBox(width: width, child: card),
    ]);
  }
}

/// Pojazdy z terminem po czasie / bliskim, serwisem według przebiegu albo w naprawie / z usterką;
/// najpilniejsze pierwsze.
class VehiclesAttention extends StatelessWidget {
  const VehiclesAttention(
      {super.key, required this.vehicles, required this.onOpen, required this.empty, this.limit = 6});

  final List<Map<String, dynamic>> vehicles;
  final ValueChanged<Map<String, dynamic>> onOpen;

  /// Gdy nic nie wymaga uwagi.
  final Widget empty;
  final int limit;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final items = <(int, Widget)>[];
    for (final v in vehicles) {
      final state = vehicleState(v);
      final urgent = mostUrgent(v);
      final km = serviceKmLeft(v);
      final notes = [
        if (state == VehicleState.repair || state == VehicleState.reported) stateText(l, v)!,
        if (urgent != null)
          (urgent.overdue ? l.vehicleOverdue : l.vehicleDueSoon)(
              serviceDateLabel(l, urgent.key), DateFormat.yMd(l.localeName).format(urgent.day)),
        if (km != null) km < 0 ? l.vehicleServiceKmOverdue(l.number(-km)) : l.vehicleServiceKmSoon(l.number(km)),
      ];
      if (notes.isEmpty) continue;
      final overdue = state == VehicleState.repair || (urgent?.overdue ?? false) || (km != null && km < 0);
      items.add((
        overdue ? 0 : 1,
        AttentionTile(
          title: vehicleTitle(v),
          subtitle: notes.join(' · '),
          overdue: overdue,
          tag: state == VehicleState.repair || state == VehicleState.reported
              ? l.tagService
              : (overdue ? l.tagUrgent : l.tagDueSoon),
          icon: kindIcon(v['kind'] as String?),
          onTap: () => onOpen(v),
        ),
      ));
    }
    if (items.isEmpty) return empty;
    items.sort((a, b) => a.$1.compareTo(b.$1));
    return Column(children: [for (final (_, tile) in items.take(limit)) tile]);
  }
}
