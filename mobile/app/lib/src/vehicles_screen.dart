import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n.dart';
import 'vehicles/fleet_widgets.dart';
import 'vehicles/service_dates.dart';
import 'vehicles/vehicle_actions.dart';
import 'vehicles/vehicle_card.dart';
import 'vehicles/vehicle_form.dart';
import 'vehicles/vehicle_state.dart';
import 'vehicles/permits_screen.dart';
import 'vehicles/vehicle_stats.dart';
import 'vehicles/vehicles_table.dart';

/// Profile pojazdów konta (prywatne i firmowe) – wymiary, według których liczona jest trasa.
/// Dodawanie, zmiana i usuwanie; pojazd firmy zmieniają właściciel i dyspozytorzy.
/// Widok kafelków (przeciąganie naczep na pojazd) albo tabeli z zakładkami – wybór zapamiętany na urządzeniu.
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen(
      {super.key,
      required this.api,
      this.onChanged,
      this.refresh,
      this.sections = const [],
      this.actions = const [],
      this.onPlanRoute,
      this.viewStore = const SecureVehiclesViewStore()});

  /// Sekcje i szybkie akcje modułów na karcie pojazdu.
  final List<VehicleSection> sections;
  final List<VehicleAction> actions;

  /// „Zaplanuj trasę” z karty pojazdu.
  final ValueChanged<Map<String, dynamic>>? onPlanRoute;

  final CoreApi api;
  final VehiclesViewStore viewStore;

  /// Po każdej zmianie listy (np. planer odświeża wybór pojazdu).
  final VoidCallback? onChanged;

  /// Sygnał „pobierz listę od nowa” (np. wejście na ekran).
  final Listenable? refresh;

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  late Future<dynamic> _vehicles = widget.api.get('/api/vehicles');
  bool _table = false;
  String _query = '';

  /// Filtr bazy: `null` – wszystkie, `''` – bez bazy, inaczej id bazy.
  String? _base;

  /// Wszystkie bazy firm użytkownika – także te, do których nie przypisano jeszcze pojazdu.
  List<Map<String, dynamic>> _allBases = const [];

  Future<void> _loadBases() async {
    try {
      final bases = (await widget.api.get('/api/bases') as List<dynamic>).cast<Map<String, dynamic>>();
      if (mounted) setState(() => _allBases = bases);
    } catch (_) {
      // Bez listy baz filtr pokazuje bazy z pojazdów.
    }
  }

  /// Sortowanie po bazie (potem po nazwie).
  bool _byBase = false;

  /// Filtr rodzaju pojazdu (`null` – wszystkie).
  String? _kindFilter;

  /// Szybki filtr stanu: 'inUse', 'free', 'service', 'due' (`null` – wszystkie).
  String? _stateFilter;

  /// Telefon: filtry baz i stanu rozwinięte (domyślnie schowane, żeby lista miała miejsce).
  bool _filtersOpen = false;

  static bool _matchesState(Map<String, dynamic> v, String? filter) {
    final state = vehicleState(v);
    return switch (filter) {
      'inUse' => state == VehicleState.inUse,
      'free' => state == VehicleState.free,
      'service' => state == VehicleState.repair || state == VehicleState.reported,
      'due' => mostUrgent(v) != null || serviceKmLeft(v) != null,
      _ => true,
    };
  }

  @override
  void initState() {
    super.initState();
    widget.refresh?.addListener(_refresh);
    _loadBases();
    widget.viewStore.readTable().then((table) {
      if (mounted && table != _table) setState(() => _table = table);
    });
  }

  void _setTable(bool table) {
    setState(() => _table = table);
    widget.viewStore.writeTable(table);
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_refresh);
    super.dispose();
  }

  /// Świeża lista bez powiadamiania innych ekranów (nic się tu nie zmieniło).
  void _refresh() {
    final vehicles = widget.api.get('/api/vehicles');
    setState(() {
      _vehicles = vehicles;
    });
    _loadBases();
  }

  void _reload() {
    final vehicles = widget.api.get('/api/vehicles');
    setState(() {
      _vehicles = vehicles;
    });
    _loadBases();
    widget.onChanged?.call();
  }

  Future<void> _after(Future<bool> action) async {
    if (await action && mounted) _reload();
  }

  void _open([Map<String, dynamic>? vehicle]) => _after(openVehicleForm(context, widget.api, vehicle));

  void _service(Map<String, dynamic> vehicle) => _after(openServiceDates(context, widget.api, vehicle));

  void _driver(Map<String, dynamic> vehicle) => _after(assignDriver(context, widget.api, vehicle));

  void _stats(Map<String, dynamic> vehicle) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => VehicleStatsScreen(api: widget.api, vehicle: vehicle)));

  void _delete(Map<String, dynamic> vehicle) => _after(deleteVehicle(context, widget.api, vehicle));

  void _couple(Map<String, dynamic> vehicle, Map<String, dynamic>? trailer) =>
      _after(coupleTrailer(context, widget.api, vehicle, trailer));

  void _chooseTrailer(Map<String, dynamic> vehicle, List<Map<String, dynamic>> trailers) =>
      _after(chooseTrailer(context, widget.api, vehicle, trailers));

  /// Karta pojazdu: wszystko o pojeździe w jednym miejscu.
  Future<void> _card(Map<String, dynamic> vehicle) async {
    await Navigator.of(context).push<dynamic>(MaterialPageRoute(
      builder: (_) => VehicleCardScreen(
        api: widget.api,
        vehicle: vehicle,
        sections: widget.sections,
        actions: widget.actions,
        onChanged: widget.onChanged,
        onPlanRoute: widget.onPlanRoute,
      ),
    ));
    if (mounted) _refresh();
  }

  List<VehicleAction> _moduleActions(Map<String, dynamic> v) => [
        for (final a in widget.actions)
          if (a.applies?.call(v) ?? true) a,
      ];

  void _runAction(VehicleAction action, Map<String, dynamic> vehicle) =>
      _after(action.run(context, vehicle).then((changed) {
        if (changed) widget.onChanged?.call();
        return changed;
      }));

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      floatingActionButton: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.end, children: [
        FloatingActionButton.small(
          heroTag: 'permits',
          tooltip: l.permitsTitle,
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => PermitsScreen(api: widget.api))),
          child: const Icon(Icons.verified_outlined),
        ),
      ]),
      body: FutureBuilder<dynamic>(
        future: _vehicles,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${snapshot.error}'),
                TextButton(onPressed: _reload, child: Text(l.retry)),
              ]),
            );
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final vehicles = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
          if (vehicles.isEmpty) {
            return Column(children: [
              _heading(l, 0),
              Expanded(child: Center(child: Text(l.vehiclesEmpty))),
            ]);
          }
          final trailers = [for (final v in vehicles) if (!isDrivable(v)) v];
          final byId = {for (final v in vehicles) v['id']: v};
          final bases = <String, String>{
            for (final b in _allBases)
              '${b['id']}': [b['name'], if ('${b['code'] ?? ''}'.isNotEmpty) b['code']].join(' · '),
            for (final v in vehicles)
              if (v['base_id'] != null && !_allBases.any((b) => b['id'] == v['base_id']))
                '${v['base_id']}': '${v['base_name'] ?? v['base_id']}',
          };
          final shown = [
            for (final v in vehicles)
              if (matchesVehicle(v, _query) &&
                  (_base == null || (v['base_id'] ?? '') == _base) &&
                  (_kindFilter == null || v['kind'] == _kindFilter) &&
                  _matchesState(v, _stateFilter))
                v,
          ];
          if (_byBase) {
            String key(Map<String, dynamic> v) => '${v['base_name'] ?? '~'} ${v['name']}'.toLowerCase();
            shown.sort((a, b) => key(a).compareTo(key(b)));
          }
          final shownMotors = [for (final v in shown) if (isDrivable(v)) v];
          final shownTrailers = [for (final v in shown) if (!isDrivable(v)) v];
          final empty = _query.trim().isEmpty ? null : l.vehiclesNoMatch;
          final states = {for (final v in shown) vehicleState(v)}..remove(VehicleState.free);
          final width = MediaQuery.sizeOf(context).width;
          // Komputer: liczby floty nad listą, „wymaga uwagi” obok – jak w projekcie taboru.
          final soonTiles = [
            SoonTile(title: l.soonTelemetry, icon: Icons.sensors),
            SoonTile(title: l.soonTpms, icon: Icons.tire_repair),
            SoonTile(title: l.soonDtc, icon: Icons.error_outline),
            SoonTile(title: l.soonReefer, icon: Icons.ac_unit),
            SoonTile(title: l.soonWorkshop, icon: Icons.handyman_outlined),
            SoonTile(title: l.soonPolicies, icon: Icons.shield_outlined),
            SoonTile(title: l.soonFleetAge, icon: Icons.eco_outlined),
          ];
          Widget framed(Widget content) {
            final header = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _heading(l, vehicles.length),
              _kinds(l, vehicles),
              if (width >= 720)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: LayoutBuilder(builder: (context, size) {
                    final width = (size.maxWidth - Gap.m * 3) / 4;
                    return FleetKpis(vehicles: vehicles, width: width);
                  }),
                ),
              _toolbar(l, states, bases, vehicles),
            ]);
            final main = Column(children: [header, Expanded(child: content)]);
            if (width < 1300) return main;
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: main),
              SizedBox(
                width: 360,
                child: ListView(padding: const EdgeInsets.fromLTRB(0, 12, 12, 88), children: [
                  SectionCard(
                    title: l.dashVehiclesTitle,
                    icon: Icons.event_note_outlined,
                    child: VehiclesAttention(
                      vehicles: vehicles,
                      onOpen: _card,
                      limit: 12,
                      empty: Text(l.dashVehiclesOk),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, Gap.l, 4, Gap.s),
                    child: SectionLabel(l.soonTitle),
                  ),
                  for (final tile in soonTiles) Padding(padding: const EdgeInsets.only(bottom: Gap.s), child: tile),
                ]),
              ),
            ]);
          }

          if (_table) return framed(_tables(l, shownMotors, shownTrailers, trailers, byId, empty));

          Widget motorCard(Map<String, dynamic> v) => _VehicleCard(
                vehicle: v,
                onOpen: () => _card(v),
                moduleActions: _moduleActions(v),
                onAction: (a) => _runAction(a, v),
                onEdit: () => _open(v),
                onDelete: () => _delete(v),
                onService: () => _service(v),
                onStats: () => _stats(v),
                onDriver: () => _driver(v),
                coupling: couples.containsKey(v['kind'])
                    ? _CouplingSlot(
                        vehicle: v,
                        trailer: byId[v['trailer_id']],
                        accepts: (t) => t['kind'] == couples[v['kind']] && !trailerBusy(t, v),
                        onDrop: (t) => _couple(v, t),
                        onChoose: () => _chooseTrailer(v, trailers),
                        onUncouple: () => _couple(v, null),
                        free: freeTrailers(v, trailers),
                      )
                    : null,
              );
          Widget trailerCard(Map<String, dynamic> t) => _DraggableTrailer(
                trailer: t,
                child: _VehicleCard(
                    vehicle: t,
                    onOpen: () => _card(t),
                    moduleActions: _moduleActions(t),
                    onAction: (a) => _runAction(a, t),
                    onEdit: () => _open(t),
                    onDelete: () => _delete(t),
                    onService: () => _service(t)),
              );
          List<Widget> section(String title, List<Map<String, dynamic>> items, Widget Function(Map<String, dynamic>) card,
                  String empty) =>
              [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
                  child: Text(title, style: Theme.of(context).textTheme.titleSmall),
                ),
                if (items.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(empty)),
                for (final item in items) Padding(padding: const EdgeInsets.only(bottom: 8), child: card(item)),
              ];
          final motorList = section(l.vehiclesMotor, shownMotors, motorCard, empty ?? l.vehiclesMotorEmpty);
          final trailerList = section(l.vehiclesTowed, shownTrailers, trailerCard, empty ?? l.vehiclesTowedEmpty);
          const padding = EdgeInsets.fromLTRB(12, 4, 12, 88);
          // Szeroki ekran: samochody po lewej, naczepy i przyczepy po prawej (przeciąganie na pojazd).
          if (width >= 900) {
            return framed(Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: ListView(padding: padding, children: motorList)),
              Expanded(child: ListView(padding: padding, children: trailerList)),
            ]));
          }
          return framed(ListView(padding: padding, children: [
            ...motorList,
            ...trailerList,
            if (width < 1300) ...[
              Padding(padding: const EdgeInsets.fromLTRB(4, 16, 4, 8), child: SectionLabel(l.soonTitle)),
              for (final tile in soonTiles) Padding(padding: const EdgeInsets.only(bottom: 8), child: tile),
            ],
          ]));
        },
      ),
    );
  }

  /// Nagłówek: tytuł z liczbą jednostek i akcje (przeglądy, eksport – w budowie; dodanie pojazdu).
  Widget _heading(AppLocalizations l, int count) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: Gap.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        alignment: WrapAlignment.spaceBetween,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(l.vehiclesFleetTitle, style: theme.textTheme.headlineSmall),
            const SizedBox(width: Gap.s),
            StatusChip(label: l.vehiclesFleetUnits(l.number(count)), tone: StatusTone.info, icon: Icons.local_shipping),
          ]),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            SoonButton(label: l.soonInspections, icon: Icons.event_note_outlined),
            SoonButton(label: l.soonCepik, icon: Icons.file_download_outlined),
            FilledButton.icon(
              key: const Key('vehicles-add'),
              onPressed: _open,
              icon: const Icon(Icons.add_circle_outline),
              label: Text(l.vehicleAdd),
            ),
          ]),
        ],
      ),
    );
  }

  /// Rodzaje pojazdów z licznikami (jak segmenty w projekcie taboru).
  Widget _kinds(AppLocalizations l, List<Map<String, dynamic>> vehicles) {
    final counts = <String, int>{};
    for (final v in vehicles) {
      final kind = '${v['kind']}';
      counts[kind] = (counts[kind] ?? 0) + 1;
    }
    Widget segment(String? kind, String label, int count) {
      final selected = _kindFilter == kind;
      final scheme = Theme.of(context).colorScheme;
      final fg = selected ? Colors.white : scheme.onSurfaceVariant;
      return Padding(
        padding: const EdgeInsets.only(right: Gap.xs),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          clipBehavior: Clip.antiAlias,
          child: Ink(
            decoration: BoxDecoration(gradient: selected ? TruckGradients.brand : null),
            child: InkWell(
              key: Key('vehicles-kind-${kind ?? 'all'}'),
              onTap: () => setState(() => _kindFilter = kind),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
                // Etykieta i licznik w jednym tekście (nazwa rodzaju nie myli się z polami formularza).
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: label),
                    const TextSpan(text: '  '),
                    TextSpan(
                      text: ' $count ',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        backgroundColor:
                            selected ? Colors.white.withOpacity(0.2) : TruckColors.of(context).surfaceHigh,
                      ),
                    ),
                  ]),
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(color: fg),
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: [
              segment(null, l.vehiclesAllKinds, vehicles.length),
              for (final e in counts.entries) segment(e.key, kindLabel(l, e.key), e.value),
            ]),
          ),
        ),
      ),
    );
  }

  /// Bazy operacyjne jako chipy i sortowanie po bazie (firma może mieć kilka baz).
  Widget _baseFilter(AppLocalizations l, Map<String, String> bases) => Wrap(
        spacing: Gap.s,
        runSpacing: Gap.s,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (value, label) in [
            (null, l.vehiclesAllBases),
            for (final e in bases.entries) (e.key, e.value),
            ('', l.vehicleBaseNone),
          ])
            ChoiceChip(
              key: Key('vehicles-base-${value ?? 'all'}'),
              avatar: value == null ? null : const Icon(Icons.warehouse_outlined, size: 16),
              label: Text(label),
              selected: _base == value,
              onSelected: (_) => setState(() => _base = value),
            ),
          FilterChip(
            key: const Key('vehicles-sort-base'),
            avatar: const Icon(Icons.sort, size: 18),
            label: Text(l.vehiclesSortByBase),
            selected: _byBase,
            onSelected: (on) => setState(() => _byBase = on),
          ),
        ],
      );

  /// Wybór widoku, wyszukiwanie po nazwie albo tablicy i objaśnienie kolorów.
  /// Szybki filtr stanu z licznikami.
  Widget _stateChips(AppLocalizations l, List<Map<String, dynamic>> vehicles) {
    int count(String filter) => vehicles.where((v) => _matchesState(v, filter)).length;
    final colors = TruckColors.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
      SectionLabel(l.vehiclesQuickFilter),
      for (final (filter, label, color) in [
        ('inUse', l.kpiInUseTitle, colors.inUse),
        ('free', l.kpiAvailable, colors.success),
        ('service', l.kpiRepair, scheme.error),
        ('due', l.kpiDeadlines, colors.warning),
      ])
        FilterChip(
          key: Key('vehicles-state-$filter'),
          label: Text('$label (${count(filter)})'),
          labelStyle: TextStyle(color: _stateFilter == filter ? Colors.white : color, fontWeight: FontWeight.w600),
          selectedColor: color,
          checkmarkColor: Colors.white,
          backgroundColor: Color.alphaBlend(color.withOpacity(0.10), colors.card),
          selected: _stateFilter == filter,
          onSelected: (on) => setState(() => _stateFilter = on ? filter : null),
        ),
    ]);
  }

  Widget _toolbar(AppLocalizations l, Set<VehicleState> states, Map<String, String> bases,
          List<Map<String, dynamic>> vehicles) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Wrap(spacing: 12, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.grid_view), label: Text(l.vehiclesViewCards)),
              ButtonSegment(value: true, icon: const Icon(Icons.table_rows_outlined), label: Text(l.vehiclesViewTable)),
            ],
            selected: {_table},
            showSelectedIcon: false,
            onSelectionChanged: (selected) => _setTable(selected.first),
          ),
          SizedBox(
            width: 280,
            child: TextField(
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: l.vehiclesSearch,
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (MediaQuery.sizeOf(context).width < 720)
            FilterChip(
              key: const Key('vehicles-filters'),
              avatar: const Icon(Icons.tune, size: 18),
              label: Text(l.vehiclesFilters),
              selected: _filtersOpen || _base != null || _stateFilter != null,
              onSelected: (_) => setState(() => _filtersOpen = !_filtersOpen),
            ),
          if (MediaQuery.sizeOf(context).width >= 720 || _filtersOpen) ...[
            _baseFilter(l, bases),
            _stateChips(l, vehicles),
            if (states.isNotEmpty) StateLegend(states: states),
          ],
            ]),
          ),
        ),
      );

  /// Tabela w dwóch zakładkach: pojazdy z napędem oraz naczepy i przyczepy.
  Widget _tables(AppLocalizations l, List<Map<String, dynamic>> motors, List<Map<String, dynamic>> towed,
      List<Map<String, dynamic>> trailers, Map<Object?, Map<String, dynamic>> byId, String? empty) {
    VoidCallback? open(Map<String, dynamic> v) => () => _card(v);
    Widget actions(Map<String, dynamic> v) => _Actions(
            vehicle: v,
            moduleActions: _moduleActions(v),
            onAction: (a) => _runAction(a, v),
            onEdit: () => _open(v),
            onDelete: () => _delete(v),
            onService: () => _service(v),
            onStats: () => _stats(v),
            onDriver: () => _driver(v));
    Widget coupling(Map<String, dynamic> v) {
      if (!couples.containsKey(v['kind'])) return const Text('–');
      final trailer = byId[v['trailer_id']];
      if (trailer == null) return TextButton(onPressed: () => _chooseTrailer(v, trailers), child: Text(l.couplingAdd));
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Text(vehicleTitle(trailer)),
        IconButton(tooltip: l.couplingRemove, onPressed: () => _couple(v, null), icon: const Icon(Icons.link_off)),
      ]);
    }

    Widget table(List<Map<String, dynamic>> items, {required bool isTowed, required String none}) => items.isEmpty
        ? Center(child: Text(empty ?? none))
        : VehiclesTable(
            vehicles: items,
            towed: isTowed,
            byId: byId,
            onOpen: open,
            actions: actions,
            coupling: coupling,
          );
    final scheme = Theme.of(context).colorScheme;
    Tab tab(IconData icon, String text) => Tab(
          height: 44,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 20),
            const SizedBox(width: 8),
            Flexible(child: Text(text, overflow: TextOverflow.ellipsis)),
          ]),
        );
    return DefaultTabController(
      length: 2,
      child: Column(children: [
        // Zakładki jako wyraźne przyciski: wybrana wypełniona kolorem.
        Container(
          margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            color: TruckColors.of(context).card,
            borderRadius: BorderRadius.circular(TruckTheme.radius),
            boxShadow: const [BoxShadow(color: Color(0x0A000000), blurRadius: 8, offset: Offset(0, 1))],
          ),
          child: TabBar(
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(
                color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            labelColor: scheme.onPrimaryContainer,
            unselectedLabelColor: scheme.onSurfaceVariant,
            labelStyle: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            dividerColor: Colors.transparent,
            tabs: [
              tab(Icons.local_shipping_outlined, '${l.vehiclesMotor} (${motors.length})'),
              tab(Icons.rv_hookup, '${l.vehiclesTowed} (${towed.length})'),
            ],
          ),
        ),
        Expanded(
          // Bez przesuwania zakładek palcem – tabela przewija się w bok.
          child: TabBarView(physics: const NeverScrollableScrollPhysics(), children: [
            table(motors, isTowed: false, none: l.vehiclesMotorEmpty),
            table(towed, isTowed: true, none: l.vehiclesTowedEmpty),
          ]),
        ),
      ]),
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard(
      {required this.vehicle,
      required this.onOpen,
      this.moduleActions = const [],
      this.onAction,
      required this.onEdit,
      required this.onDelete,
      required this.onService,
      this.onStats,
      this.onDriver,
      this.coupling});

  final Map<String, dynamic> vehicle;

  /// Kliknięcie w kafelek – karta pojazdu.
  final VoidCallback onOpen;
  final List<VehicleAction> moduleActions;
  final ValueChanged<VehicleAction>? onAction;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onService;
  final VoidCallback? onStats;
  final VoidCallback? onDriver;
  final Widget? coupling;

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final company = v['company_id'] != null;
    final state = vehicleState(v);
    final stateLabel = stateText(l, v);
    final urgent = mostUrgent(v);
    final kmLeft = serviceKmLeft(v);
    String n(Object? value) => value is num ? l.number(value) : '–';
    final kind = v['kind'] as String?;
    final summary = l.vehicleSummary(n(v['height_m']), n(v['width_m']), n(v['length_m']),
        n(v['gvw_t']), n(v['axle_load_t']));
    final tank = v['tank_volume_m3'] is num ? ' · ${l.number(v['tank_volume_m3'] as num)} m³' : '';
    final adr = v['hazmat'] == true ? ' · ADR' : '';
    final tare = v['tare_t'] is num && v['gvw_t'] is num
        ? ' · ${l.vehicleTareSummary(n(v['tare_t']), n((v['gvw_t'] as num) - (v['tare_t'] as num)))}'
        : '';
    final seats = v['seats'] is num ? ' · ${l.vehicleSeatsSummary(n(v['seats']), n(v['standing_places'] ?? 0))}' : '';
    return Card(
      color: stateTint(context, state),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: Icon(kindIcon(kind), color: stateColor(context, state)),
          title: Text(vehicleTitle(v)),
          subtitle: Text('${kindLabel(l, kind)} · ${company ? l.vehicleOfCompany : l.vehiclePrivate}'
              '${stateLabel != null ? ' · $stateLabel' : ''}\n'
              '$summary$tare$tank$seats$adr'
              '${v['assigned_driver_name'] != null ? '\n${l.vehicleAssignedDriver('${v['assigned_driver_name']}')}' : ''}'),
          isThreeLine: true,
          onTap: onOpen,
          trailing: _Actions(
              vehicle: v,
              moduleActions: moduleActions,
              onAction: onAction,
              onEdit: onEdit,
              onDelete: onDelete,
              onService: onService,
              onStats: onStats,
              onDriver: onDriver),
        ),
        if (urgent != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              Icon(urgent.overdue ? Icons.error_outline : Icons.schedule,
                  size: 18, color: urgent.overdue ? scheme.error : scheme.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  (urgent.overdue ? l.vehicleOverdue : l.vehicleDueSoon)(
                      serviceDateLabel(l, urgent.key), DateFormat.yMd(l.localeName).format(urgent.day)),
                  style: TextStyle(color: urgent.overdue ? scheme.error : scheme.tertiary),
                ),
              ),
            ]),
          ),
        if (kmLeft != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(children: [
              Icon(kmLeft < 0 ? Icons.error_outline : Icons.build_circle_outlined,
                  size: 18, color: kmLeft < 0 ? scheme.error : scheme.tertiary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  kmLeft < 0 ? l.vehicleServiceKmOverdue(l.number(-kmLeft)) : l.vehicleServiceKmSoon(l.number(kmLeft)),
                  style: TextStyle(color: kmLeft < 0 ? scheme.error : scheme.tertiary),
                ),
              ),
            ]),
          ),
        if (coupling != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: coupling),
      ]),
    );
  }
}

