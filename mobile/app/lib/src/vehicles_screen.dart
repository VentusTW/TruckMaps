import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'l10n.dart';
import 'vehicles/service_dates.dart';
import 'vehicles/vehicle_form.dart';

/// Profile pojazdów konta (prywatne i firmowe) – wymiary, według których liczona jest trasa.
/// Dodawanie, zmiana i usuwanie; pojazd firmy zmieniają właściciel i dyspozytorzy.
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key, required this.api, this.onChanged});

  final CoreApi api;

  /// Po każdej zmianie listy (np. planer odświeża wybór pojazdu).
  final VoidCallback? onChanged;

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  late Future<dynamic> _vehicles = widget.api.get('/api/vehicles');

  void _reload() {
    final vehicles = widget.api.get('/api/vehicles');
    setState(() {
      _vehicles = vehicles;
    });
    widget.onChanged?.call();
  }

  Future<void> _open([Map<String, dynamic>? vehicle]) async {
    final saved = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => VehicleFormScreen(api: widget.api, vehicle: vehicle)),
    );
    if (saved != null && mounted) _reload();
  }

  Future<void> _service(Map<String, dynamic> vehicle) async {
    final saved = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => ServiceDatesScreen(api: widget.api, vehicle: vehicle)),
    );
    if (saved != null && mounted) _reload();
  }

  Future<void> _delete(Map<String, dynamic> vehicle) async {
    final l = context.l;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.vehicleDeleteTitle),
        content: Text(l.vehicleDeleteQuestion('${vehicle['name']}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.api.delete('/api/vehicles/${vehicle['id']}');
      _reload();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// Podpięcie naczepy / przyczepy do pojazdu ([trailer] `null` – odpięcie).
  Future<void> _couple(Map<String, dynamic> vehicle, Map<String, dynamic>? trailer) async {
    try {
      await widget.api.put('/api/vehicles/${vehicle['id']}/trailer', {'trailer_id': trailer?['id']});
      _reload();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  /// „Podepnij”: lista pasujących naczep / przyczep; te w użyciu – na czerwono i nie do wybrania.
  Future<void> _chooseTrailer(Map<String, dynamic> vehicle, List<Map<String, dynamic>> trailers) async {
    final l = context.l;
    final fitting = [for (final t in trailers) if (t['kind'] == couples[vehicle['kind']]) t];
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.couplingChoose('${vehicle['name']}')),
        children: [
          if (fitting.isEmpty)
            Padding(padding: const EdgeInsets.all(24), child: Text(l.couplingNone(kindLabel(l, couples[vehicle['kind']])))),
          for (final t in fitting)
            _InUse(
              inUse: _busy(t, vehicle),
              child: SimpleDialogOption(
                onPressed: _busy(t, vehicle) ? null : () => Navigator.pop(context, t),
                child: ListTile(
                  leading: Icon(kindIcon(t['kind'] as String?)),
                  title: Text(_title(t)),
                  subtitle: Text(_busy(t, vehicle) ? _inUseText(l, t) : trailerLabel(l, '${t['trailer_type']}')),
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) await _couple(vehicle, chosen);
  }

  /// W użyciu dla [vehicle]: podpięta gdzie indziej (do tego pojazdu – nie przeszkadza).
  bool _busy(Map<String, dynamic> trailer, Map<String, dynamic> vehicle) =>
      trailer['in_use'] == true && trailer['coupled_to_id'] != vehicle['id'];

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-vehicle',
        onPressed: _open,
        icon: const Icon(Icons.add),
        label: Text(l.vehicleAdd),
      ),
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
          final motors = [for (final v in vehicles) if (isDrivable(v)) v];
          final trailers = [for (final v in vehicles) if (!isDrivable(v)) v];
          final byId = {for (final v in vehicles) v['id']: v};

          Widget motorCard(Map<String, dynamic> v) => _VehicleCard(
                vehicle: v,
                onEdit: () => _open(v),
                onDelete: () => _delete(v),
                onService: () => _service(v),
                coupling: couples.containsKey(v['kind'])
                    ? _CouplingSlot(
                        vehicle: v,
                        trailer: byId[v['trailer_id']],
                        accepts: (t) => t['kind'] == couples[v['kind']] && !_busy(t, v),
                        onDrop: (t) => _couple(v, t),
                        onChoose: () => _chooseTrailer(v, trailers),
                        onUncouple: () => _couple(v, null),
                      )
                    : null,
              );
          Widget trailerCard(Map<String, dynamic> t) => _DraggableTrailer(
                trailer: t,
                child: _VehicleCard(
                    vehicle: t, onEdit: () => _open(t), onDelete: () => _delete(t), onService: () => _service(t)),
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
          final motorList = section(l.vehiclesMotor, motors, motorCard, l.vehiclesMotorEmpty);
          final trailerList = section(l.vehiclesTowed, trailers, trailerCard, l.vehiclesTowedEmpty);
          const padding = EdgeInsets.fromLTRB(12, 4, 12, 88);
          // Szeroki ekran: samochody po lewej, naczepy i przyczepy po prawej (przeciąganie na pojazd).
          if (MediaQuery.sizeOf(context).width >= 900) {
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: ListView(padding: padding, children: motorList)),
              Expanded(child: ListView(padding: padding, children: trailerList)),
            ]);
          }
          return ListView(padding: padding, children: [...motorList, ...trailerList]);
        },
      ),
    );
  }
}

