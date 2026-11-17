import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'texts.dart';

double _d(Object? value) => value is num ? value.toDouble() : 0;

/// Stan względem limitu: `over` – przekroczony, `warn` – ponad 90 %, `ok`.
String loadStatus(num load, num? limit) {
  if (limit == null || limit <= 0) return 'ok';
  if (load > limit + 0.5) return 'over';
  return load > 0.9 * limit ? 'warn' : 'ok';
}

/// Kolor stanu nacisku: zielony / pomarańczowy / czerwony.
Color loadColor(BuildContext context, String status) => switch (status) {
      'over' => Theme.of(context).colorScheme.error,
      'warn' => TruckColors.of(context).warning,
      _ => TruckColors.of(context).success,
    };

/// Naciski na każdą oś, masa ciągnika i całkowita oraz udział osi napędowej – nad rysunkiem
/// planu (jak w planerach nacisków, np. Axle Plan). `vehicle` – `PlanOut.vehicle` z serwera.
class AxleStrip extends StatelessWidget {
  const AxleStrip({super.key, required this.vehicle});

  final Map<String, dynamic> vehicle;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    final axles = (vehicle['axles'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final tractor = vehicle['tractor_kg'] as num?;
    final share = _d(vehicle['drive_share']);
    final minShare = _d(vehicle['drive_min_share']);
    final shareOk = share >= minShare;
    BoxDecoration box([Color? border]) => BoxDecoration(
          color: colors.surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.radius),
          border: border == null ? null : Border.all(color: border.withOpacity(0.5)),
        );
    Widget weight(String key, String label, num kg, num? limit) {
      final color = loadColor(context, loadStatus(kg, limit));
      return Expanded(
        child: Container(
          key: ValueKey('axle-strip-$key'),
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          decoration: box(),
          child: Row(children: [
            Expanded(child: Text(label, style: theme.textTheme.labelMedium)),
            Text(t.tonnes(kg.toDouble()),
                style: theme.textTheme.titleSmall?.copyWith(color: color, fontWeight: FontWeight.w700)),
          ]),
        ),
      );
    }

    Widget axle(Map<String, dynamic> a) {
      final status = '${a['status']}';
      final color = loadColor(context, status);
      final load = _d(a['load_kg']);
      return Expanded(
        child: Container(
          key: ValueKey('axle-strip-${a['id']}'),
          padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.s),
          decoration: box(status == 'ok' ? null : color),
          child: Column(children: [
            Text(t.axleName('${a['id']}'),
                style: theme.textTheme.labelMedium,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              t.axleUse(t.tonnes(load), t.number((_d(a['ratio']) * 100).round())),
              style: theme.textTheme.labelLarge?.copyWith(color: color, fontWeight: FontWeight.w700),
              textAlign: TextAlign.center,
            ),
          ]),
        ),
      );
    }

    final steer = axles.isEmpty ? null : axles.first;
    final steerMin = steer?['min_kg'] as num?;
    final steerLow = steerMin != null && _d(steer?['load_kg']) < steerMin;
    Widget banner(IconData icon, Color color, String text, String key) => Container(
          key: ValueKey(key),
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(TruckTheme.radius),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(icon, size: 18, color: color),
            const SizedBox(width: Gap.s),
            Flexible(child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: color))),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        if (tractor != null) ...[
          weight('tractor', t.tractorWeight, tractor, vehicle['tractor_limit_kg'] as num?),
          const SizedBox(width: Gap.s),
        ],
        weight('gross', t.grossWeight, _d(vehicle['gross_kg']), vehicle['gross_limit_kg'] as num?),
      ]),
      const SizedBox(height: Gap.s),
      Row(children: [
        for (final (i, a) in axles.indexed) ...[
          if (i > 0) const SizedBox(width: Gap.s),
          axle(a),
        ],
      ]),
      const SizedBox(height: Gap.s),
      banner(
        shareOk ? Icons.check_circle : Icons.warning_amber_rounded,
        shareOk ? colors.success : theme.colorScheme.error,
        t.driveAxleShare(t.number((share * 100).round()), t.number((minShare * 100).round())),
        'axle-strip-share',
      ),
      if (steerLow) ...[
        const SizedBox(height: Gap.xs),
        banner(Icons.warning_amber_rounded, theme.colorScheme.error, t.steerBelowMin(t.tonnes(steerMin.toDouble())),
            'axle-strip-steer-low'),
      ],
    ]);
  }
}