/// Menu pojazdu: zmiana, terminy, usunięcie – według uprawnień; bez uprawnień kłódka.
class _Actions extends StatelessWidget {
  const _Actions(
      {required this.vehicle,
      this.moduleActions = const [],
      this.onAction,
      required this.onEdit,
      required this.onDelete,
      required this.onService,
      this.onStats,
      this.onDriver});

  final Map<String, dynamic> vehicle;

  /// Akcje modułów (np. „Zgłoś usterkę”) – w tym samym menu.
  final List<VehicleAction> moduleActions;
  final ValueChanged<VehicleAction>? onAction;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onService;

  /// Statystyki przejazdów – tylko pojazdy, które jeżdżą same (bez naczep i przyczep).
  final VoidCallback? onStats;

  /// Przydział kierowcy – pojazdy firmy, które jeżdżą same; zmieniają zarządzający.
  final VoidCallback? onDriver;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final editable = vehicle['can_edit'] != false;
    final service = vehicle['can_service'] == true;
    if (!editable && !service && moduleActions.isEmpty) {
      return Tooltip(message: l.vehicleReadOnly, child: const Icon(Icons.lock_outline));
    }
    return PopupMenuButton<String>(
      onSelected: (action) => switch (action) {
        'edit' => onEdit(),
        'service' => onService(),
        'stats' => onStats?.call(),
        'driver' => onDriver?.call(),
        'delete' => onDelete(),
        final id => onAction?.call(moduleActions.firstWhere((a) => 'module:${a.id}' == id)),
      },
      itemBuilder: (context) => [
        for (final a in moduleActions)
          PopupMenuItem(
            value: 'module:${a.id}',
            child: ListTile(contentPadding: EdgeInsets.zero, leading: Icon(a.icon), title: Text(a.label)),
          ),
        if (editable) PopupMenuItem(value: 'edit', child: Text(l.edit)),
        if (service) PopupMenuItem(value: 'service', child: Text(l.vehicleServiceAction)),
        if (onStats != null)
          PopupMenuItem(value: 'stats', child: Text(l.vehicleStatsAction)),
        if (onDriver != null && canAssignDriver(vehicle) && !moduleActions.any((a) => a.id == assignDriverActionId))
          PopupMenuItem(value: 'driver', child: Text(l.vehicleDriverAction)),
        if (editable) PopupMenuItem(value: 'delete', child: Text(l.delete)),
      ],
    );
  }
}

