import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../planner/planner_screen.dart' show mapTiles;
import '../planner/route.dart';
import 'corridor.dart';
import 'guidance.dart';
import 'speech.dart';

/// Skąd nawigacja bierze pozycję: GPS albo symulacja (testy, pokaz bez jazdy).
abstract class PositionSource {
  Stream<LatLng> get positions;
  Future<void> dispose();
}

enum GpsProblem { disabled, denied }

class GpsPositions implements PositionSource {
  final _controller = StreamController<LatLng>.broadcast();
  StreamSubscription<Position>? _subscription;

  /// Prosi o zgodę na lokalizację; `null` – GPS działa.
  Future<GpsProblem?> start() async {
    if (!await Geolocator.isLocationServiceEnabled()) return GpsProblem.disabled;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return GpsProblem.denied;
    }
    _subscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.bestForNavigation, distanceFilter: 5),
    ).listen((p) => _controller.add(LatLng(p.latitude, p.longitude)));
    return null;
  }

  @override
  Stream<LatLng> get positions => _controller.stream;

  @override
  Future<void> dispose() async {
    await _subscription?.cancel();
    await _controller.close();
  }
}

/// Symulacja: pozycja z dotknięcia mapy albo jazda po trasie z zadaną prędkością.
class SimulatedPositions implements PositionSource {
  final _controller = StreamController<LatLng>.broadcast();
  Timer? _timer;

  @override
  Stream<LatLng> get positions => _controller.stream;

  void jump(LatLng position) {
    stopDriving();
    _controller.add(position);
  }

  /// Jazda po linii od podanego miejsca (m od początku), co sekundę o [speedKmh].
  void drive(List<LatLng> line, {double fromM = 0, double speedKmh = 60}) {
    stopDriving();
    var along = fromM;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      along += speedKmh / 3.6;
      final point = pointAlong(line, along);
      if (point == null) return stopDriving();
      _controller.add(point);
    });
  }

  void stopDriving() {
    _timer?.cancel();
    _timer = null;
  }

  bool get driving => _timer != null;

  @override
  Future<void> dispose() async {
    stopDriving();
    await _controller.close();
  }
}

/// Punkt [alongM] metrów od początku linii; `null` – za końcem.
LatLng? pointAlong(List<LatLng> line, double alongM) {
  var left = alongM;
  for (var i = 0; i < line.length - 1; i++) {
    final length = distanceM(line[i], line[i + 1]);
    if (left <= length) {
      final t = length == 0 ? 0.0 : left / length;
      return LatLng(line[i].latitude + t * (line[i + 1].latitude - line[i].latitude),
          line[i].longitude + t * (line[i + 1].longitude - line[i].longitude));
    }
    left -= length;
  }
  return null;
}

/// Dane trasy do nawigacji (z planera).
class NavigationRequest {
  const NavigationRequest({
    required this.vehicleId,
    required this.route,
    required this.destination,
    this.via = const [],
    this.avoidDifficult = true,
  });

  final String vehicleId;
  final PlannedRoute route;
  final LatLng destination;
  final List<LatLng> via;
  final bool avoidDifficult;
}