String _title(Map<String, dynamic> v) {
  final plate = '${v['plate'] ?? ''}';
  return plate.isEmpty ? '${v['name']}' : '${v['name']} · $plate';
}

String _inUseText(AppLocalizations l, Map<String, dynamic> v) => v['in_repair'] == true
    ? l.vehicleInRepair
    : v['coupled_to_name'] != null
        ? l.vehicleCoupledTo('${v['coupled_to_name']}')
        : l.vehicleInUse;

/// Stonowany czerwony dla pojazdów i naczep w użyciu.
class _InUse extends StatelessWidget {
  const _InUse({required this.inUse, required this.child});

  final bool inUse;
  final Widget child;

  static Color tint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Color.alphaBlend(scheme.error.withOpacity(0.10), scheme.surface);
  }

  @override
  Widget build(BuildContext context) => inUse ? ColoredBox(color: tint(context), child: child) : child;
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard(
      {required this.vehicle, required this.onEdit, required this.onDelete, required this.onService, this.coupling});

  final Map<String, dynamic> vehicle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onService;
  final Widget? coupling;

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final company = v['company_id'] != null;
    final editable = v['can_edit'] != false;
    final inUse = v['in_use'] == true || v['in_repair'] == true;
    final service = v['can_service'] == true;
    final urgent = mostUrgent(v);
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
      color: inUse ? _InUse.tint(context) : null,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          leading: Icon(kindIcon(kind), color: inUse ? scheme.error : null),
          title: Text(_title(v)),
          subtitle: Text('${kindLabel(l, kind)} · ${company ? l.vehicleOfCompany : l.vehiclePrivate}'
              '${inUse ? ' · ${_inUseText(l, v)}' : ''}\n'
              '$summary$tare$tank$seats$adr'),
          isThreeLine: true,
          onTap: editable ? onEdit : (service ? onService : null),
          trailing: editable || service
              ? PopupMenuButton<String>(
                  onSelected: (action) => switch (action) {
                    'edit' => onEdit(),
                    'service' => onService(),
                    _ => onDelete(),
                  },
                  itemBuilder: (context) => [
                    if (editable) PopupMenuItem(value: 'edit', child: Text(l.edit)),
                    if (service) PopupMenuItem(value: 'service', child: Text(l.vehicleServiceAction)),
                    if (editable) PopupMenuItem(value: 'delete', child: Text(l.delete)),
                  ],
                )
              : Tooltip(message: l.vehicleReadOnly, child: const Icon(Icons.lock_outline)),
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
        if (coupling != null) Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 12), child: coupling),
      ]),
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
          Text(_title(trailer)),
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
  });

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
                trailer == null ? l.couplingEmpty(wanted) : l.couplingWith(_title(trailer!)),
                style: trailer == null ? TextStyle(color: scheme.outline) : null,
              ),
            ),
            if (trailer != null)
              IconButton(tooltip: l.couplingRemove, onPressed: onUncouple, icon: const Icon(Icons.link_off))
            else
              TextButton(onPressed: onChoose, child: Text(l.couplingAdd)),
          ]),
        );
      },
    );
  }
}
