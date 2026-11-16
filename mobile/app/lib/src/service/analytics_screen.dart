import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import '../records/records.dart';
import '../vehicles/vehicle_form.dart' show kindLabel;
import 'fleet_export.dart';
import 'revenue.dart';
import 'service_data.dart';

/// „Raporty i Analityka” według projektu Stitch: przebiegi, kursy puste, koszt wozokilometra,
/// spalanie i ranking taboru z przejazdów TruckMaps (`/api/vehicles/{id}/stats`) i kosztów napraw
/// modułu Serwis, przychody ze zleceń transportowych i marża (`/api/companies/{id}/revenue/summary`,
/// tankowania z kart paliwowych, gdy są). Korytarze i zgodność prawna – „W budowie”.
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

  /// Przychody ze zleceń (`null` – brak dostępu) i tankowania z kart w PLN według pojazdu.
  Map<String, dynamic>? _revenue;
  Map<String?, double>? _fuel;

  /// Filtry: pojazd (id), rodzaj pojazdu, baza; ukryte KPI (ustawienie firmy).
  String? _vehicle, _kind, _base;
  Set<int> _hiddenKpis = const {};
  String? _schedule;

  FleetData _filtered(FleetData d) {
    bool keep(Map<String, dynamic> v) =>
        (_vehicle == null || v['id'] == _vehicle) &&
        (_kind == null || v['kind'] == _kind) &&
        (_base == null || v['base_name'] == _base);
    final vehicles = [
      for (final v in d.vehicles)
        if (keep(v) || d.vehicles.any((p) => keep(p) && p['trailer_id'] == v['id'])) v
    ];
    final ids = {for (final v in vehicles) '${v['id']}'};
    return FleetData(
      vehicles: vehicles,
      orders: d.orders,
      stats: {
        for (final e in d.stats.entries)
          if (ids.contains(e.key)) e.key: e.value
      },
      drivers: d.drivers,
    );
  }

  Future<void> _loadSettings() async {
    final company = widget.companyId;
    if (company == null) return;
    try {
      final s = await RecordsApi(widget.api, company).settings();
      if (!mounted) return;
      setState(() {
        _hiddenKpis = {for (final i in (s['analytics_hidden_kpis'] as List?) ?? const []) (i as num).toInt()};
        _schedule = s['report_schedule'] as String?;
      });
    } catch (_) {}
  }

  /// Wybór wartości filtra; `''` – wszystkie.
  Future<void> _pick(String title, List<(String, String)> options, String? current, ValueChanged<String?> set) async {
    final l = context.l;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(title: Text(title), children: [
        RadioListTile<String>(
            value: '', groupValue: current ?? '', title: Text(l.anAll), onChanged: (v) => Navigator.pop(context, v)),
        for (final (value, label) in options)
          RadioListTile<String>(
              value: value, groupValue: current ?? '', title: Text(label), onChanged: (v) => Navigator.pop(context, v)),
      ]),
    );
    if (chosen != null) setState(() => set(chosen.isEmpty ? null : chosen));
  }

  void _filterTap(String label) {
    final l = context.l;
    final data = _data;
    if (data == null) return;
    if (label == l.anVehicles) {
      _pick(label, [for (final v in data.power) ('${v['id']}', '${v['plate'] ?? v['name']}')], _vehicle,
          (v) => _vehicle = v);
    } else if (label == l.anSpec) {
      final kinds = {for (final v in data.power) '${v['kind']}'};
      _pick(label, [for (final k in kinds) (k, kindLabel(l, k))], _kind, (v) => _kind = v);
    } else if (label == l.anHub) {
      final bases = {
        for (final v in data.vehicles)
          if (v['base_name'] != null) '${v['base_name']}'
      };
      _pick(label, [for (final b in bases) (b, b)], _base, (v) => _base = v);
    }
  }

  /// Widoczne KPI (ustawienie firmy dla wszystkich w biurze).
  Future<void> _configKpis() async {
    final l = context.l;
    final titles = [l.anTotalKm, l.anCostKm, l.anRevenue, l.anBurn];
    final hidden = {..._hiddenKpis};
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialog) => AlertDialog(
          title: Text(l.anKpiConfig),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (i, t) in titles.indexed)
              CheckboxListTile(
                value: !hidden.contains(i),
                title: Text(t),
                onChanged: (on) => setDialog(() => on == true ? hidden.remove(i) : hidden.add(i)),
              ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.save)),
          ],
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _hiddenKpis = hidden);
    if (widget.companyId case final company?) {
      await RecordsApi(widget.api, company).putSetting('analytics_hidden_kpis', hidden.toList()..sort());
    }
  }

  /// Raport cykliczny do skrzynki biura (i e-mailem): co tydzień albo co miesiąc.
  Future<void> _configSchedule() async {
    final l = context.l;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(title: Text(l.anSchedule), children: [
        for (final (value, label) in [
          ('', l.anScheduleOff),
          ('weekly', l.anScheduleWeekly),
          ('monthly', l.anScheduleMonthly)
        ])
          RadioListTile<String>(
              value: value,
              groupValue: _schedule ?? '',
              title: Text(label),
              onChanged: (v) => Navigator.pop(context, v)),
      ]),
    );
    if (chosen == null || widget.companyId == null) return;
    await RecordsApi(widget.api, widget.companyId!).putSetting('report_schedule', chosen.isEmpty ? null : chosen);
    if (mounted) setState(() => _schedule = chosen.isEmpty ? null : chosen);
  }

  @override
  void initState() {
    super.initState();
    _load();
    _loadSettings();
  }

  Future<void> _load() async {
    try {
      final revenue = loadRevenueSummary(widget.api, widget.companyId, months: widget.months);
      final fuel = loadFuelCardCost(widget.api, widget.companyId, months: widget.months);
      final data = await FleetData.load(widget.api, widget.companyId, withStats: true, months: widget.months);
      final (r, f) = (await revenue, await fuel);
      if (mounted) {
        setState(() {
          _data = data;
          _revenue = r;
          _fuel = f;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Eksport tabeli pojazdów (km, godziny, koszty, serwis) do CSV – otwiera się w Excelu.
  Future<void> _export() async {
    final data = _data;
    if (data == null) return;
    final shown = _filtered(data);
    final revenue = {
      for (final v in uiMaps(_revenue?['vehicles'])) '${v['vehicle_id']}': ((v['total'] as num?) ?? 0).toDouble()
    };
    final rows =
        fleetReportRows(context.l, shown, (id) => _serviceCost(shown, id), revenue: _revenue == null ? null : revenue);
    final opened = await openCsv(toCsv(rows), 'raport-floty');
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.exportFailed)));
    }
  }

  /// Otwiera listę zleceń z przychodami; po zmianach odświeża podsumowanie.
  Future<void> _enterRevenue() async {
    final company = widget.companyId;
    if (company == null) return;
    final changed = await showDialog<bool>(
        context: context,
        builder: (_) => RevenueOrdersDialog(api: widget.api, companyId: company, months: widget.months));
    if (changed == true) {
      final r = await loadRevenueSummary(widget.api, company, months: widget.months);
      if (mounted) setState(() => _revenue = r);
    }
  }

  bool get _filtering => _vehicle != null || _kind != null || _base != null;

  double _serviceCost(FleetData data, String vehicleId) => data.done
      .where((o) => o['vehicle_id'] == vehicleId || data.vehicle(vehicleId)?['trailer_id'] == o['vehicle_id'])
      .fold(0.0, (a, o) => a + orderTotal(o));

  @override
  Widget build(BuildContext context) {
    final data = _data == null ? null : _filtered(_data!);
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
          for (final (i, k) in _kpis(context, data).indexed)
            if (!_hiddenKpis.contains(i)) SizedBox(width: kpiWidth, child: k),
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
                onPressed: () => label == l.anKpiConfig ? _configKpis() : _configSchedule(),
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
      (
        l.anVehicles,
        _vehicle == null
            ? l.anAllVehicles
            : '${_data?.vehicle(_vehicle)?['plate'] ?? _data?.vehicle(_vehicle)?['name'] ?? ''}',
        Icons.local_shipping_outlined,
        false
      ),
      (l.anSpec, _kind == null ? l.anAllTypes : kindLabel(l, _kind!), Icons.category_outlined, false),
      (l.anHub, _base ?? widget.companyName, Icons.warehouse_outlined, false),
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
                onTap: real ? null : () => _filterTap(label),
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

  /// Przychód w okresie dla pokazanych pojazdów (filtry) – suma, na km, zlecenia, waluty bez kursu.
  ({double total, double? perKm, int count, int orders, List<String> unconverted})? _revenueIn(FleetData data) {
    final r = _revenue;
    if (r == null) return null;
    final unconverted = [for (final c in (r['unconverted'] as List?) ?? const []) '$c'];
    if (!_filtering) {
      return (
        total: ((r['total'] as num?) ?? 0).toDouble(),
        perKm: (r['per_km'] as num?)?.toDouble(),
        count: ((r['count'] as num?) ?? 0).toInt(),
        orders: ((r['orders_total'] as num?) ?? 0).toInt(),
        unconverted: unconverted,
      );
    }
    final ids = {for (final v in data.vehicles) '${v['id']}'};
    final shown = [
      for (final v in uiMaps(r['vehicles']))
        if (ids.contains('${v['vehicle_id']}')) v
    ];
    final total = shown.fold(0.0, (a, v) => a + ((v['total'] as num?) ?? 0));
    final km = shown.fold(0.0, (a, v) => a + ((v['km'] as num?) ?? 0));
    return (
      total: total,
      perKm: km == 0 ? null : total / km,
      count: shown.fold(0, (a, v) => a + ((v['count'] as num?) ?? 0).toInt()),
      orders: uiMaps(r['orders']).where((o) => ids.contains('${o['vehicle_id']}')).length,
      unconverted: unconverted,
    );
  }

  /// Tankowania z kart (PLN) pokazanych pojazdów; bez filtrów – także tankowania bez pojazdu.
  double? _fuelIn(FleetData data) {
    final f = _fuel;
    if (f == null) return null;
    if (!_filtering) return f.values.fold<double>(0, (a, b) => a + b);
    final ids = {for (final v in data.vehicles) '${v['id']}'};
    return f.entries.where((e) => ids.contains(e.key)).fold<double>(0, (a, e) => a + e.value);
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
    final revenue = _revenueIn(data);
    final fuel = _fuelIn(data);
    // Tankowania z kart (gdy są) zastępują szacunek kosztów tras – jak w TCO, bez podwójnego paliwa.
    final cardFuel = fuel != null && fuel > 0;
    final costs = (cardFuel ? fuel : routeCost) + service;
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
          revenue == null ? '–' : l.number(revenue.total, decimals: 0),
          revenue == null ? '' : 'PLN',
          [
            if (revenue == null)
              Text(l.anRevenueNone, style: theme.textTheme.bodySmall)
            else ...[
              Text(l.anRevenuePerKm(revenue.perKm == null ? '–' : l.number(revenue.perKm!, decimals: 2)),
                  style: theme.textTheme.bodySmall),
              Text((!cardFuel ? l.anMarginCosts : l.anMarginCostsFuel)(l.number(costs, decimals: 0)),
                  style: theme.textTheme.bodySmall),
              Text(l.anMargin(l.number(revenue.total - costs, decimals: 0)),
                  key: const Key('an-margin'),
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: revenue.total - costs < 0 ? scheme.error : colors.success)),
              Text(l.anRevenueOrders(l.number(revenue.count), l.number(revenue.orders)),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (revenue.unconverted.isNotEmpty)
                Text(l.anRevenueUnconverted(revenue.unconverted.join(', ')),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.error)),
              if (widget.companyId != null)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('an-revenue-enter'),
                    onPressed: _enterRevenue,
                    icon: const Icon(Icons.edit_outlined, size: 16),
                    label: Text(l.anRevenueEnter),
                  ),
                ),
            ],
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
                          alignment: Alignment.centerRight,
                          child: Builder(builder: (context) {
                            final all = [
                              for (final (_, s2, sv2) in rows)
                                (((s2?['distance_km'] as num?) ?? 0).toDouble(), tripCosts(s2) + sv2)
                            ];
                            final fleetKm = all.fold(0.0, (a, x) => a + x.$1);
                            final fleetAvg = fleetKm == 0 ? 0.0 : all.fold(0.0, (a, x) => a + x.$2) / fleetKm;
                            if (km == 0 || fleetAvg == 0) return const Text('–');
                            final diff = ((routes + service) / km / fleetAvg - 1) * 100;
                            return Text('${diff >= 0 ? '+' : ''}${l.number(diff, decimals: 0)}%',
                                style: theme.textTheme.labelLarge
                                    ?.copyWith(color: diff > 10 ? scheme.error : (diff < -10 ? colors.success : null)));
                          }))),
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
