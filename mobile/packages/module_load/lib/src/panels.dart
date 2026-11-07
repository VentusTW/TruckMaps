import 'dart:math' as math;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'sim_view.dart';
import 'texts.dart';

double _d(Object? value) => value is num ? value.toDouble() : 0;

double _ratio(num? value, num? limit) => value == null || limit == null || limit <= 0 ? 0 : value / limit;

List<Map<String, dynamic>> _list(Map<String, dynamic> plan, String key) =>
    (plan[key] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

/// Środek ciężkości w porządku: żadna oś nie przeciążona, oś napędowa ciągnika ma ≥ 25%.
bool cogBalanced(Map<String, dynamic> plan) {
  if (_list(plan, 'axles').any((a) => a['over'] == true)) return false;
  final tractor = plan['tractor'] as Map<String, dynamic>?;
  if (tractor == null) return true;
  return _d(tractor['drive_share']) >= 0.25 &&
      _d(tractor['front_kg']) <= _d(tractor['front_limit_kg']) &&
      _d(tractor['drive_kg']) <= _d(tractor['drive_limit_kg']) &&
      _d(tractor['gvw_kg']) <= _d(tractor['gvw_limit_kg']);
}

Color _barColor(BuildContext context, double ratio, bool over) {
  final scheme = Theme.of(context).colorScheme;
  if (over) return scheme.error;
  return ratio >= 0.9 ? TruckColors.of(context).warning : scheme.primaryContainer;
}

/// Nagłówek: ciągnik + naczepa, certyfikat, zlecenie, KPI i przyciski.
class LoadHeader extends StatelessWidget {
  const LoadHeader({
    super.key,
    required this.cargo,
    required this.tractor,
    required this.plan,
    required this.bodyCode,
    required this.reference,
    required this.mats,
    required this.approved,
    required this.busy,
    required this.onForces,
    required this.onExport,
    required this.onApprove,
  });

  final Map<String, dynamic> cargo;
  final Map<String, dynamic>? tractor;
  final Map<String, dynamic>? plan;
  final String bodyCode;
  final String reference;
  final bool mats;
  final bool approved;
  final bool busy;
  final VoidCallback? onForces;
  final VoidCallback? onExport;
  final VoidCallback? onApprove;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final caption = theme.textTheme.bodySmall?.copyWith(color: scheme.secondary);
    final plan = this.plan;
    Widget unit(Map<String, dynamic> v) => Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${v['name']}', style: theme.textTheme.titleMedium),
          if (v['plate'] != null) ...[
            const SizedBox(width: Gap.s),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: TruckColors.of(context).surfaceHigh,
                borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
              ),
              child: Text('${v['plate']}', style: theme.textTheme.labelSmall),
            ),
          ],
        ]);
    Widget kpi(String label, String value, String? unit, String? note, {double? progress, bool over = false}) =>
        SizedBox(
          width: 210,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SectionLabel(label),
            const SizedBox(height: Gap.xs),
            BigNumber(value: value, unit: unit, size: 22),
            if (note != null) Text(note, style: caption),
            if (progress != null) ...[
              const SizedBox(height: Gap.xs),
              TruckProgressBar(value: progress, color: over ? scheme.error : null),
            ],
          ]),
        );
    final places = plan?['pallet_places'] as int? ?? 0;
    final used = plan?['places_used'] as int? ?? 0;
    final weight = _d(plan?['weight_kg']);
    final payload = plan?['payload_kg'] as num?;
    final forces = plan?['forces'] as Map<String, dynamic>?;
    final mu = forces == null ? (mats ? 0.6 : 0.3) : _d(forces['mu']);
    final identity = Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const IconSquare(icon: Icons.local_shipping_outlined),
      const SizedBox(width: Gap.m),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: Gap.s, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (tractor != null) ...[unit(tractor!), Text('+', style: theme.textTheme.titleMedium)],
            unit(cargo),
          ]),
          const SizedBox(height: Gap.xs),
          Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
            StatusChip(
              label: t.body(bodyCode),
              tone: bodyCode == 'unknown' ? StatusTone.neutral : StatusTone.ok,
              icon: Icons.verified_outlined,
              uppercase: false,
            ),
            if (reference.isNotEmpty)
              StatusChip(label: '${t.reference}: $reference', tone: StatusTone.info, uppercase: false),
            if (approved)
              StatusChip(label: t.approved, tone: StatusTone.ok, icon: Icons.check_circle_outline, uppercase: false),
          ]),
          if (tractor == null) ...[
            const SizedBox(height: Gap.xs),
            Text(t.noTrailer, style: caption),
          ],
        ]),
      ),
    ]);
    final buttons = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(
        onPressed: onForces,
        icon: busy
            ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.calculate_outlined),
        label: Text(t.forcesButton),
      ),
      const SizedBox(height: Gap.s),
      OutlinedButton.icon(
        onPressed: onExport,
        icon: const Icon(Icons.picture_as_pdf_outlined),
        label: Text(t.exportButton),
      ),
      const SizedBox(height: Gap.s),
      FilledButton.icon(
        onPressed: onApprove,
        icon: Icon(approved ? Icons.verified : Icons.check_circle_outline),
        label: Text(approved ? t.approved : t.approveButton),
      ),
    ]);
    final kpis = Wrap(spacing: Gap.xl, runSpacing: Gap.m, children: [
      kpi(
        t.kpiPlaces,
        plan == null ? '–' : '$used / $places',
        null,
        plan == null || places == 0 ? null : t.placesShare(t.fixed(used / places * 100)),
        progress: plan == null ? null : _ratio(used, places),
      ),
      kpi(
        t.kpiWeight,
        plan == null ? '–' : t.tonnes(weight),
        payload == null ? null : '/ ${t.tonnes(payload.toDouble())}',
        null,
        progress: plan == null || payload == null ? null : _ratio(weight, payload),
        over: payload != null && weight > payload,
      ),
      kpi(t.kpiFriction, t.fixed(mu, 2), null, t.friction(t.fixed(mu, 2), mats)),
    ]);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: LayoutBuilder(builder: (context, size) {
          if (size.maxWidth >= 900) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                identity,
                const SizedBox(height: Gap.l),
                kpis,
              ])),
              const SizedBox(width: Gap.l),
              SizedBox(width: 320, child: buttons),
            ]);
          }
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            identity,
            const SizedBox(height: Gap.l),
            kpis,
            const SizedBox(height: Gap.l),
            buttons,
          ]);
        }),
      ),
    );
  }
}

