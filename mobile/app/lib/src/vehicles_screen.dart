import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n.dart';
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

  @override
  void initState() {
    super.initState();
    widget.refresh?.addListener(_refresh);
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
  }

  void _reload() {
    final vehicles = widget.api.get('/api/vehicles');
    setState(() {
      _vehicles = vehicles;
    });
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
        const SizedBox(height: 12),
        FloatingActionButton.extended(
          heroTag: 'add-vehicle',
          onPressed: _open,
          icon: const Icon(Icons.add),
          label: Text(l.vehicleAdd),
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
          if (vehicles.isEmpty) return Center(child: Text(l.vehiclesEmpty));
          final trailers = [for (final v in vehicles) if (!isDrivable(v)) v];
          final byId = {for (final v in vehicles) v['id']: v};
          final shown = [for (final v in vehicles) if (matchesVehicle(v, _query)) v];
          final shownMotors = [for (final v in shown) if (isDrivable(v)) v];
          final shownTrailers = [for (final v in shown) if (!isDrivable(v)) v];
          final empty = _query.trim().isEmpty ? null : l.vehiclesNoMatch;
          final states = {for (final v in shown) vehicleState(v)}..remove(VehicleState.free);
          if (_table) {
            return Column(children: [
              _toolbar(l, states),
              Expanded(child: _tables(l, shownMotors, shownTrailers, trailers, byId, empty)),
            ]);
          }

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
          if (MediaQuery.sizeOf(context).width >= 900) {
            return Column(children: [
              _toolbar(l, states),
              Expanded(
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: ListView(padding: padding, children: motorList)),
                  Expanded(child: ListView(padding: padding, children: trailerList)),
                ]),
              ),
            ]);
          }
          return Column(children: [
            _toolbar(l, states),
            Expanded(child: ListView(padding: padding, children: [...motorList, ...trailerList])),
          ]);
        },
      ),
    );
  }

  /// Wybór widoku, wyszukiwanie po nazwie albo tablicy i objaśnienie kolorów.
  Widget _toolbar(AppLocalizations l, Set<VehicleState> states) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
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
                border: const OutlineInputBorder(),
              ),
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          if (states.isNotEmpty) StateLegend(states: states),
        ]),
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
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: scheme.surfaceVariant, borderRadius: BorderRadius.circular(12)),
          child: TabBar(
            indicatorSize: TabBarIndicatorSize.tab,
            indicator: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(9)),
            labelColor: scheme.onPrimary,
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
        if (onDriver != null && canAssignDriver(vehicle))
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