/// Ile kolejnych pozycji poza trasą (nie na drodze czerwonej), zanim trasa jest przeliczana.
const offRouteFixes = 3;

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({
    super.key,
    required this.api,
    required this.request,
    this.source,
    this.alarmSound = true,
    this.speaker,
  });

  final CoreApi api;
  final NavigationRequest request;

  /// Źródło pozycji podane z góry (testy); zwykle GPS z symulacją pod ręką.
  final PositionSource? source;
  final bool alarmSound;

  /// Głos podany z góry (testy); zwykle syntezator mowy systemu w języku aplikacji.
  final Speaker? speaker;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> with SingleTickerProviderStateMixin {
  final _map = MapController();
  final _simulation = SimulatedPositions();
  final _player = AudioPlayer();
  late final _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
  GpsPositions? _gps;
  final List<StreamSubscription<LatLng>> _subscriptions = [];

  late PlannedRoute _route = widget.request.route;
  late List<LatLng> _via = widget.request.via;
  Corridor? _corridor;
  String? _corridorError;
  LatLng? _position;
  PositionCheck? _check;
  int _offRoute = 0;

  /// Ile trasy przejechano przy ostatniej pozycji na trasie (do pominięcia minionych punktów).
  double _lastAlongM = 0;
  bool _recalculating = false;
  String? _notice;
  bool _follow = true;
  Guidance? _guidance;
  bool _voice = true;
  late final Speaker _speaker = widget.speaker ?? systemSpeaker(_speechLanguage(Localizations.localeOf(context)));

  @override
  void initState() {
    super.initState();
    _loadCorridor();
    _listen(widget.source ?? _simulation);
    if (widget.source == null) _startGps();
  }

  Future<void> _startGps() async {
    final gps = GpsPositions();
    final problem = await gps.start();
    if (!mounted) return;
    if (problem != null) {
      setState(() => _notice = problem == GpsProblem.disabled ? context.l.gpsDisabled : context.l.gpsDenied);
      await gps.dispose();
      return;
    }
    _gps = gps;
    _listen(gps);
  }

  void _listen(PositionSource source) => _subscriptions.add(source.positions.listen(_onPosition));

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _gps?.dispose();
    _simulation.dispose();
    _player.dispose();
    _speaker.dispose();
    _blink.dispose();
    super.dispose();
  }

  Future<void> _loadCorridor() async {
    try {
      final body = await widget.api.post('/api/corridor', {
        'vehicle_id': widget.request.vehicleId,
        'route': encodePolyline6(_route.points),
      });
      final corridor = Corridor.fromJson(body as Map<String, dynamic>);
      setState(() {
        _corridor = corridor;
        _corridorError = null;
        // Kilometry manewrów z silnika tras → metry linii trasy, po której liczona jest pozycja.
        final valhallaM = _route.distanceKm * 1000;
        _guidance = Guidance(_route.maneuvers, scale: valhallaM > 0 ? corridor.lengthM / valhallaM : 1);
      });
    } catch (error) {
      // Bez korytarza nie ma alarmu – kierowca musi o tym wiedzieć.
      if (mounted) setState(() => _corridorError = context.l.corridorFailed('$error'));
    }
  }

  void _onPosition(LatLng position) {
    final corridor = _corridor;
    final check = corridor?.check(position);
    final wasAlarm = _check?.alarm != null;
    setState(() {
      _position = position;
      _check = check;
      if (check?.alongM case final along?) _lastAlongM = along;
      if (check == null || check.onRoute || check.alarm != null) {
        _offRoute = 0;
      } else {
        _offRoute++;
      }
    });
    if (_follow) _map.move(position, _map.camera.zoom < 14 ? 16 : _map.camera.zoom);
    final alarm = check?.alarm != null;
    if (alarm && !wasAlarm) _startAlarm();
    if (!alarm && wasAlarm) _stopAlarm();
    if (!alarm && check?.alongM != null) _announce(check!.alongM!);
    if (_offRoute >= offRouteFixes && !_recalculating) _recalculate(position);
  }

  /// Komunikaty głosowe przy tej pozycji na trasie (najwyżej raz każdy).
  void _announce(double alongM) {
    final texts = _guidance?.announce(alongM, context.l) ?? const [];
    if (_voice && texts.isNotEmpty) _speaker.speak(texts.join(' '));
  }

  static String _speechLanguage(Locale locale) =>
      const {'pl': 'pl-PL', 'en': 'en-US', 'de': 'de-DE', 'cs': 'cs-CZ', 'sk': 'sk-SK'}[locale.languageCode] ??
      locale.toLanguageTag();

  Future<void> _startAlarm() async {
    _speaker.stop();
    _blink.repeat(reverse: true);
    HapticFeedback.heavyImpact();
    if (widget.alarmSound) {
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.play(AssetSource('alarm.wav'));
    }
  }

  Future<void> _stopAlarm() async {
    _blink
      ..stop()
      ..value = 0;
    await _player.stop();
  }

  /// Zjazd z trasy (nie na drogę nieprzejezdną): nowa trasa od pozycji do celu.
  Future<void> _recalculate(LatLng position) async {
    setState(() => _recalculating = true);
    // Punkty pośrednie już minięte nie są potrzebne w nowej trasie.
    final remaining = [for (final via in _via) if (_alongOf(via) > _lastAlongM) via];
    try {
      final body = await widget.api.post('/api/routes', {
        'origin': {'lat': position.latitude, 'lon': position.longitude},
        'destination': {'lat': widget.request.destination.latitude, 'lon': widget.request.destination.longitude},
        'via': [for (final v in remaining) {'lat': v.latitude, 'lon': v.longitude}],
        'vehicle_id': widget.request.vehicleId,
        'avoid_difficult': widget.request.avoidDifficult,
      }) as Map<String, dynamic>;
      setState(() {
        _route = RouteResult.fromJson(body).route;
        _via = remaining;
        _offRoute = 0;
        _lastAlongM = 0;
        _notice = context.l.rerouted;
      });
      await _loadCorridor();
    } catch (error) {
      if (mounted) setState(() => _notice = context.l.rerouteFailed('$error'));
    } finally {
      if (mounted) setState(() => _recalculating = false);
    }
  }

  double _alongOf(LatLng point) {
    final (_, segment, t) = nearestOnLine(point, _route.points);
    var along = 0.0;
    for (var i = 0; i < segment; i++) {
      along += distanceM(_route.points[i], _route.points[i + 1]);
    }
    return along + t * distanceM(_route.points[segment], _route.points[segment + 1]);
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    final alarm = check?.alarm;
    final l = context.l;
    return Scaffold(
      appBar: AppBar(title: Text(l.navigationTitle), actions: [
        IconButton(
          tooltip: _voice ? l.voiceOn : l.voiceOff,
          icon: Icon(_voice ? Icons.volume_up_outlined : Icons.volume_off_outlined),
          onPressed: () {
            setState(() => _voice = !_voice);
            if (!_voice) _speaker.stop();
          },
        ),
        IconButton(
          tooltip: _follow ? l.followingVehicle : l.backToVehicle,
          icon: Icon(_follow ? Icons.gps_fixed : Icons.gps_not_fixed),
          onPressed: () {
            setState(() => _follow = true);
            if (_position != null) _map.move(_position!, 16);
          },
        ),
      ]),
      body: Stack(children: [
        FlutterMap(
          mapController: _map,
          options: MapOptions(
            initialCameraFit: CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(_route.points), padding: const EdgeInsets.all(48)),
            onTap: (_, point) => _simulation.jump(point),
            onPositionChanged: (_, gesture) {
              if (gesture && _follow) setState(() => _follow = false);
            },
          ),
          children: [
            mapTiles(),
            PolylineLayer(polylines: [
              for (final item in _corridor?.items.where((i) => i.level == 'red') ?? <CorridorItem>[])
                if (item.line.length > 1) Polyline(points: item.line, strokeWidth: 3, color: levelColor('red').withOpacity(0.6)),
              for (final (points, level) in _route.coloredParts)
                Polyline(points: points, strokeWidth: 6, color: levelColor(level), borderStrokeWidth: 2, borderColor: Colors.white),
            ]),
            MarkerLayer(markers: [
              Marker(point: widget.request.destination, width: 30, height: 30, child: const _Pin('B', Color(0xFFA32D2D))),
              if (_position != null)
                Marker(
                  point: _position!,
                  width: 26,
                  height: 26,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: alarm != null ? levelColor('red') : const Color(0xFF185FA5),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.white, width: 3),
                      boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black45)],
                    ),
                  ),
                ),
            ]),
            SimpleAttributionWidget(source: Text(l.mapAttribution)),
          ],
        ),
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (check?.alongM case final along? when alarm == null)
              if (_guidance?.next(along) case final next?) _ManeuverCard(next: next),
            _StatusBanner(
              check: check,
              corridor: _corridor,
              corridorError: _corridorError,
              recalculating: _recalculating,
              notice: _notice,
            ),
          ]),
        ),
        Positioned(left: 12, bottom: 24, child: _simulationControls()),
        if (alarm != null)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _blink,
              builder: (context, child) => ColoredBox(
                color: Color.lerp(const Color(0xE6D62828), const Color(0xE6600000), _blink.value)!,
                child: child,
              ),
              child: SafeArea(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.white, size: 96),
                      Text(l.alarmTitle,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 12),
                      Text(alarm.message,
                          textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontSize: 20)),
                      const SizedBox(height: 12),
                      Text(l.alarmHint,
                          textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, fontSize: 16)),
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _simulationControls() {
    final l = context.l;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Tooltip(message: l.simulationHint, child: const Icon(Icons.science_outlined, size: 18)),
          const SizedBox(width: 8),
          for (final speed in [60.0, 600.0])
            TextButton(
              onPressed: () => setState(() => _simulation.drive(_route.points, fromM: _lastAlongM, speedKmh: speed)),
              child: Text(speed < 100 ? l.simulationDrive : l.simulationFast),
            ),
          if (_simulation.driving)
            TextButton(onPressed: () => setState(_simulation.stopDriving), child: Text(l.simulationStop)),
        ]),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.check,
    required this.corridor,
    required this.corridorError,
    required this.recalculating,
    required this.notice,
  });

  final PositionCheck? check;
  final Corridor? corridor;
  final String? corridorError;
  final bool recalculating;
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final check = this.check;
    final corridor = this.corridor;
    final l = context.l;
    final (color, text) = switch ((check, corridor)) {
      _ when corridorError != null => (Colors.orange.shade800, corridorError!),
      (_, null) => (Colors.grey.shade700, l.loadingCorridor),
      (null, _) => (const Color(0xFF185FA5), l.waitingForPosition),
      (final c?, final k?) when c.onRoute =>
        (const Color(0xFF3B6D11), l.onRouteRemaining(l.km((k.lengthM - (c.alongM ?? 0)) / 1000))),
      (final c?, _) when c.alarm != null => (const Color(0xFFD62828), c.alarm!.message),
      _ => (Colors.orange.shade800, recalculating ? l.offRouteRecalculating : l.offRoute),
    };
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(text, style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
          if (notice != null)
            Text(notice!, style: const TextStyle(color: Colors.white70)),
        ]),
      ),
    );
  }
}