/// Legenda symulatora: grupy ładunku z zakresem mas, wolne miejsca, dane naczepy.
class SimLegend extends StatelessWidget {
  const SimLegend({super.key, required this.plan, required this.kinds});

  final Map<String, dynamic> plan;
  final List<CargoLook> kinds;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary);
    final scene = SimScene(plan, kinds);
    final groups = <CargoGroup, List<double>>{};
    final counts = <CargoGroup, int>{};
    // Towar inny niż palety – osobno każdy rodzaj (nazwa, kolor grupy towaru).
    final others = <String, (Color, List<double>, int)>{};
    for (final p in scene.pieces) {
      final each = p.weight / math.max(1, p.pieces);
      if (p.group == CargoGroup.bulk) {
        final name = p.look.name.isEmpty ? t.group('bulk') : p.look.name;
        final (color, weights, count) = others[name] ?? (p.color, <double>[], 0);
        others[name] = (color, weights..add(each), count + p.pieces);
        continue;
      }
      groups.putIfAbsent(p.group, () => []).add(each);
      counts[p.group] = (counts[p.group] ?? 0) + p.pieces;
    }
    final units = counts.values.fold<int>(0, (s, c) => s + c) + others.values.fold<int>(0, (s, o) => s + o.$3);
    final free = math.max(0, (plan['pallet_places'] as int? ?? 0) - (plan['places_used'] as int? ?? 0));
    String range(List<double> w) {
      final lo = w.reduce(math.min).round(), hi = w.reduce(math.max).round();
      return lo == hi ? '$lo kg' : '$lo–$hi kg';
    }

    Widget dot(Color color) => Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(right: Gap.s),
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        );
    Widget fact(String label, String value) => SizedBox(
          width: 170,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: caption),
            Text(value, style: theme.textTheme.labelLarge),
          ]),
        );
    final legend = Container(
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(
        color: TruckColors.of(context).surfaceLow,
        borderRadius: BorderRadius.circular(TruckTheme.radius),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: SectionLabel(t.legendTitle)),
          StatusChip(label: t.units(units), tone: StatusTone.info, uppercase: false),
        ]),
        const SizedBox(height: Gap.s),
        for (final g in CargoGroup.values)
          if (groups[g] != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                dot(groupColors[g]!),
                Expanded(child: Text(t.groupLine(t.group(g.name), range(groups[g]!), counts[g]!), style: caption)),
              ]),
            ),
        for (final MapEntry(key: name, value: (color, weights, count)) in others.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              dot(color),
              Expanded(child: Text(t.groupLine(name, range(weights), count), style: caption)),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Container(
              width: 12,
              height: 12,
              margin: const EdgeInsets.only(right: Gap.s),
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.outline),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(t.freeSlots(free), style: caption),
          ]),
        ),
      ]),
    );
    final facts = Wrap(spacing: Gap.m, runSpacing: Gap.s, children: [
      fact(t.length, t.metres(scene.length)),
      fact(t.width, t.metres(scene.width)),
      fact(t.usableHeight, plan['inner_height_m'] == null ? '–' : t.metres(scene.inner)),
      fact(t.loadingMetres, '${t.fixed(_d(plan['ldm']), 2)} LDM'),
      if (scene.cog != null) fact(t.cogShort, t.metres(scene.cog!)),
    ]);
    return LayoutBuilder(builder: (context, size) {
      if (size.maxWidth >= 720) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: legend),
          const SizedBox(width: Gap.l),
          Expanded(child: facts),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        legend,
        const SizedBox(height: Gap.m),
        facts,
      ]);
    });
  }
}

