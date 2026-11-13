import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'fleet_export.dart';
import 'service_data.dart';

/// „Raporty i Analityka” według projektu Stitch: przebiegi, kursy puste, koszt wozokilometra,
/// spalanie i ranking taboru z przejazdów TruckMaps (`/api/vehicles/{id}/stats`) i kosztów napraw
/// modułu Serwis. Przychody, marże, korytarze i zgodność prawna – „W budowie”.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.companyName,
    required this.onOpen,
    this.onOpenVehicle,
    this.months = 6,
  });

  final CoreApi api;
  final String? companyId;
  final String companyName;
  final ValueChanged<String> onOpen;
  final void Function(String id, String name)? onOpenVehicle;
  final int months;

  @override
  State<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends State<AnalyticsScreen> {
  FleetData? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await FleetData.load(widget.api, widget.companyId, withStats: true, months: widget.months);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Eksport tabeli pojazdów (km, godziny, koszty, serwis) do CSV – otwiera się w Excelu.
  Future<void> _export() async {
    final data = _data;
    if (data == null) return;
    final opened =
        await openCsv(toCsv(fleetReportRows(context.l, data, (id) => _serviceCost(data, id))), 'raport-floty');
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.exportFailed)));
    }
  }

  double _serviceCost(FleetData data, String vehicleId) => data.done
      .where((o) => o['vehicle_id'] == vehicleId || data.vehicle(vehicleId)?['trailer_id'] == o['vehicle_id'])
      .fold(0.0, (a, o) => a + orderTotal(o));

  @override
  Widget build(BuildContext context) {
    final data = _data;
    if (data == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error'));
    }
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final wide = inner >= 900;
      final kpiColumns = wide ? 4 : (inner >= 560 ? 2 : 1);
      final kpiWidth = (inner - gap * (kpiColumns - 1)) / kpiColumns;
      final l = context.l;
      return ListView(padding: EdgeInsets.all(pad), children: [
        _header(context, data),
        const SizedBox(height: gap),
        _filters(context, inner),
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          for (final k in _kpis(context, data)) SizedBox(width: kpiWidth, child: k),
        ]),
        const SizedBox(height: gap),
        if (wide)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(flex: 8, child: _trend(context, data)),
              const SizedBox(width: gap),
              Expanded(flex: 4, child: _wipCard(context, l.anCorridors, l.anCorridorsNote, Icons.alt_route_outlined)),
            ]),
          )
        else ...[
          _trend(context, data),
          const SizedBox(height: gap),
          _wipCard(context, l.anCorridors, l.anCorridorsNote, Icons.alt_route_outlined),
        ],
        const SizedBox(height: gap),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 8, child: _ranking(context, data)),
            const SizedBox(width: gap),
            Expanded(
              flex: 4,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                _wipCard(context, l.anCompliance, l.anComplianceNote, Icons.policy_outlined),
                const SizedBox(height: gap),
                _source(context, data),
              ]),
            ),
          ])
        else ...[
          _ranking(context, data),
          const SizedBox(height: gap),
          _wipCard(context, l.anCompliance, l.anComplianceNote, Icons.policy_outlined),
          const SizedBox(height: gap),
          _source(context, data),
        ],
      ]);
    });
  }

  Widget _header(BuildContext context, FleetData data) {
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
                UiTag(l.anBadge, tone: 'info'),
                const SizedBox(width: Gap.s),
                Text(l.anSource, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: Gap.s),
              Text(l.anTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(l.anSubtitle(l.number(data.power.length), widget.companyName),
                  style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final (label, icon) in [(l.anKpiConfig, Icons.tune_outlined), (l.anSchedule, Icons.event_outlined)])
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
                onPressed: () => widget.onOpen(label),
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
              onPressed: _export,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(l.anExport),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context, double inner) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final items = [
      (l.anRange, l.anLastMonths(l.number(widget.months)), Icons.calendar_today_outlined, true),
      (l.anVehicles, l.anAllVehicles, Icons.local_shipping_outlined, false),
      (l.anSpec, l.anAllTypes, Icons.category_outlined, false),
      (l.anHub, widget.companyName, Icons.warehouse_outlined, false),
    ];
    final columns = inner >= 900 ? 4 : 2;
    final width = (inner - 40 - Gap.m * (columns - 1)) / columns;
    return UiPanel(
      child: Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
        for (final (label, value, icon, real) in items)
          SizedBox(
            width: width,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              InkWell(
                onTap: real ? null : () => widget.onOpen(label),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
                  decoration: BoxDecoration(
                      color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
                  child: Row(children: [
                    Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.s),
                    Expanded(
                        child: Text(value,
                            maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelLarge)),
                    Icon(Icons.expand_more, size: 18, color: scheme.outline),
                  ]),
                ),
              ),
            ]),
          ),
      ]),
    );
  }

  List<Widget> _kpis(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final stats = data.stats.values;
    final km = stats.fold(0.0, (a, s) => a + ((s['distance_km'] as num?) ?? 0));
    final empty = stats.fold(0.0, (a, s) => a + ((s['empty_km'] as num?) ?? 0));
    final routeCost = stats.fold(0.0, (a, s) => a + tripCosts(s));
    final service = data.done.fold(0.0, (a, o) => a + orderTotal(o));
    final perKm = km == 0 ? null : (routeCost + service) / km;
    final burns = [
      for (final v in data.power)
        if (v['consumption_loaded'] is num) (v['consumption_loaded'] as num).toDouble()
    ];
    final burn = burns.isEmpty ? null : burns.reduce((a, b) => a + b) / burns.length;
    final euro6 = data.power.where((v) => v['emission_class'] == 'euro6' || v['emission_class'] == 'electric').length;
    final big = theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700);
    Widget card(String label, IconData icon, String value, String unit, List<Widget> foot,
            {Color? iconBg, Color? iconFg}) =>
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Text(label.toUpperCase(),
                        style:
                            theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.5))),
                IconSquare(icon: icon, size: 36, background: iconBg, color: iconFg),
              ]),
              const SizedBox(height: Gap.s),
              Text.rich(TextSpan(children: [
                TextSpan(text: value, style: big),
                TextSpan(text: ' $unit', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
              ])),
              const SizedBox(height: Gap.m),
              ...foot,
            ]),
          ),
        );
    final share = km == 0 ? 0.0 : empty / km;
    return [
      card(l.anTotalKm, Icons.speed_outlined, l.number(km, decimals: 0), 'km', [
        Row(children: [
          Expanded(
              child:
                  Text(l.anLoaded('${l.number(100 * (1 - share), decimals: 1)}%'), style: theme.textTheme.bodySmall)),
          Text(l.anEmpty('${l.number(100 * share, decimals: 1)}%'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.error)),
        ]),
        const SizedBox(height: Gap.xs),
        TruckProgressBar(value: 1 - share, height: 6, color: colors.success),
      ]),
      card(l.anCostKm, Icons.payments_outlined, perKm == null ? '–' : l.number(perKm, decimals: 2), 'PLN / km', [
        Text(l.anRouteCosts(km == 0 ? '–' : l.number(routeCost / km, decimals: 2)), style: theme.textTheme.bodySmall),
        Text(l.anServiceCosts(km == 0 ? '–' : l.number(service / km, decimals: 2)), style: theme.textTheme.bodySmall),
      ]),
      card(
          l.anRevenue,
          Icons.account_balance_wallet_outlined,
          '–',
          '',
          [
            WipTag(what: l.anRevenue, onOpen: widget.onOpen),
          ],
          iconBg: scheme.tertiaryContainer,
          iconFg: scheme.onTertiaryContainer),
      card(l.anBurn, Icons.eco_outlined, burn == null ? '–' : l.number(burn, decimals: 1), 'l / 100 km', [
        Text(l.anBurnNote, style: theme.textTheme.bodySmall),
        Text(l.anEuro6(l.number(euro6), l.number(data.power.length)), style: theme.textTheme.labelMedium),
      ]),
    ];
  }

  Widget _trend(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final now = DateTime.now();
    final months = [for (var i = widget.months - 1; i >= 0; i--) DateTime(now.year, now.month - i)];
    String key(DateTime m) => DateFormat('yyyy-MM').format(m);
    double routeCost(DateTime m) => data.stats.values.fold(0.0, (a, s) {
          final month = uiMaps(s['months']).where((x) => x['month'] == key(m)).firstOrNull;
          return a + tripCosts(month);
        });
    double km(DateTime m) => data.stats.values.fold(0.0, (a, s) {
          final month = uiMaps(s['months']).where((x) => x['month'] == key(m)).firstOrNull;
          return a + ((month?['distance_km'] as num?) ?? 0);
        });
    double service(DateTime m) => data.done.where((o) {
          final d = day(o['completed_at']);
          return d != null && d.year == m.year && d.month == m.month;
        }).fold(0.0, (a, o) => a + orderTotal(o));
    final label = DateFormat.MMM(l.localeName);
    final best = months.isEmpty ? null : months.reduce((a, b) => km(a) >= km(b) ? a : b);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.anTrend, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(l.anTrendNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          _legend(context, scheme.primaryContainer, l.anLegendRoutes),
          const SizedBox(width: Gap.m),
          _legend(context, scheme.outline, l.anLegendService),
        ]),
        const SizedBox(height: Gap.l),
        MiniBars(
          height: 170,
          labels: [for (final m in months) label.format(m)],
          series: [
            (scheme.primaryContainer, [for (final m in months) routeCost(m)]),
            (scheme.outline, [for (final m in months) service(m)]),
          ],
        ),
        const SizedBox(height: Gap.m),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Icon(Icons.verified_outlined, size: 18, color: scheme.tertiaryContainer),
            const SizedBox(width: Gap.s),
            Expanded(
              child: Text(
                  best == null
                      ? '–'
                      : l.anBestMonth(DateFormat.yMMMM(l.localeName).format(best), l.number(km(best), decimals: 0)),
                  style: theme.textTheme.bodySmall),
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _legend(BuildContext context, Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ]);

  Widget _ranking(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final rows = [
      for (final v in data.power) (v, data.stats['${v['id']}'], _serviceCost(data, '${v['id']}')),
    ]..sort((a, b) => ((b.$2?['distance_km'] as num?) ?? 0).compareTo((a.$2?['distance_km'] as num?) ?? 0));
    final head = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.anRanking, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(l.anRankingNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          UiTag(l.anTop(l.number(rows.length.clamp(0, 5)), l.number(rows.length)), tone: 'info', uppercase: false),
        ]),
        const SizedBox(height: Gap.l),
        Container(
          color: colors.surfaceLow,
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          child: Row(children: [
            Expanded(flex: 4, child: Text(l.anColVehicle.toUpperCase(), style: head)),
            Expanded(flex: 2, child: Text(l.anColKm.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.anColBurn.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.anColService.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.anColRoutes.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.anColPerKm.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.anColRating.toUpperCase(), textAlign: TextAlign.end, style: head)),
          ]),
        ),
        for (final (v, s, service) in rows.take(5))
          InkWell(
            onTap: widget.onOpenVehicle == null
                ? null
                : () => widget.onOpenVehicle!('${v['id']}', '${v['plate'] ?? v['name']}'),
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.surfaceHigh))),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
              child: Builder(builder: (context) {
                final km = ((s?['distance_km'] as num?) ?? 0).toDouble();
                final routes = tripCosts(s);
                final repair = v['in_repair'] == true || v['repair_reported'] == true;
                return Row(children: [
                  Expanded(
                    flex: 4,
                    child: Row(children: [
                      Icon(repair ? Icons.warning_amber_outlined : Icons.local_shipping_outlined,
                          size: 18, color: repair ? scheme.error : scheme.primary),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${v['plate'] ?? ''}', style: theme.textTheme.labelLarge),
                          Text('${v['name']}',
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                    ]),
                  ),
                  Expanded(
                      flex: 2,
                      child:
                          Text(l.number(km, decimals: 0), textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text(
                          v['consumption_loaded'] == null
                              ? '–'
                              : '${l.number(v['consumption_loaded'] as num, decimals: 1)} l',
                          textAlign: TextAlign.end,
                          style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number(service, decimals: 0)} PLN',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number(routes, decimals: 0)} PLN',
                          textAlign: TextAlign.end, style: theme.textTheme.labelLarge)),
                  Expanded(
                      flex: 2,
                      child: Text(km == 0 ? '–' : l.number((routes + service) / km, decimals: 2),
                          textAlign: TextAlign.end,
                          style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary))),
                  Expanded(
                      flex: 2,
                      child: Align(
                          alignment: Alignment.centerRight, child: WipTag(what: l.anColRating, onOpen: widget.onOpen))),
                ]);
              }),
            ),
          ),
        if (rows.isEmpty) UiEmpty(l.anNoData),
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

  Widget _source(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final trips = data.stats.values.fold(0, (a, s) => a + ((s['trips'] as num?) ?? 0).toInt());
    return Card(
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.anConnector.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onPrimaryContainer.withOpacity(0.8))),
              const SizedBox(height: Gap.xs),
              Text(l.anSynced, style: theme.textTheme.titleMedium?.copyWith(color: scheme.onPrimaryContainer)),
              Text(l.anSyncedNote(l.number(trips), l.number(data.orders?.length ?? 0)),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onPrimaryContainer.withOpacity(0.85))),
            ]),
          ),
          IconButton.filled(
            style: IconButton.styleFrom(backgroundColor: Colors.white, foregroundColor: scheme.primary),
            tooltip: l.opsRefresh,
            onPressed: () {
              setState(() => _data = null);
              _load();
            },
            icon: const Icon(Icons.sync),
          ),
        ]),
      ),
    );
  }
}
