import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../planner/place_field.dart';
import '../planner/route.dart';
import 'live_screen.dart' show LiveVehicle;

/// Centrala: trasa dla pojazdu firmy wysyłana kierowcy. Start domyślnie w bieżącej pozycji
/// pojazdu, ale można wpisać dowolne miejsce (pojazd bywa teraz gdzie indziej), do tego punkty
/// „Jedź przez”, cel, kierowca i uwagi. Wyznaczona trasa jest rysowana na mapie centrali.
class RoutePlanPanel extends StatefulWidget {
  const RoutePlanPanel({
    super.key,
    required this.api,
    required this.companyId,
    required this.vehicle,
    required this.onRoute,
    required this.onClose,
    required this.onSent,
  });

  final CoreApi api;
  final String companyId;
  final LiveVehicle vehicle;

  /// Wyznaczona trasa (do narysowania) albo `null` po zmianie punktów.
  final ValueChanged<PlannedRoute?> onRoute;
  final VoidCallback onClose;

  /// Trasa wysłana – nazwa kierowcy do komunikatu.
  final ValueChanged<String> onSent;

  @override
  State<RoutePlanPanel> createState() => _RoutePlanPanelState();
}

class _RoutePlanPanelState extends State<RoutePlanPanel> {
  final _startText = TextEditingController();
  final _endText = TextEditingController();
  final _note = TextEditingController();
  final List<TextEditingController> _viaText = [];
  final List<Place?> _via = [];
  Place? _start, _end;
  bool _avoid = true;
  bool _busy = false;
  String? _error;
  PlannedRoute? _route;
  List<(String, String)> _drivers = const [];
  String? _driver;

  @override
  void initState() {
    super.initState();
    final position = widget.vehicle.position;
    if (position != null) {
      // Domyślny start: tu, gdzie pojazd jest teraz (można zmienić na dowolne miejsce).
      _start = Place('${widget.vehicle.plate ?? widget.vehicle.name} (GPS)', position);
      _startText.text = _start!.label;
    }
    _loadDrivers();
  }