/// Rozkład nacisków: osie ciągnika (szacunek), siodło, osie naczepy, DMC z limitem.
class AxlePanel extends StatelessWidget {
  const AxlePanel({super.key, required this.plan});

  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final caption = theme.textTheme.bodySmall?.copyWith(color: scheme.secondary);
    final axles = _list(plan, 'axles');
    final tractor = plan['tractor'] as Map<String, dynamic>?;
    final ok = cogBalanced(plan);
    Widget bar(String label, num load, num? limit, {bool? over, String? note, bool noteBad = false}) {
      final ratio = _ratio(load, limit);
      final isOver = over ?? (limit != null && load > limit);
      return Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(label, style: theme.textTheme.labelMedium)),
            Text(
              limit == null
                  ? t.tonnes(load.toDouble())
                  : '${t.tonnes(load.toDouble())} / ${t.tonnes(limit.toDouble())}',
              style: theme.textTheme.labelLarge?.copyWith(color: isOver ? scheme.error : null),
            ),
          ]),
          if (limit != null) ...[
            const SizedBox(height: Gap.xs),
            Row(children: [
              Expanded(child: TruckProgressBar(value: ratio, height: 8, color: _barColor(context, ratio, isOver))),
              const SizedBox(width: Gap.s),
              Text('${t.fixed(ratio * 100)}%', style: caption),
            ]),
          ],
          if (note != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child:
                  Text(note, style: caption?.copyWith(color: noteBad ? scheme.error : TruckColors.of(context).success)),
            ),
        ]),
      );
    }

    return SectionCard(
      title: t.axleDistribution,
      icon: Icons.balance,
      action: Padding(
        padding: const EdgeInsets.only(right: Gap.s),
        child: StatusChip(label: ok ? t.withinLimits : t.axleOver, tone: ok ? StatusTone.ok : StatusTone.error),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.axleIntro, style: caption),
        const SizedBox(height: Gap.m),
        if (tractor != null) ...[
          bar(t.tractorFront, _d(tractor['front_kg']), _d(tractor['front_limit_kg'])),
          bar(
            t.tractorDrive,
            _d(tractor['drive_kg']),
            _d(tractor['drive_limit_kg']),
            note: t.driveShare(t.fixed(_d(tractor['drive_share']) * 100)),
            noteBad: _d(tractor['drive_share']) < 0.25,
          ),
        ],
        for (final axle in axles)
          bar(t.axle(axle['name'] as String), axle['load_kg'] as num, axle['limit_kg'] as num?,
              over: axle['over'] == true),
        if (tractor != null)
          Container(
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: TruckColors.of(context).surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  SectionLabel(t.gvw),
                  BigNumber(value: t.tonnes(_d(tractor['gvw_kg'])), size: 20),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                SectionLabel(t.gvwLimit),
                Text(
                  t.tonnes(_d(tractor['gvw_limit_kg'])),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: _d(tractor['gvw_kg']) > _d(tractor['gvw_limit_kg']) ? scheme.error : scheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ]),
            ]),
          )
        else if (plan['cog_m'] case final num cog)
          Text(t.cog(t.number(cog)), style: theme.textTheme.labelLarge),
      ]),
    );
  }
}

