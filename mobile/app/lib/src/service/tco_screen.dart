import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'service_data.dart';

/// „Koszty i TCO” według projektu Stitch: koszt wozokilometra i jego struktura (trasy, serwis),
/// benchmark marek, spalanie pusty/pełny z kart pojazdów i ranking kierowców z przejazdów.
/// Wynagrodzenia, amortyzacja, myto, ceny paliw, anomalie CAN, akcyza i ERP – „W budowie”.
class TcoScreen extends StatefulWidget {
  const TcoScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.onOpen,
    this.onOpenDriver,
    this.months = 6,
  });

  final CoreApi api;
  final String? companyId;
  final ValueChanged<String> onOpen;
  final void Function(String id, String name)? onOpenDriver;
  final int months;

  @override
  State<TcoScreen> createState() => _TcoScreenState();
}

class _TcoScreenState extends State<TcoScreen> {
  FleetData? _data;
  Object? _error;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data =
          await FleetData.load(widget.api, widget.companyId, withStats: true, withDrivers: true, months: widget.months);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error'));
    }
    final l = context.l;
    final km = data.stats.values.fold(0.0, (a, s) => a + ((s['distance_km'] as num?) ?? 0));
    final routes = data.stats.values.fold(0.0, (a, s) => a + tripCosts(s));
    final service = data.done.fold(0.0, (a, o) => a + orderTotal(o));
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final wide = inner >= 900;
      final third = wide ? (inner - 2 * gap) / 3 : inner;
      return ListView(padding: EdgeInsets.all(pad), children: [
        _header(context),
        const SizedBox(height: gap),
        _filters(context, km, routes, service),
        const SizedBox(height: gap),
        if (wide)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(flex: 7, child: _structure(context, km, routes, service)),
              const SizedBox(width: gap),
              Expanded(flex: 5, child: _benchmark(context, data)),
            ]),
          )
        else ...[
          _structure(context, km, routes, service),
          const SizedBox(height: gap),
          _benchmark(context, data),
        ],
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          SizedBox(width: third, child: _tonnage(context, data)),
          SizedBox(
              width: third,
              child: _wipCard(context, l.tcoFuelPrices, l.tcoFuelPricesNote, Icons.local_gas_station_outlined)),
          SizedBox(width: third, child: _wipCard(context, l.tcoAnomalies, l.tcoAnomaliesNote, Icons.shield_outlined)),
        ]),
        const SizedBox(height: gap),
        _drivers(context, data),
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          SizedBox(
              width: wide ? (inner - gap) / 2 : inner,
              child: _wipCard(context, l.tcoExcise, l.tcoExciseNote, Icons.receipt_outlined)),
          SizedBox(
              width: wide ? (inner - gap) / 2 : inner,
              child: _wipCard(context, l.tcoErp, l.tcoErpNote, Icons.sync_alt_outlined)),
        ]),
      ]);
    });
  }

  Widget _header(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return UiPanel(
      child: Wrap(
        spacing: Gap.l,
        runSpacing: Gap.m,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 0, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                UiTag(l.tcoBadge, tone: 'critical'),
                const SizedBox(width: Gap.s),
                Text(l.tcoSource, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: Gap.s),
              Text(l.tcoTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(l.tcoSubtitle, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final (label, icon) in [
              (l.tcoExciseShort, Icons.euro_outlined),
              (l.tcoErpShort, Icons.storage_outlined)
            ])
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
                onPressed: () => widget.onOpen(label),
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
              onPressed: () => widget.onOpen(l.tcoReport),
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(l.tcoReport),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context, double km, double routes, double service) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final perKm = km == 0 ? null : (routes + service) / km;
    Widget box(String label, Widget child, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 200),
            padding: const EdgeInsets.all(Gap.m),
            decoration:
                BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              child,
            ]),
          ),
        );
    return UiPanel(
      child: Wrap(spacing: Gap.m, runSpacing: Gap.m, crossAxisAlignment: WrapCrossAlignment.center, children: [
        box(l.tcoPeriod, Text(l.anLastMonths(l.number(widget.months)), style: theme.textTheme.labelLarge)),
        box(l.tcoMake, WipTag(what: l.tcoMake, onOpen: widget.onOpen), onTap: () => widget.onOpen(l.tcoMake)),
        box(l.tcoCards, WipTag(what: l.tcoCards, onOpen: widget.onOpen), onTap: () => widget.onOpen(l.tcoCards)),
        box(
          l.tcoAvgKm,
          Text.rich(TextSpan(children: [
            TextSpan(
                text: perKm == null ? '–' : l.number(perKm, decimals: 2),
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            TextSpan(text: ' PLN / km', style: theme.textTheme.bodySmall),
          ])),
        ),
      ]),
    );
  }

  Widget _structure(BuildContext context, double km, double routes, double service) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final total = routes + service;
    final parts = [
      (l.tcoRoutes, l.tcoRoutesNote, routes, scheme.primary, true),
      (l.tcoService, l.tcoServiceNote, service, scheme.primaryContainer, true),
      (l.tcoWages, l.tcoWagesNote, 0.0, scheme.outline, false),
      (l.tcoDepreciation, l.tcoDepreciationNote, 0.0, scheme.outlineVariant, false),
      (l.tcoTolls, l.tcoTollsNote, 0.0, colors.surfaceHigh, false),
    ];
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.tcoStructure, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(l.tcoStructureNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(km == 0 ? '–' : '${l.number(total / km, decimals: 2)} PLN',
                style: theme.textTheme.titleLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
            Text(l.tcoBase(l.number(km, decimals: 0)), style: theme.textTheme.labelSmall),
          ]),
        ]),
        const SizedBox(height: Gap.l),
        ClipRRect(
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          child: SizedBox(
            height: 22,
            child: Row(children: [
              for (final (_, _, value, color, _) in parts)
                if (value > 0)
                  Expanded(
                    flex: (value / (total == 0 ? 1 : total) * 1000).round().clamp(1, 1000),
                    child: Container(
                      color: color,
                      alignment: Alignment.center,
                      child: Text('${(100 * value / total).round()}%',
                          style: theme.textTheme.labelSmall?.copyWith(color: Colors.white)),
                    ),
                  ),
              if (total == 0) Expanded(child: Container(color: colors.surfaceHigh)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.l),
        for (final (name, note, value, color, real) in parts)
          UiBox(
            padding: const EdgeInsets.all(Gap.m),
            child: Row(children: [
              Container(width: 12, height: 12, color: color),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: theme.textTheme.labelLarge),
                  Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (real)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(km == 0 ? '–' : '${l.number(value / km, decimals: 2)} PLN/km',
                      style: theme.textTheme.labelLarge),
                  Text(total == 0 ? '' : '${l.number(100 * value / total, decimals: 1)}%',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                ])
              else
                WipTag(what: name, onOpen: widget.onOpen),
            ]),
          ),
      ]),
    );
  }

  Widget _benchmark(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final v in data.power) {
      groups.putIfAbsent('${v['name']}'.split(' ').first, () => []).add(v);
    }
    final rows = [
      for (final MapEntry(key: make, value: list) in groups.entries)
        () {
          final km = list.fold(0.0, (a, v) => a + ((data.stats['${v['id']}']?['distance_km'] as num?) ?? 0));
          final cost = list.fold(0.0, (a, v) => a + tripCosts(data.stats['${v['id']}']));
          final burns = [
            for (final v in list)
              if (v['consumption_loaded'] is num) (v['consumption_loaded'] as num).toDouble()
          ];
          return (
            make,
            list.length,
            burns.isEmpty ? null : burns.reduce((a, b) => a + b) / burns.length,
            km == 0 ? null : cost / km,
            list.first['adblue_percent'] as num?,
          );
        }(),
    ]..sort((a, b) => (a.$4 ?? 99).compareTo(b.$4 ?? 99));
    final best = rows.where((r) => r.$4 != null).firstOrNull;
    final worst = rows.where((r) => r.$4 != null).lastOrNull;
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.tcoBenchmark, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(l.tcoBenchmarkNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.l),
        if (rows.isEmpty) UiEmpty(l.anNoData),
        for (final (make, count, burn, perKm, _) in rows)
          UiBox(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(make, style: theme.textTheme.labelLarge)),
                UiTag(l.tcoUnits(l.number(count)), tone: 'info', uppercase: false),
                const SizedBox(width: Gap.s),
                Text(perKm == null ? '–' : '${l.number(perKm, decimals: 2)} PLN/km',
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
              ]),
              const SizedBox(height: Gap.xs),
              Text(burn == null ? l.tcoBurnUnknown : l.tcoBurn(l.number(burn, decimals: 1)),
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: Gap.xs),
              TruckProgressBar(value: perKm == null || worst?.$4 == null ? 0 : perKm / worst!.$4!, height: 5),
            ]),
          ),
        if (best != null && worst != null && best != worst)
          Container(
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Row(children: [
              Icon(Icons.insights_outlined, color: scheme.primary),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text(l.tcoInsight(best.$1, l.number(100 * (1 - best.$4! / worst.$4!), decimals: 1), worst.$1),
                    style: theme.textTheme.bodySmall),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _tonnage(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    double avg(String key) {
      final list = [
        for (final v in data.power)
          if (v[key] is num) (v[key] as num).toDouble()
      ];
      return list.isEmpty ? 0 : list.reduce((a, b) => a + b) / list.length;
    }

    final empty = avg('consumption_empty');
    final full = avg('consumption_loaded');
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.tcoTonnage, subtitle: l.tcoTonnageNote, icon: Icons.scale_outlined),
        const SizedBox(height: Gap.l),
        MiniBars(
          height: 120,
          labels: [l.tcoEmpty, l.tcoFull],
          series: [
            (scheme.primaryContainer, [empty, full]),
          ],
        ),
        const SizedBox(height: Gap.s),
        Row(children: [
          Expanded(
              child: Text('${l.tcoEmpty}: ${empty == 0 ? '–' : l.number(empty, decimals: 1)} l/100 km',
                  style: theme.textTheme.bodySmall)),
          Text('${l.tcoFull}: ${full == 0 ? '–' : l.number(full, decimals: 1)} l/100 km',
              style: theme.textTheme.bodySmall),
        ]),
        const SizedBox(height: Gap.xs),
        Text(empty == 0 || full == 0 ? '' : l.tcoDelta(l.number(full - empty, decimals: 1)),
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
      ]),
    );
  }

  Widget _drivers(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final q = _query.trim().toLowerCase();
    final drivers = [
      for (final d in data.drivers ?? const <Map<String, dynamic>>[])
        if (q.isEmpty || '${d['name']}'.toLowerCase().contains(q)) d
    ]..sort((a, b) => ((b['stats']?['distance_km'] as num?) ?? 0).compareTo((a['stats']?['distance_km'] as num?) ?? 0));
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          spacing: Gap.m,
          runSpacing: Gap.s,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                UiTag(l.tcoEcoBadge, tone: 'tertiary'),
                const SizedBox(width: Gap.s),
                Text(l.tcoDriversTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ]),
              Text(l.tcoDriversNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            Wrap(spacing: Gap.s, children: [
              SizedBox(
                width: 220,
                child: TextField(
                  key: const Key('tco-search'),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l.tcoSearchDriver,
                    prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
                onPressed: () => widget.onOpen(l.tcoBonuses),
                child: Text(l.tcoBonuses),
              ),
            ]),
          ],
        ),
        const SizedBox(height: Gap.l),
        Container(
          color: colors.surfaceLow,
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          child: Row(children: [
            Expanded(flex: 4, child: Text(l.tcoColDriver.toUpperCase(), style: head)),
            Expanded(flex: 2, child: Text(l.tcoColKm.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColTrips.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColHours.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColEmpty.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColIdle.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColScore.toUpperCase(), textAlign: TextAlign.end, style: head)),
          ]),
        ),
        if (data.drivers == null) Padding(padding: const EdgeInsets.all(Gap.m), child: UiEmpty(l.drvNoModule)),
        for (final d in drivers.take(6))
          InkWell(
            onTap: widget.onOpenDriver == null ? null : () => widget.onOpenDriver!('${d['id']}', '${d['name']}'),
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.surfaceHigh))),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
              child: Builder(builder: (context) {
                final s = (d['stats'] as Map?) ?? const {};
                final km = ((s['distance_km'] as num?) ?? 0).toDouble();
                final empty = ((s['empty_km'] as num?) ?? 0).toDouble();
                final name = '${d['name']}';
                return Row(children: [
                  Expanded(
                    flex: 4,
                    child: Row(children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: scheme.secondaryContainer,
                        child: Text(name.split(' ').take(2).map((p) => p.isEmpty ? '' : p[0]).join(),
                            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer)),
                      ),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name, style: theme.textTheme.labelLarge),
                          Text([for (final v in uiMaps(d['vehicles'])) '${v['plate'] ?? v['name']}'].join(', '),
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                    ]),
                  ),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number(km, decimals: 0)} km',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text(l.number((s['trips'] as num?) ?? 0),
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number((s['hours'] as num?) ?? 0, decimals: 0)} h',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text(km == 0 ? '–' : '${l.number(100 * empty / km, decimals: 1)}%',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number((s['idle_hours'] as num?) ?? 0, decimals: 1)} h',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Align(
                          alignment: Alignment.centerRight, child: WipTag(what: l.tcoColScore, onOpen: widget.onOpen))),
                ]);
              }),
            ),
          ),
      ]),
    );
  }

  Widget _wipCard(BuildContext context, String title, String note, IconData icon) {
    final theme = Theme.of(context);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: title, icon: icon, trailing: WipTag(what: title, onOpen: widget.onOpen)),
        const SizedBox(height: Gap.m),
        Text(note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
