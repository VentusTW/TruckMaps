import 'dart:async';
import 'dart:math' as math;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../planner/planner_screen.dart' show mapTiles;
import '../planner/route.dart' show PlannedRoute, levelColor;
import 'route_plan_panel.dart';

/// Pojazd firmy na mapie centrali (`GET /api/companies/{id}/live`).
class LiveVehicle {
  const LiveVehicle({
    required this.id,
    required this.name,
    this.plate,
    this.driver,
    this.position,
    this.speedKmh,
    this.heading,
    this.destination,
    this.remainingKm,
    this.eta,
    this.at,
    this.state = 'no_signal',
  });

  factory LiveVehicle.fromJson(Map<String, dynamic> json) {
    final lat = (json['lat'] as num?)?.toDouble(), lon = (json['lon'] as num?)?.toDouble();
    DateTime? time(String key) => json[key] == null ? null : DateTime.parse(json[key] as String).toLocal();
    return LiveVehicle(
      id: json['vehicle_id'] as String,
      name: json['name'] as String,
      plate: json['plate'] as String?,
      driver: json['driver'] as String?,
      position: lat == null || lon == null ? null : LatLng(lat, lon),
      speedKmh: (json['speed_kmh'] as num?)?.toDouble(),
      heading: (json['heading'] as num?)?.toDouble(),
      destination: json['destination'] as String?,
      remainingKm: (json['remaining_km'] as num?)?.toDouble(),
      eta: time('eta'),
      at: time('at'),
      state: json['state'] as String? ?? 'no_signal',
    );
  }

  final String id, name;
  final String? plate, driver, destination;
  final LatLng? position;
  final double? speedKmh, heading, remainingKm;
  final DateTime? eta, at;

  /// `driving`, `stopped`, `no_signal`.
  final String state;
}