/// Bilans sił EN 12195-1: przyspieszenia, tarcie, ściana czołowa, napięcie pasów.
class ForcesPanel extends StatelessWidget {
  const ForcesPanel({super.key, required this.plan});

  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final caption = theme.textTheme.bodySmall?.copyWith(color: scheme.secondary);
    final f = plan['forces'] as Map<String, dynamic>?;
    if (f == null) return const SizedBox.shrink();
    final ok = f['ok'] == true;
    final wall = f['wall_kN'] as num?;
    Widget tile(String label, String value, String note) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: TruckColors.of(context).surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: caption),
              BigNumber(value: value, size: 20),
              Text(note, style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
            ]),
          ),
        );
    Widget row(String label, String value, {bool bad = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: Text(label, style: caption)),
            const SizedBox(width: Gap.s),
            Text(value, style: theme.textTheme.labelLarge?.copyWith(color: bad ? scheme.error : null)),
          ]),
        );
    return SectionCard(
      title: t.forcesTitle,
      icon: Icons.functions,
      action: Padding(
        padding: const EdgeInsets.only(right: Gap.s),
        child: Icon(Icons.circle, size: 10, color: ok ? TruckColors.of(context).success : scheme.error),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          tile(t.longitudinal, '0.8 g', t.braking(t.fixed(_d(f['forward_kN'])))),
          const SizedBox(width: Gap.s),
          tile(t.lateral, '0.5 g', t.cornering(t.fixed(_d(f['side_kN'])))),
        ]),
        const SizedBox(height: Gap.m),
        row(t.frictionForce(t.fixed(_d(f['mu']), 2)), '${t.fixed(_d(f['friction_kN']))} kN'),
        row(t.restForward, '${t.fixed(_d(f['rest_forward_kN']))} kN'),
        row(t.wallCapacity, wall == null ? t.wallUnknown : '${t.fixed(wall)} kN',
            bad: f['wall_holds'] != true && wall != null),
        row(t.tension, t.tensionValue(t.number(_d(f['tension_daN']).round()), (f['straps'] as int?) ?? 0)),
        const SizedBox(height: Gap.s),
        Container(
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(
            color: ok ? TruckColors.of(context).mint : scheme.errorContainer,
            borderRadius: BorderRadius.circular(TruckTheme.radius),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
                size: 18, color: ok ? TruckColors.of(context).onMint : scheme.onErrorContainer),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Text(
                ok ? t.forcesOk : t.forcesFail,
                style: theme.textTheme.bodySmall?.copyWith(
                    color: ok ? TruckColors.of(context).onMint : scheme.onErrorContainer, fontWeight: FontWeight.w600),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}

const _gearIcons = {
  'straps': Icons.link,
  'edges': Icons.crop_free,
  'beams': Icons.horizontal_rule,
  'mats': Icons.layers_outlined,
  'airbags': Icons.air,
  'chains': Icons.link_outlined,
  'chocks': Icons.change_history,
  'net': Icons.grid_on,
  'stakes': Icons.view_week_outlined,
};

/// Lista sprzętu VDI 2700: wymagane z obliczeń, założone – potwierdzane w aplikacji.
class GearTable extends StatelessWidget {
  const GearTable({
    super.key,
    required this.plan,
    required this.checked,
    required this.onChecked,
    this.highlight,
    this.onHighlight,
    this.available,
  });

  /// Wyposażenie użytkownika (kolumna „Masz”); `null` – bez ograniczeń.
  final Map<String, int>? available;
  final Map<String, dynamic> plan;
  final Set<String> checked;
  final void Function(String id, bool on) onChecked;

  /// Pozycja podświetlona na rysunku; [onHighlight] – najechanie myszą (na dotyku: stuknięcie w nazwę).
  final String? highlight;
  final ValueChanged<String?>? onHighlight;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary);
    final gear = _list(plan, 'equipment');
    final strapDaN = ((plan['forces'] as Map<String, dynamic>?)?['strap_daN'] as int?) ?? 400;
    final done = gear.every((g) => (g['required'] as int) == 0 || checked.contains(g['id']));
    Widget head(String text) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s, horizontal: Gap.xs),
          child: SectionLabel(text),
        );
    final shortages = (plan['shortages'] as Map<String, dynamic>? ?? const {});
    int short(String id) => (shortages[id] as int?) ?? 0;
    TableRow gearRow(int i, Map<String, dynamic> g) {
      final id = g['id'] as String;
      final required = g['required'] as int;
      final on = checked.contains(id);
      final lit = highlight == id;
      // Cała komórka reaguje na kursor – wiersz podświetla sprzęt na rysunku.
      Widget cell(Widget child, {bool tap = false}) => MouseRegion(
            key: tap ? ValueKey('gear-row-$id') : null,
            onEnter: (_) => onHighlight?.call(id),
            onExit: (_) => onHighlight?.call(null),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: tap ? () => onHighlight?.call(lit ? null : id) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: Gap.m, horizontal: Gap.xs),
                child: child,
              ),
            ),
          );
      return TableRow(decoration: BoxDecoration(color: lit ? glowColor.withOpacity(0.18) : null), children: [
        cell(Text((i + 1).toString().padLeft(2, '0'), style: caption)),
        cell(
            tap: true,
            Row(children: [
              Icon(lit ? Icons.visibility : (_gearIcons[id] ?? Icons.build_outlined),
                  size: 18, color: theme.colorScheme.primary),
              const SizedBox(width: Gap.s),
              Expanded(
                  child: Text(t.gear(id),
                      style: theme.textTheme.labelLarge?.copyWith(fontWeight: lit ? FontWeight.w800 : null))),
            ])),
        cell(Text(t.gearSpec(id, strapDaN).isEmpty ? t.gearSpecMore(id) : t.gearSpec(id, strapDaN), style: caption)),
        cell(Text(t.pieces(required), style: theme.textTheme.labelLarge)),
        if (available != null)
          cell(Text(t.pieces(available![id] ?? 0),
              style: theme.textTheme.labelLarge
                  ?.copyWith(color: short(id) > 0 ? theme.colorScheme.error : null, fontWeight: FontWeight.w700))),
        cell(required == 0
            ? const SizedBox.shrink()
            : Checkbox(
                key: ValueKey('gear-$id'),
                value: on,
                onChanged: (v) => onChecked(id, v ?? false),
              )),
        cell(Align(
          alignment: Alignment.centerLeft,
          child: StatusChip(
            label: short(id) > 0
                ? t.statusShort(short(id))
                : required == 0
                    ? t.statusNotNeeded
                    : on
                        ? t.statusConfirmed
                        : t.statusMissing,
            tone: short(id) > 0
                ? StatusTone.error
                : required == 0
                    ? StatusTone.neutral
                    : on
                        ? StatusTone.ok
                        : StatusTone.warning,
            uppercase: false,
          ),
        )),
      ]);
    }

    final table = Table(
      columnWidths: {
        0: const FixedColumnWidth(40),
        1: const FlexColumnWidth(2.2),
        2: const FlexColumnWidth(2.6),
        3: const FlexColumnWidth(1.1),
        if (available != null) 4: const FlexColumnWidth(0.9),
        (available != null ? 5 : 4): const FixedColumnWidth(80),
        (available != null ? 6 : 5): const FlexColumnWidth(1.4),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(horizontalInside: BorderSide(color: theme.dividerColor)),
      children: [
        TableRow(children: [
          head(t.colNo),
          head(t.colItem),
          head(t.colSpec),
          head(t.colRequired),
          if (available != null) head(t.colHave),
          head(t.colInstalled),
          head(t.colStatus),
        ]),
        for (final (i, g) in gear.indexed) gearRow(i, g),
      ],
    );
    return SectionCard(
      title: t.gearTitle,
      icon: Icons.fact_check_outlined,
      action: Padding(
        padding: const EdgeInsets.only(right: Gap.s),
        child: StatusChip(
          label: done ? t.gearVerified : t.gearPending,
          tone: done ? StatusTone.ok : StatusTone.warning,
          uppercase: false,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.gearHoverHint, style: caption),
        LayoutBuilder(builder: (context, size) {
          if (size.maxWidth >= 720) return table;
          return SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: 720, child: table));
        }),
      ]),
    );
  }
}

