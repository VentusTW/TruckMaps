import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';

const _towed = {'semitrailer', 'trailer'};

/// Stan operacyjny pojazdu z danych serwera.
enum FleetStatus { driving, ready, service, reported }

FleetStatus fleetStatus(Map<String, dynamic> v) {
  if (v['in_repair'] == true) return FleetStatus.service;
  if (v['repair_reported'] == true) return FleetStatus.reported;
  if (v['in_use'] == true) return FleetStatus.driving;
  return FleetStatus.ready;
}

/// Kategorie zakładek (jak we wzorze); `null` – wszystkie.
enum FleetTab { all, tractors, curtains, reefers, swap }

/// Ekran „Pojazdy i Tabor” według projektu Stitch. Dane z `/api/vehicles` (pojazdy firmy);
/// czego API jeszcze nie ma (telemetria CAN, rampy, opony, naciski osi) – znacznik „W budowie”.
/// Każdy przycisk i odnośnik – [onOpen] (ekran „W budowie”).
class FleetScreen extends StatefulWidget {
  const FleetScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.onOpen,
    this.onOpenDriver,
    this.onOpenVehicle,
    this.pageSize = 5,
    this.today,
  });

  final CoreApi api;
  final String? companyId;
  final ValueChanged<String> onOpen;

  /// Kliknięcie kierowcy w tabeli – jego profil.
  final ValueChanged<String>? onOpenDriver;

  /// Kliknięcie wiersza – profil pojazdu (bez tego – „W budowie”).
  final void Function(String id, String name)? onOpenVehicle;
  final int pageSize;

  /// Dzień odniesienia terminów (testy podmieniają).
  final DateTime? today;

  @override
  State<FleetScreen> createState() => _FleetScreenState();
}