/// Centrala & Live Map: pojazdy firmy na mapie z pozycjami z aplikacji kierowców (odświeżane
/// co [refresh]), lista z kierowcą, stanem, prędkością, km do celu i godziną przyjazdu.
class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key, required this.api, required this.companyId, this.refresh = const Duration(seconds: 15)});

  final CoreApi api;
  final String? companyId;
  final Duration refresh;

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  final _map = MapController();
  List<LiveVehicle> _vehicles = const [];
  String? _error;
  String? _selected;
  bool _fitted = false;
  bool _loading = true;
  Timer? _timer;

  /// Planowanie trasy dla pojazdu (panel zamiast listy) i wyznaczona trasa na mapie.
  LiveVehicle? _planFor;
  PlannedRoute? _planned;

  /// Ostatnie trasy wysłane kierowcom.
  List<Map<String, dynamic>> _sent = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.refresh, (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final company = widget.companyId;
    if (company == null) {
      setState(() => _loading = false);
      return;
    }
    try {
      final list = await widget.api.get('/api/companies/$company/live') as List<dynamic>;
      final sent = await widget.api.get('/api/companies/$company/route-assignments').catchError((_) => <dynamic>[]);
      if (!mounted) return;
      _sent = [for (final a in sent as List<dynamic>) a as Map<String, dynamic>];
      setState(() {
        _vehicles = [for (final v in list) LiveVehicle.fromJson(v as Map<String, dynamic>)];
        _error = null;
        _loading = false;
      });
      _fit();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _loading = false;
        });
      }
    }
  }

  /// Pierwsze wczytanie: mapa obejmuje wszystkie pojazdy z pozycją.
  void _fit() {
    if (_fitted) return;
    final points = [
      for (final v in _vehicles)
        if (v.position != null) v.position!
    ];
    if (points.isEmpty) return;
    _fitted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (points.length == 1) {
        _map.move(points.first, 12);
      } else {
        _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(64)));
      }
    });
  }

  void _select(LiveVehicle vehicle) {
    setState(() => _selected = vehicle.id);
    if (vehicle.position != null) _map.move(vehicle.position!, math.max(_map.camera.zoom, 12));
  }

  Color _stateColor(String state, ColorScheme scheme) => switch (state) {
        'driving' => const Color(0xFF1E88E5),
        'stopped' => const Color(0xFF6D6D6D),
        _ => const Color(0xFFE08A00),
      };

  String _stateLabel(AppLocalizations l, String state) => switch (state) {
        'driving' => l.liveStateDriving,
        'stopped' => l.liveStateStopped,
        _ => l.liveStateNoSignal,
      };

  String _assignmentState(AppLocalizations l, String state) => switch (state) {
        'accepted' => l.liveSentAccepted,
        'done' => l.liveSentDone,
        'rejected' => l.liveSentRejected,
        _ => l.liveSentWaiting,
      };

  String _ago(AppLocalizations l, DateTime? at) {
    if (at == null) return l.liveNever;
    final minutes = DateTime.now().difference(at).inMinutes;
    if (minutes < 1) return l.liveJustNow;
    if (minutes < 60) return l.liveMinutesAgo(minutes);
    return l.liveHoursAgo(minutes ~/ 60);
  }

  Widget _marker(LiveVehicle v, ColorScheme scheme) {
    final color = _stateColor(v.state, scheme);
    final selected = v.id == _selected;
    return GestureDetector(
      onTap: () => _select(v),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color, width: 1.5),
            boxShadow: const [BoxShadow(color: Color(0x33000000), blurRadius: 4)],
          ),
          child: Text(v.plate ?? v.name,
              style: TextStyle(
                  fontSize: 11, fontWeight: FontWeight.w700, color: selected ? Colors.white : const Color(0xFF222222))),
        ),
        const SizedBox(height: 2),
        Transform.rotate(
          angle: (v.heading ?? 0) * math.pi / 180,
          child: Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
            ),
            child: Icon(v.heading != null && v.state == 'driving' ? Icons.navigation : Icons.local_shipping,
                size: 16, color: Colors.white),
          ),
        ),
      ]),
    );
  }

  Widget _tile(LiveVehicle v, AppLocalizations l, ThemeData theme) {
    final color = _stateColor(v.state, theme.colorScheme);
    final details = [
      if (v.driver != null) v.driver!,
      if (v.speedKmh != null) '${v.speedKmh!.round()} km/h',
      if (v.destination != null) '→ ${v.destination}',
      if (v.remainingKm != null) l.liveRemaining(v.remainingKm!.round()),
      if (v.eta != null) l.liveEta(TimeOfDay.fromDateTime(v.eta!).format(context)),
    ];
    return ListTile(
      key: Key('live-${v.id}'),
      selected: v.id == _selected,
      onTap: v.position == null ? null : () => _select(v),
      trailing: IconButton(
        key: Key('plan-${v.id}'),
        tooltip: l.livePlanRoute,
        icon: const Icon(Icons.alt_route),
        onPressed: () => setState(() {
          _planFor = v;
          _planned = null;
          _selected = v.id;
        }),
      ),
      leading:
          CircleAvatar(backgroundColor: color, child: const Icon(Icons.local_shipping, color: Colors.white, size: 20)),
      title: Text([v.name, if (v.plate != null) v.plate!].join(' · ')),
      subtitle: Text([
        '${_stateLabel(l, v.state)} · ${_ago(l, v.at)}',
        if (details.isNotEmpty) details.join(' · '),
      ].join('\n')),
      isThreeLine: details.isNotEmpty,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    if (widget.companyId == null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(l.liveNoCompany)));
    }
    final driving = _vehicles.where((v) => v.state == 'driving').length;
    final map = FlutterMap(
      mapController: _map,
      options: const MapOptions(initialCenter: LatLng(52.1, 19.1), initialZoom: 6),
      children: [
        mapTiles(),
        if (_planned != null)
          PolylineLayer(polylines: [
            for (final (points, level) in _planned!.coloredParts)
              Polyline(
                  points: points,
                  strokeWidth: level == 'red' ? 7 : 6,
                  color: levelColor(level),
                  borderStrokeWidth: 2,
                  borderColor: Colors.white),
          ]),
        MarkerLayer(markers: [
          for (final v in _vehicles)
            if (v.position != null)
              Marker(
                  point: v.position!,
                  width: 120,
                  height: 64,
                  alignment: Alignment.topCenter,
                  child: _marker(v, theme.colorScheme)),
        ]),
      ],
    );
    final list = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(children: [
          Expanded(child: Text(l.liveSummary(driving, _vehicles.length), style: theme.textTheme.titleMedium)),
          IconButton(tooltip: l.liveRefresh, onPressed: _load, icon: const Icon(Icons.refresh)),
        ]),
      ),
      if (_error != null)
        Padding(
            padding: const EdgeInsets.all(16), child: Text(_error!, style: TextStyle(color: theme.colorScheme.error))),
      if (_loading) const LinearProgressIndicator(),
      if (!_loading && _vehicles.isEmpty && _error == null)
        Padding(padding: const EdgeInsets.all(16), child: Text(l.liveEmpty)),
      Expanded(
        child: ListView(children: [
          for (final v in _vehicles) _tile(v, l, theme),
          if (_sent.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(l.liveSentTitle, style: theme.textTheme.titleSmall),
            ),
            for (final a in _sent.take(10))
              ListTile(
                dense: true,
                leading: Icon(switch (a['state']) {
                  'accepted' => Icons.directions_car,
                  'done' => Icons.check_circle_outline,
                  'rejected' => Icons.cancel_outlined,
                  _ => Icons.send_outlined,
                }),
                title: Text('${(a['origin'] as Map)['label']} → ${(a['destination'] as Map)['label']}'),
                subtitle: Text(
                    '${a['driver_name']} · ${a['plate'] ?? a['vehicle_name']} · ${_assignmentState(l, '${a['state']}')}'),
              ),
          ],
        ]),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Text(l.liveHowItWorks, style: theme.textTheme.bodySmall),
      ),
    ]);
    final planFor = _planFor;
    final side = planFor == null
        ? list
        : RoutePlanPanel(
            key: ValueKey(('plan', planFor.id)),
            api: widget.api,
            companyId: widget.companyId!,
            vehicle: planFor,
            onRoute: (route) {
              setState(() => _planned = route);
              if (route != null && route.points.length > 1) {
                _map.fitCamera(
                    CameraFit.bounds(bounds: LatLngBounds.fromPoints(route.points), padding: const EdgeInsets.all(48)));
              }
            },
            onClose: () => setState(() {
              _planFor = null;
              _planned = null;
            }),
            onSent: (driver) {
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.livePlanSent(driver))));
              setState(() {
                _planFor = null;
                _planned = null;
              });
              _load();
            },
          );
    return LayoutBuilder(builder: (context, size) {
      if (size.maxWidth >= 900) {
        return Row(children: [
          SizedBox(width: 380, child: Material(color: theme.colorScheme.surface, child: side)),
          const VerticalDivider(width: 1),
          Expanded(child: map),
        ]);
      }
      return Column(children: [
        Expanded(flex: 3, child: map),
        const Divider(height: 1),
        Expanded(flex: 2, child: side),
      ]);
    });
  }
}