/// Naczepę / przyczepę przeciąga się na pole pojazdu (na telefonie – po przytrzymaniu).
class _DraggableTrailer extends StatelessWidget {
  const _DraggableTrailer({required this.trailer, required this.child});

  final Map<String, dynamic> trailer;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final feedback = Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(kindIcon(trailer['kind'] as String?)),
          const SizedBox(width: 8),
          Text(vehicleTitle(trailer)),
        ]),
      ),
    );
    final dimmed = Opacity(opacity: 0.4, child: child);
    final touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    return touch
        ? LongPressDraggable<Map<String, dynamic>>(
            data: trailer, feedback: feedback, childWhenDragging: dimmed, child: child)
        : Draggable<Map<String, dynamic>>(data: trailer, feedback: feedback, childWhenDragging: dimmed, child: child);
  }
}

/// Pole pojazdu na naczepę / przyczepę: upuszczenie, „Podepnij” albo odpięcie.
class _CouplingSlot extends StatelessWidget {
  const _CouplingSlot({
    required this.vehicle,
    required this.trailer,
    required this.accepts,
    required this.onDrop,
    required this.onChoose,
    required this.onUncouple,
    this.free = const [],
  });

  /// Wolne pasujące naczepy – „Podepnij X” jednym kliknięciem.
  final List<Map<String, dynamic>> free;