class _FleetScreenState extends State<FleetScreen> {
  List<Map<String, dynamic>>? _vehicles;
  List<String> _bases = const [];
  Object? _error;
  FleetTab _tab = FleetTab.all;
  FleetStatus? _status;
  String _query = '';
  int _page = 0;
  final _search = TextEditingController();

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(FleetScreen old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId) _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final list = uiMaps(await widget.api.get('/api/vehicles'));
      if (!mounted) return;
      setState(() {
        _vehicles = [
          for (final v in list)
            if (v['company_id'] == widget.companyId) v
        ];
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    // Bazy firmy (przyciski filtra) – dodatek: bez nich ekran działa dalej.
    final company = widget.companyId;
    if (company == null) return;
    try {
      final screen = await widget.api.get('/api/dashboard/screen?company_id=${Uri.encodeQueryComponent(company)}');
      if (mounted && screen is Map) {
        setState(() => _bases = [for (final b in screen['bases'] as List? ?? const []) '$b']);
      }
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _all => _vehicles ?? const [];
  List<Map<String, dynamic>> get _power => [
        for (final v in _all)
          if (!_towed.contains(v['kind'])) v
      ];
  List<Map<String, dynamic>> get _trailers => [
        for (final v in _all)
          if (_towed.contains(v['kind'])) v
      ];

  Map<String, dynamic>? _trailerOf(Map<String, dynamic> v) => _all.where((t) => t['id'] == v['trailer_id']).firstOrNull;

  bool _inTab(Map<String, dynamic> v, FleetTab tab) {
    final trailer = _trailerOf(v);
    return switch (tab) {
      FleetTab.all => true,
      FleetTab.tractors => v['kind'] == 'tractor',
      FleetTab.curtains => trailer?['trailer_type'] == 'curtain',
      FleetTab.reefers => trailer?['trailer_type'] == 'reefer' || v['trailer_type'] == 'reefer',
      FleetTab.swap => trailer?['trailer_type'] == 'container' || v['trailer_type'] == 'container',
    };
  }

  int _tabCount(FleetTab tab) => switch (tab) {
        FleetTab.all => _all.length,
        FleetTab.tractors => _all.where((v) => v['kind'] == 'tractor').length,
        FleetTab.curtains => _trailers.where((v) => v['trailer_type'] == 'curtain').length,
        FleetTab.reefers => _trailers.where((v) => v['trailer_type'] == 'reefer').length,
        FleetTab.swap => _all.where((v) => v['trailer_type'] == 'container').length,
      };

  List<Map<String, dynamic>> get _rows {
    final q = _query.trim().toLowerCase();
    return [
      for (final v in _power)
        if (_inTab(v, _tab) &&
            (_status == null ||
                fleetStatus(v) == _status ||
                (_status == FleetStatus.service && fleetStatus(v) == FleetStatus.reported)) &&
            (q.isEmpty ||
                [v['plate'], v['name'], v['vin'], v['driver_name'], v['assigned_driver_name'], _trailerOf(v)?['plate']]
                    .any((s) => '${s ?? ''}'.toLowerCase().contains(q))))
          v
    ];
  }

  DateTime? _date(dynamic s) => s == null ? null : DateTime.tryParse('$s');

  int _countDue(String field, int days) => _all.where((v) {
        final d = _date(v[field]);
        return d != null && !d.isAfter(_today.add(Duration(days: days)));
      }).length;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (_vehicles == null) {
      if (_error != null) {
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$_error', textAlign: TextAlign.center),
            const SizedBox(height: Gap.m),
            OutlinedButton(onPressed: _load, child: Text(l.retry)),
          ]),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final wide = inner >= 900;
      final kpiColumns = wide ? 5 : (inner >= 560 ? 3 : 1);
      final kpiWidth = (inner - gap * (kpiColumns - 1)) / kpiColumns;
      final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _filters(context),
        const SizedBox(height: gap),
        _table(context),
        const SizedBox(height: gap),
        _bottomCards(context, inner >= 700),
      ]);
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _canCard(context),
        const SizedBox(height: gap),
        _deadlinesCard(context),
        const SizedBox(height: gap),
        _axlesCard(context),
      ]);
      return ListView(padding: EdgeInsets.fromLTRB(pad, Gap.l, pad, pad), children: [
        _header(context),
        const SizedBox(height: gap),
        _tabs(context),
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          for (final card in _kpis(context)) SizedBox(width: kpiWidth, child: card),
        ]),
        const SizedBox(height: gap),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 8, child: left),
            const SizedBox(width: gap),
            Expanded(flex: 4, child: right),
          ])
        else ...[
          left,
          const SizedBox(height: gap),
          right,
        ],
      ]);
    });
  }

  // ------------------------------------------------------------------ nagłówek i zakładki

  Widget _header(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final crumbs = theme.textTheme.labelMedium;
    final open = widget.onOpen;
    Widget outlined(String label, IconData icon) => OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            backgroundColor: colors.card,
            foregroundColor: scheme.onSurface,
            side: BorderSide(color: colors.surfaceHigh),
          ),
          onPressed: () => open(label),
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(Icons.home_outlined, size: 14, color: scheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(l.fleetCrumbStart, style: crumbs?.copyWith(color: scheme.onSurfaceVariant)),
        Text('  /  ', style: crumbs?.copyWith(color: scheme.outline)),
        Text(l.mainMenuFleet, style: crumbs?.copyWith(color: scheme.primary)),
        Text('  /  ', style: crumbs?.copyWith(color: scheme.outline)),
        Text(l.fleetCrumbHub, style: crumbs?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
      const SizedBox(height: Gap.s),
      LayoutBuilder(builder: (context, size) {
        final title = Wrap(spacing: Gap.m, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(l.fleetTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
          UiTag(l.fleetUnits(l.number(_all.length)), tone: 'info', uppercase: false),
        ]);
        final buttons = Wrap(spacing: Gap.s, runSpacing: Gap.s, alignment: WrapAlignment.end, children: [
          outlined(l.fleetInspections, Icons.fact_check_outlined),
          outlined(l.fleetExport, Icons.download_outlined),
          FilledButton.icon(
            key: const Key('fleet-add'),
            style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
            onPressed: () => open(l.fleetAdd),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: Text(l.fleetAdd),
          ),
        ]);
        // Szeroko – tytuł po lewej, przyciski po prawej (jak we wzorze); wąsko – jedno pod drugim.
        return size.maxWidth >= 900
            ? Row(children: [
                Expanded(child: title),
                const SizedBox(width: Gap.xl),
                Flexible(child: buttons),
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                title,
                const SizedBox(height: Gap.m),
                buttons,
              ]);
      }),
    ]);
  }

  Widget _tabs(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final labels = {
      FleetTab.all: l.fleetTabAll,
      FleetTab.tractors: l.fleetTabTractors,
      FleetTab.curtains: l.fleetTabCurtains,
      FleetTab.reefers: l.fleetTabReefers,
      FleetTab.swap: l.fleetTabSwap,
    };
    return UiPanel(
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final MapEntry(key: tab, value: label) in labels.entries)
              Material(
                color: tab == _tab ? scheme.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                child: InkWell(
                  key: Key('fleet-tab-${tab.name}'),
                  borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                  onTap: () => setState(() {
                    _tab = tab;
                    _page = 0;
                  }),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(label,
                          style: theme.textTheme.labelMedium
                              ?.copyWith(color: tab == _tab ? scheme.onPrimaryContainer : scheme.onSurface)),
                      const SizedBox(width: Gap.s),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: tab == _tab ? scheme.onPrimaryContainer.withOpacity(0.2) : colors.surfaceHigh,
                          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                        ),
                        child: Text(l.number(_tabCount(tab)),
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: tab == _tab ? scheme.onPrimaryContainer : scheme.onSurface)),
                      ),
                    ]),
                  ),
                ),
              ),
          ]),
        ),
        IconButton(
          tooltip: l.fleetTabSettings,
          onPressed: () => widget.onOpen(l.fleetTabSettings),
          icon: Icon(Icons.tune_outlined, color: scheme.onSurfaceVariant),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ wskaźniki

  List<Widget> _kpis(BuildContext context) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final colors = TruckColors.of(context);
    final power = _power;
    final total = power.isEmpty ? 1 : power.length;
    int count(FleetStatus s) => power.where((v) => fleetStatus(v) == s).length;
    final driving = count(FleetStatus.driving);
    final ready = count(FleetStatus.ready);
    final service = count(FleetStatus.service);
    final reported = count(FleetStatus.reported);
    String pct(int n) => '${l.number(100 * n / total, decimals: 1)}%';
    final years = [
      for (final v in _all)
        if (v['production_year'] is num) _today.year - (v['production_year'] as num)
    ];
    final age = years.isEmpty ? null : years.reduce((a, b) => a + b) / years.length;
    final euro6 = power.where((v) => v['emission_class'] == 'euro6' || v['emission_class'] == 'electric').length;
    final unassigned =
        power.where((v) => fleetStatus(v) == FleetStatus.ready && v['assigned_driver_name'] == null).length;
    return [
      _Kpi(
        label: l.fleetKpiDriving,
        icon: Icons.trending_up,
        value: l.number(driving),
        badge: pct(driving),
        bar: driving / total,
        barColor: scheme.primaryContainer,
        left: Text(l.fleetKpiDrivingNote),
        right: WipTag(what: l.fleetKpiCanSpeed, onOpen: widget.onOpen),
      ),
      _Kpi(
        label: l.fleetKpiRamps,
        icon: Icons.forklift,
        value: '–',
        left: Text(l.fleetKpiRampsNote),
        right: WipTag(what: l.fleetKpiRamps, onOpen: widget.onOpen),
      ),
      _Kpi(
        label: l.fleetKpiReady,
        icon: Icons.check_circle_outline,
        iconColor: scheme.tertiaryContainer,
        value: l.number(ready),
        valueColor: scheme.tertiaryContainer,
        badge: pct(ready),
        bar: ready / total,
        barColor: scheme.tertiaryContainer,
        left: Text(l.fleetKpiUnassigned(l.number(unassigned))),
        right: Text(l.fleetKpiReadyNote, style: TextStyle(color: scheme.tertiaryContainer)),
      ),
      _Kpi(
        label: l.fleetKpiService,
        icon: Icons.handyman_outlined,
        iconColor: scheme.error,
        iconBackground: scheme.errorContainer,
        value: l.number(service + reported),
        valueColor: scheme.error,
        badge: pct(service + reported),
        bar: (service + reported) / total,
        barColor: scheme.error,
        left: Text(l.fleetKpiInRepair(l.number(service))),
        right: Text(l.fleetKpiReported(l.number(reported)), style: TextStyle(color: scheme.error)),
      ),
      _Kpi(
        label: l.fleetKpiAge,
        icon: Icons.shield_outlined,
        value: age == null ? '–' : l.number(age, decimals: 1),
        unit: l.fleetKpiYears,
        bar: power.isEmpty ? null : euro6 / total,
        barColor: colors.success,
        left: Text(l.fleetKpiEuro6(pct(euro6))),
        right: WipTag(what: l.fleetKpiWarranty, onOpen: widget.onOpen),
      ),
    ];
  }

  // ------------------------------------------------------------------ filtry i tabela

  Widget _filters(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final power = _power;
    int count(bool Function(FleetStatus) test) => power.where((v) => test(fleetStatus(v))).length;
    Widget base(String label, bool selected) => Material(
          color: selected ? scheme.secondaryContainer : colors.surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
            onTap: selected ? null : () => widget.onOpen(label),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.s),
              child: Text(label,
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: selected ? scheme.onSecondaryContainer : scheme.onSurface)),
            ),
          ),
        );
    Widget chip(String label, FleetStatus? status, {bool alarm = false, VoidCallback? onTap}) {
      final selected = status != null && status == _status;
      return InkWell(
        key: Key('fleet-status-${status?.name ?? label}'),
        borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        onTap: onTap ??
            () => setState(() {
                  _status = selected ? null : status;
                  _page = 0;
                }),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 4),
          decoration: BoxDecoration(
            color: alarm ? scheme.errorContainer : (selected ? scheme.primaryContainer : colors.surfaceLow),
            borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          ),
          child: Text(label,
              style: theme.textTheme.labelMedium?.copyWith(
                  color: alarm ? scheme.onErrorContainer : (selected ? scheme.onPrimaryContainer : scheme.primary))),
        ),
      );
    }

    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SizedBox(
            width: 260,
            child: TextField(
              key: const Key('fleet-search'),
              controller: _search,
              onChanged: (q) => setState(() {
                _query = q;
                _page = 0;
              }),
              style: theme.textTheme.bodyMedium,
              decoration: InputDecoration(
                isDense: true,
                hintText: l.fleetSearchHint,
                prefixIcon: Icon(Icons.search, size: 20, color: scheme.outline),
                suffixIcon: TextButton(
                  onPressed: () => setState(() {
                    _search.clear();
                    _query = '';
                  }),
                  child: Text(l.fleetClear, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                ),
              ),
            ),
          ),
          base(l.fleetAllBases, true),
          for (final b in _bases) base(b, false),
        ]),
        const SizedBox(height: Gap.m),
        Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(l.fleetQuickFilter.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.6)),
          chip(l.fleetFilterDriving(l.number(count((s) => s == FleetStatus.driving))), FleetStatus.driving),
          chip(l.fleetFilterRamps, null, onTap: () => widget.onOpen(l.fleetFilterRamps)),
          chip(l.fleetFilterReady(l.number(count((s) => s == FleetStatus.ready))), FleetStatus.ready),
          chip(l.fleetFilterService(l.number(count((s) => s == FleetStatus.service || s == FleetStatus.reported))),
              FleetStatus.service,
              alarm: true),
          const SizedBox(width: Gap.m),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.sync_outlined, size: 16, color: scheme.outline),
            const SizedBox(width: 4),
            Text(l.fleetCanRefresh, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
            const SizedBox(width: 4),
            WipTag(what: l.fleetCanRefresh, onOpen: widget.onOpen),
          ]),
        ]),
      ]),
    );
  }

  Widget _table(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final rows = _rows;
    final pages = (rows.length / widget.pageSize).ceil().clamp(1, 1 << 30);
    final page = _page.clamp(0, pages - 1);
    final shown = rows.skip(page * widget.pageSize).take(widget.pageSize).toList();
    final head = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.6);
    Widget pageButton(String label, int? target, {bool selected = false}) => Padding(
          padding: const EdgeInsets.only(left: Gap.xs),
          child: Material(
            color: selected ? scheme.primaryContainer : colors.card,
            borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
            child: InkWell(
              borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
              onTap: target == null ? null : () => setState(() => _page = target),
              child: Container(
                constraints: const BoxConstraints(minWidth: 32),
                padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(color: selected ? scheme.primaryContainer : colors.surfaceHigh),
                  borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                ),
                child: Text(label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: selected
                            ? scheme.onPrimaryContainer
                            : (target == null ? scheme.outline : scheme.onSurface))),
              ),
            ),
          ),
        );
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: colors.surfaceLow,
          padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
          child: Row(children: [
            Expanded(flex: 10, child: Text(l.fleetColVehicle.toUpperCase(), style: head)),
            Expanded(flex: 6, child: Text(l.fleetColDriver.toUpperCase(), style: head)),
            Expanded(flex: 6, child: Text(l.fleetColStatus.toUpperCase(), style: head)),
            Expanded(flex: 6, child: Text(l.fleetColTelemetry.toUpperCase(), style: head)),
          ]),
        ),
        if (shown.isEmpty) Padding(padding: const EdgeInsets.all(Gap.l), child: UiEmpty(l.fleetEmpty)),
        for (final v in shown) _row(context, v),
        Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: Gap.s,
            children: [
              Text(
                  l.fleetShown(
                    l.number(rows.isEmpty ? 0 : page * widget.pageSize + 1),
                    l.number(page * widget.pageSize + shown.length),
                    l.number(rows.length),
                  ),
                  style: theme.textTheme.bodySmall),
              Row(mainAxisSize: MainAxisSize.min, children: [
                pageButton(l.fleetPrev, page > 0 ? page - 1 : null),
                for (var i = 0; i < pages && i < 5; i++) pageButton('${i + 1}', i, selected: i == page),
                if (pages > 5) pageButton('…', null),
                pageButton(l.fleetNext, page < pages - 1 ? page + 1 : null),
              ]),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> v) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final status = fleetStatus(v);
    final trailer = _trailerOf(v);
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final service = status == FleetStatus.service || status == FleetStatus.reported;
    final driver = (v['driver_name'] ?? v['assigned_driver_name']) as String?;
    final initials = driver == null
        ? '–'
        : driver.trim().split(RegExp(r'\s+')).take(2).map((p) => p.isEmpty ? '' : p[0]).join().toUpperCase();
    final euro = switch (v['emission_class']) {
      'euro6' => 'EURO 6',
      'euro5' => 'EURO 5',
      'euro4' => 'EURO 4',
      'euro3' => 'EURO 3',
      'electric' => 'EV',
      _ => null,
    };
    final (String tag, String tone) = switch (status) {
      FleetStatus.service => (l.fleetTagService, 'error'),
      FleetStatus.reported => (l.fleetTagReported, 'error'),
      FleetStatus.ready when driver == null => (l.fleetTagReady, 'tertiary'),
      _ => (euro ?? '', 'info'),
    };
    final (String statusText, Color statusBg, Color statusFg) = switch (status) {
      FleetStatus.driving => (l.fleetStatusDriving, scheme.secondaryContainer, scheme.onSecondaryContainer),
      FleetStatus.ready => (l.fleetStatusReady, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      FleetStatus.service => (l.fleetStatusService, scheme.errorContainer, scheme.onErrorContainer),
      FleetStatus.reported => (l.fleetStatusReported, scheme.errorContainer, scheme.onErrorContainer),
    };
    final deadlines = [
      for (final (field, label) in [
        ('inspection_until', l.fleetDueInspection),
        ('tachograph_until', l.fleetDueTachograph),
        ('udt_until', l.fleetDueUdt),
      ])
        if (_date(v[field]) case final d?) (d, label)
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final next = deadlines.firstOrNull;
    final format = DateFormat.yMd(l.localeName);
    return InkWell(
      key: Key('fleet-row-${v['id']}'),
      onTap: () => widget.onOpenVehicle != null
          ? widget.onOpenVehicle!('${v['id']}', '${v['plate'] ?? v['name']}')
          : widget.onOpen('${v['plate'] ?? v['name']}'),
      child: Container(
        decoration: BoxDecoration(
          color: service ? scheme.errorContainer.withOpacity(0.25) : null,
          border: Border(top: BorderSide(color: colors.surfaceHigh)),
        ),
        padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.l),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            flex: 10,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: service ? scheme.errorContainer : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(TruckTheme.radius),
                ),
                child: Icon(service ? Icons.build_outlined : Icons.local_shipping_outlined,
                    size: 20, color: service ? scheme.error : scheme.primary),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('${v['plate'] ?? v['name']}', style: theme.textTheme.titleSmall?.copyWith(fontSize: 15)),
                    if (tag.isNotEmpty) UiTag(tag, tone: tone),
                  ]),
                  Text(
                      [
                        '${v['name']}',
                        if (v['production_year'] != null) '(${v['production_year']})',
                      ].join(' '),
                      style: small),
                  if (trailer != null) ...[
                    const SizedBox(height: Gap.xs),
                    Row(children: [
                      Icon(trailer['trailer_type'] == 'reefer' ? Icons.ac_unit_outlined : Icons.rv_hookup_outlined,
                          size: 14, color: scheme.outline),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                            [if (trailer['plate'] != null) '${trailer['plate']}', '${trailer['name']}'].join('  •  '),
                            style: small?.copyWith(color: scheme.outline)),
                      ),
                    ]),
                  ],
                ]),
              ),
            ]),
          ),
          Expanded(
            flex: 6,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(
                radius: 12,
                backgroundColor: scheme.secondaryContainer,
                child: Text(initials,
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer, fontSize: 9)),
              ),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  InkWell(
                    key: Key('fleet-driver-${v['id']}'),
                    onTap: driver == null || widget.onOpenDriver == null ? null : () => widget.onOpenDriver!(driver),
                    child: Text(driver ?? l.fleetNoDriver,
                        style: theme.textTheme.labelLarge?.copyWith(
                            color: driver == null ? scheme.outline : scheme.primary,
                            decoration: driver == null ? null : TextDecoration.underline,
                            decorationColor: scheme.primary.withOpacity(0.4))),
                  ),
                  Text(
                      switch ((status, driver)) {
                        (FleetStatus.driving, _) => l.fleetDriverDriving,
                        (_, null) => l.fleetDriverNone,
                        _ => l.fleetDriverAssigned,
                      },
                      style: small),
                ]),
              ),
            ]),
          ),
          Expanded(
            flex: 6,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
                decoration: BoxDecoration(color: statusBg, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
                child: Text(statusText, style: theme.textTheme.labelMedium?.copyWith(color: statusFg)),
              ),
              if (next != null) ...[
                const SizedBox(height: Gap.xs),
                Text(l.fleetNextDue(next.$2, format.format(next.$1)),
                    style: small?.copyWith(
                        color: next.$1.isBefore(_today.add(const Duration(days: 14))) ? scheme.error : null)),
              ],
            ]),
          ),
          Expanded(
            flex: 6,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.local_gas_station_outlined, size: 14, color: scheme.outline),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                      v['consumption_loaded'] == null
                          ? '–'
                          : l.fleetConsumption(l.number(v['consumption_loaded'] as num, decimals: 1)),
                      style: small),
                ),
              ]),
              const SizedBox(height: Gap.xs),
              WipTag(what: l.fleetColTelemetry, onOpen: widget.onOpen),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _bottomCards(BuildContext context, bool row) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final insured = _all.where((v) {
      final d = _date(v['insurance_until']);
      return d != null && !d.isBefore(_today);
    }).length;
    final ocp = _all.where((v) {
      final d = _date(v['ocp_until']);
      return d != null && !d.isBefore(_today);
    }).length;
    final burns = [
      for (final v in _power)
        if (v['consumption_loaded'] is num) (v['consumption_loaded'] as num)
    ];
    final burn = burns.isEmpty ? null : burns.reduce((a, b) => a + b) / burns.length;
    Widget card(IconData icon, String title, List<Widget> body) => UiPanel(
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, color: scheme.primary, size: 22),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: Gap.xs),
                ...body,
              ]),
            ),
          ]),
        );
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final cards = [
      card(Icons.tire_repair_outlined, l.fleetTyres, [
        Text(l.fleetTyresNote, style: small),
        const SizedBox(height: Gap.xs),
        WipTag(what: l.fleetTyres, onOpen: widget.onOpen),
      ]),
      card(Icons.shield_outlined, l.fleetPolicies, [
        Text(l.fleetPoliciesOc(l.number(insured), l.number(_all.length)), style: small),
        const SizedBox(height: Gap.xs),
        Text(l.fleetPoliciesOcp(l.number(ocp)),
            style: theme.textTheme.labelMedium?.copyWith(color: TruckColors.of(context).success)),
      ]),
      card(Icons.speed_outlined, l.fleetBurn, [
        Text(burn == null ? '–' : l.fleetConsumption(l.number(burn, decimals: 1)), style: small),
        const SizedBox(height: Gap.xs),
        Text(l.fleetBurnNote, style: theme.textTheme.labelMedium?.copyWith(color: scheme.outline)),
      ]),
    ];
    if (!row) {
      return Column(children: [
        for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: c),
      ]);
    }
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, c) in cards.indexed) ...[if (i > 0) const SizedBox(width: 20), Expanded(child: c)],
      ]),
    );
  }

  // ------------------------------------------------------------------ prawa kolumna

  Widget _canCard(BuildContext context) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.fleetCanTitle,
          subtitle: l.fleetCanSubtitle,
          icon: Icons.sensors_outlined,
          iconColor: scheme.tertiaryContainer,
          trailing: WipTag(what: l.fleetCanTitle, onOpen: widget.onOpen),
        ),
        const SizedBox(height: Gap.m),
        UiEmpty(l.fleetCanNone),
      ]),
    );
  }

  Widget _deadlinesCard(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final format = DateFormat('dd.MM', l.localeName);
    final tacho = [
      for (final v in _all)
        if (_date(v['tachograph_until']) case final d? when !d.isAfter(_today.add(const Duration(days: 30)))) d
    ]..sort();
    final udt = _all.where((v) => v['udt_until'] != null).length;
    final udtDue = _countDue('udt_until', 30);
    Widget item(IconData icon, String title, String text, Widget trailing, {bool alarm = false}) => UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: alarm ? scheme.errorContainer : colors.card,
                borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
              ),
              child: Icon(icon, size: 18, color: alarm ? scheme.error : scheme.primary),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, style: theme.textTheme.labelLarge),
                Text(text, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
            const SizedBox(width: Gap.s),
            trailing,
          ]),
        );
    final inspections = _countDue('inspection_until', 14);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.fleetDeadlinesTitle,
          subtitle: l.fleetDeadlinesSubtitle,
          icon: Icons.verified_user_outlined,
          iconColor: scheme.error,
          iconBackground: scheme.errorContainer,
          trailing: TextButton(
            onPressed: () => widget.onOpen(l.fleetCalendar),
            child: Text('${l.fleetCalendar} ›'),
          ),
        ),
        const SizedBox(height: Gap.l),
        item(
          Icons.car_crash_outlined,
          l.fleetSkp,
          l.fleetSkpNote(l.number(inspections)),
          inspections == 0
              ? Text(l.fleetOk, style: theme.textTheme.labelMedium?.copyWith(color: colors.success))
              : OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    foregroundColor: scheme.error,
                    side: BorderSide(color: colors.surfaceHigh),
                    backgroundColor: colors.card,
                  ),
                  onPressed: () => widget.onOpen(l.fleetBook),
                  child: Text(l.fleetBook),
                ),
          alarm: inspections > 0,
        ),
        item(
          Icons.speed_outlined,
          l.fleetTacho,
          l.fleetTachoNote(l.number(tacho.length)),
          Text(tacho.isEmpty ? l.fleetOk : l.fleetDueOn(format.format(tacho.first)),
              style: theme.textTheme.labelMedium?.copyWith(color: tacho.isEmpty ? colors.success : scheme.onSurface)),
        ),
        item(
          Icons.precision_manufacturing_outlined,
          l.fleetUdt,
          l.fleetUdtNote(l.number(udt)),
          Text(udtDue == 0 ? l.fleetOk : l.fleetUdtDue(l.number(udtDue)),
              style: theme.textTheme.labelMedium?.copyWith(color: udtDue == 0 ? colors.success : scheme.error)),
        ),
      ]),
    );
  }

  Widget _axlesCard(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final sample = _power.where((v) => v['kind'] == 'tractor').firstOrNull ?? _power.firstOrNull;
    final trailer = sample == null ? null : _trailerOf(sample);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.fleetAxlesTitle,
          subtitle: sample == null
              ? null
              : l.fleetAxlesSample(
                  [sample['plate'] ?? sample['name'], if (trailer != null) trailer['name']].join(' / ')),
          icon: Icons.view_in_ar_outlined,
          trailing: sample?['gvw_t'] is num
              ? UiTag(l.fleetDmc(l.number(sample!['gvw_t'] as num, decimals: 1)), tone: 'info', uppercase: false)
              : null,
        ),
        const SizedBox(height: Gap.l),
        UiBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (sample != null)
              Text(
                  l.fleetAxlesParams(l.number(sample['axle_count'] as num? ?? 0),
                      l.number(sample['axle_load_t'] as num? ?? 0, decimals: 1)),
                  style: theme.textTheme.bodySmall),
            const SizedBox(height: Gap.s),
            Row(children: [
              Expanded(
                  child: Text(l.fleetAxlesLoads,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant))),
              WipTag(what: l.fleetAxlesTitle, onOpen: widget.onOpen),
            ]),
          ]),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => widget.onOpen(l.mainMenuLoad3d),
            child: Text(l.fleetOpen3d),
          ),
        ),
        const SizedBox(height: Gap.s),
        FilledButton.icon(
          style: FilledButton.styleFrom(
            backgroundColor: colors.surfaceLow,
            foregroundColor: scheme.primary,
            padding: const EdgeInsets.symmetric(vertical: Gap.l),
          ),
          onPressed: () => widget.onOpen(l.fleetHomologation),
          icon: const Icon(Icons.tune_outlined, size: 18),
          label: Text(l.fleetHomologation),
        ),
      ]),
    );
  }
}