/// Normy prawne i atesty: EN 12642, EN 12195-1, VDI 2700, art. 61 PoRD.
class NormsPanel extends StatelessWidget {
  const NormsPanel({super.key, required this.plan, required this.gearDone});

  final Map<String, dynamic> plan;

  /// VDI 2700 wymaga też potwierdzonego sprzętu z listy.
  final bool gearDone;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final caption = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary);
    final norms = [
      for (final n in _list(plan, 'norms'))
        (id: n['id'] as String, ok: n['ok'] == true && (n['id'] != 'vdi2700' || gearDone)),
    ];
    final met = norms.where((n) => n.ok).length;
    return SectionCard(
      title: t.normsTitle,
      icon: Icons.gavel_outlined,
      action: Padding(
        padding: const EdgeInsets.only(right: Gap.s),
        child: StatusChip(
          label: t.normsCount(met, norms.length),
          tone: met == norms.length ? StatusTone.ok : StatusTone.warning,
          uppercase: false,
        ),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final n in norms)
          Container(
            margin: const EdgeInsets.only(bottom: Gap.s),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: TruckColors.of(context).surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(n.ok ? Icons.verified_outlined : Icons.report_outlined,
                  size: 20, color: toneColor(context, n.ok ? StatusTone.ok : StatusTone.warning)),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(t.normTitle(n.id), style: theme.textTheme.labelLarge)),
                    StatusChip(
                      label: n.ok ? t.normOk : t.normCheck,
                      tone: n.ok ? StatusTone.ok : StatusTone.warning,
                    ),
                  ]),
                  const SizedBox(height: 2),
                  Text(t.normText(n.id), style: caption),
                ]),
              ),
            ]),
          ),
      ]),
    );
  }
}

/// Ostrzeżenia z serwera.
class WarningsPanel extends StatelessWidget {
  const WarningsPanel({super.key, required this.plan});

  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final warning in (plan['warnings'] as List<dynamic>))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('⚠ $warning', style: TextStyle(color: scheme.onErrorContainer)),
          ),
      ]),
    );
  }
}