  final Map<String, dynamic> vehicle;
  final Map<String, dynamic>? trailer;
  final bool Function(Map<String, dynamic>) accepts;
  final ValueChanged<Map<String, dynamic>> onDrop;
  final VoidCallback onChoose;
  final VoidCallback onUncouple;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final wanted = kindLabel(l, couples[vehicle['kind']]);
    return DragTarget<Map<String, dynamic>>(
      onWillAcceptWithDetails: (details) => accepts(details.data),
      onAcceptWithDetails: (details) => onDrop(details.data),
      builder: (context, candidates, rejected) {
        final highlight = candidates.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: rejected.isNotEmpty ? scheme.error : (highlight ? scheme.primary : scheme.outlineVariant),
              width: highlight ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(children: [
            Icon(Icons.link, size: 18, color: trailer == null ? scheme.outline : scheme.primary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                trailer == null ? l.couplingEmpty(wanted) : l.couplingWith(vehicleTitle(trailer!)),
                style: trailer == null ? TextStyle(color: scheme.outline) : null,
              ),
            ),
            if (trailer != null)
              IconButton(tooltip: l.couplingRemove, onPressed: onUncouple, icon: const Icon(Icons.link_off))
            else ...[
              // Jedna wolna pasująca naczepa – podpięcie bez okna wyboru.
              if (free.length == 1)
                TextButton.icon(
                  onPressed: () => onDrop(free.single),
                  icon: const Icon(Icons.link, size: 18),
                  label: Text(l.cardCoupleQuick(vehicleTitle(free.single))),
                ),
              TextButton(onPressed: onChoose, child: Text(free.length == 1 ? l.couplingOther : l.couplingAdd)),
            ],
          ]),
        );
      },
    );
  }
}