/// Karta wskaźnika taboru: etykieta, ikona, liczba z udziałem procentowym, pasek, dwie linie stopki.
class _Kpi extends StatelessWidget {
  const _Kpi({
    required this.label,
    required this.icon,
    required this.value,
    required this.left,
    required this.right,
    this.unit,
    this.badge,
    this.bar,
    this.barColor,
    this.valueColor,
    this.iconColor,
    this.iconBackground,
  });

  final String label;
  final IconData icon;
  final String value;
  final String? unit;
  final String? badge;
  final double? bar;
  final Color? barColor;
  final Color? valueColor;
  final Color? iconColor;
  final Color? iconBackground;
  final Widget left;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final small = theme.textTheme.bodySmall!.copyWith(color: scheme.onSurfaceVariant);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(label.toUpperCase(),
                  maxLines: 2,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.6)),
            ),
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconBackground ?? colors.surfaceLow,
                borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
              ),
              child: Icon(icon, size: 18, color: iconColor ?? scheme.primary),
            ),
          ]),
          const SizedBox(height: Gap.s),
          Wrap(spacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(value,
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w700, color: valueColor ?? scheme.onSurface)),
            if (unit != null) Text(unit!, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
            if (badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                    color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
                child: Text(badge!, style: theme.textTheme.labelSmall?.copyWith(color: valueColor ?? scheme.primary)),
              ),
          ]),
          const SizedBox(height: Gap.m),
          SizedBox(
            height: 6,
            child: bar == null ? null : TruckProgressBar(value: bar!, height: 6, color: barColor),
          ),
          const SizedBox(height: Gap.m),
          DefaultTextStyle(
            style: small,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: left),
              const SizedBox(width: Gap.s),
              Flexible(child: Align(alignment: Alignment.topRight, child: right)),
            ]),
          ),
        ]),
      ),
    );
  }
}