/// Następny manewr: strzałka, odległość i napis (np. „300 m · Skręć w prawo w DK94”).
class _ManeuverCard extends StatelessWidget {
  const _ManeuverCard({required this.next});

  final NextManeuver next;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Card(
      color: const Color(0xFF1F2A33),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Icon(maneuverIcon(next.maneuver.type), color: Colors.white, size: 48),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(Guidance.display(l, next.distanceM),
                  style: const TextStyle(color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
              Text(next.maneuver.instruction, style: const TextStyle(color: Colors.white, fontSize: 16)),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Strzałka do rodzaju manewru Valhalli.
IconData maneuverIcon(int type) => switch (type) {
      >= 1 && <= 3 => Icons.navigation_outlined,
      >= 4 && <= 6 => Icons.flag_outlined,
      9 => Icons.turn_slight_right,
      10 => Icons.turn_right,
      11 => Icons.turn_sharp_right,
      12 => Icons.u_turn_right,
      13 => Icons.u_turn_left,
      14 => Icons.turn_sharp_left,
      15 => Icons.turn_left,
      16 => Icons.turn_slight_left,
      18 || 20 => Icons.ramp_right,
      19 || 21 => Icons.ramp_left,
      23 => Icons.fork_right,
      24 => Icons.fork_left,
      25 => Icons.merge,
      26 || 27 => Icons.roundabout_right,
      28 || 29 => Icons.directions_boat_outlined,
      _ => Icons.straight,
    };

class _Pin extends StatelessWidget {
  const _Pin(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
        child: Center(child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700))),
      );
}