  @override
  void dispose() {
    for (final c in [_startText, _endText, _note, ..._viaText]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadDrivers() async {
    try {
      final company = await widget.api.get('/api/companies/${widget.companyId}') as Map<String, dynamic>;
      final members = (company['members'] as List<dynamic>).cast<Map<String, dynamic>>();
      final drivers = [
        for (final m in members)
          if (m['role'] == 'driver') ('${m['id']}', '${m['display_name']}'),
      ];
      if (!mounted) return;
      setState(() {
        _drivers = drivers;
        // Domyślnie kierowca, który teraz jedzie tym pojazdem.
        _driver = drivers.where((d) => d.$2 == widget.vehicle.driver).firstOrNull?.$1 ??
            (drivers.isEmpty ? null : drivers.first.$1);
      });
    } catch (_) {
      // Bez listy kierowców wysłanie jest niedostępne; wyznaczanie działa.
    }
  }

  void _changed() {
    if (_route == null) return;
    setState(() => _route = null);
    widget.onRoute(null);
  }

  Map<String, dynamic> _json(Place p) => {'lat': p.point.latitude, 'lon': p.point.longitude};
  Map<String, dynamic> _stop(Place p) => {..._json(p), 'label': p.label};

  Future<void> _calculate() async {
    final start = _start, end = _end;
    if (start == null || end == null) return setState(() => _error = context.l.chooseStartAndEnd);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = await widget.api.post('/api/routes', {
        'origin': _json(start),
        'destination': _json(end),
        'via': [for (final v in _via.whereType<Place>()) _json(v)],
        'vehicle_id': widget.vehicle.id,
        'avoid_difficult': _avoid,
      }) as Map<String, dynamic>;
      final route = RouteResult.fromJson(body).route;
      setState(() => _route = route);
      widget.onRoute(route);
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _send() async {
    final start = _start, end = _end, route = _route, driver = _driver;
    if (start == null || end == null || route == null || driver == null) return;
    setState(() => _busy = true);
    try {
      await widget.api.post('/api/companies/${widget.companyId}/route-assignments', {
        'vehicle_id': widget.vehicle.id,
        'driver_member_id': driver,
        'origin': _stop(start),
        'destination': _stop(end),
        'via': [for (final v in _via.whereType<Place>()) _stop(v)],
        'avoid_difficult': _avoid,
        'note': _note.text.trim(),
        'distance_km': route.distanceKm,
        'duration_min': route.durationMin,
      });
      widget.onSent(_drivers.firstWhere((d) => d.$1 == driver).$2);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final route = _route;
    final near = widget.vehicle.position ?? const LatLng(52.1, 19.1);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
          child: Text(l.livePlanTitle(widget.vehicle.plate ?? widget.vehicle.name), style: theme.textTheme.titleMedium),
        ),
        IconButton(tooltip: l.liveBackToList, onPressed: widget.onClose, icon: const Icon(Icons.close)),
      ]),
      Text(l.livePlanStartHint, style: theme.textTheme.bodySmall),
      const SizedBox(height: 12),
      PlaceField(
        key: const Key('plan-start'),
        api: widget.api,
        label: l.fromLabel,
        icon: Icons.trip_origin,
        controller: _startText,
        near: near,
        onSelected: (p) {
          _start = p;
          _changed();
        },
      ),
      for (final (i, controller) in _viaText.indexed)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(children: [
            Expanded(
              child: PlaceField(
                api: widget.api,
                label: l.livePlanVia(i + 1),
                icon: Icons.more_vert,
                controller: controller,
                near: near,
                onSelected: (p) {
                  _via[i] = p;
                  _changed();
                },
              ),
            ),
            IconButton(
              tooltip: l.livePlanRemoveVia,
              onPressed: () => setState(() {
                _viaText.removeAt(i).dispose();
                _via.removeAt(i);
                _changed();
              }),
              icon: const Icon(Icons.remove_circle_outline),
            ),
          ]),
        ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _viaText.length >= 5
              ? null
              : () => setState(() {
                    _viaText.add(TextEditingController());
                    _via.add(null);
                  }),
          icon: const Icon(Icons.add),
          label: Text(l.livePlanAddVia),
        ),
      ),
      PlaceField(
        key: const Key('plan-end'),
        api: widget.api,
        label: l.toLabel,
        icon: Icons.flag,
        controller: _endText,
        near: near,
        onSelected: (p) {
          _end = p;
          _changed();
        },
      ),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        value: _avoid,
        onChanged: (v) {
          setState(() => _avoid = v ?? true);
          _changed();
        },
        title: Text(l.livePlanAvoid),
      ),
      FilledButton.icon(
        key: const Key('plan-calculate'),
        onPressed: _busy ? null : _calculate,
        icon: const Icon(Icons.route),
        label: Text(l.livePlanCalculate),
      ),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
      if (route != null) ...[
        const SizedBox(height: 16),
        Text(l.livePlanSummary(route.distanceKm.round(), _duration(route.durationMin)),
            style: theme.textTheme.titleSmall),
        const SizedBox(height: 12),
        if (_drivers.isEmpty)
          Text(l.livePlanNoDrivers, style: theme.textTheme.bodySmall)
        else ...[
          DropdownButtonFormField<String>(
            value: _driver,
            decoration: InputDecoration(labelText: l.livePlanDriver, border: const OutlineInputBorder()),
            items: [for (final (id, name) in _drivers) DropdownMenuItem(value: id, child: Text(name))],
            onChanged: (id) => setState(() => _driver = id),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            maxLength: 500,
            maxLines: 2,
            decoration: InputDecoration(labelText: l.livePlanNote, border: const OutlineInputBorder()),
          ),
          FilledButton.icon(
            key: const Key('plan-send'),
            onPressed: _busy || _driver == null ? null : _send,
            icon: const Icon(Icons.send),
            label: Text(l.livePlanSend),
          ),
        ],
      ],
    ]);
  }

  static String _duration(double minutes) {
    final m = minutes.round();
    return m < 60 ? '$m min' : '${m ~/ 60} h ${(m % 60).toString().padLeft(2, '0')} min';
  }
}
