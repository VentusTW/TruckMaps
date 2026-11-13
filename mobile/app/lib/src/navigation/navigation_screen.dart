import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../planner/clusters.dart';
import '../planner/place_field.dart' show Place;
import '../planner/planner_screen.dart' show mapTiles, nightMapTiles;
import '../planner/route.dart';
import '../reports/report_sheet.dart';
import 'corridor.dart';
import 'guidance.dart';
import 'live_sharing.dart';
import 'nav_widgets.dart';
import 'route_events.dart';
import 'speech.dart';

/// Skąd nawigacja bierze pozycję: GPS albo symulacja (testy, pokaz bez jazdy).
abstract class PositionSource {
  Stream<LatLng> get positions;
  Future<void> dispose();
}

enum GpsProblem { disabled, denied }

/// Ustawienia GPS nawigacji: najlepsza dokładność co 5 m, praca w tle i przy wygaszonym ekranie.
LocationSettings navigationLocationSettings(String title, String text,
    {TargetPlatform? platform}) {
  const accuracy = LocationAccuracy.bestForNavigation;
  const distanceFilter = 5;
  switch (kIsWeb ? null : platform ?? defaultTargetPlatform) {
    case TargetPlatform.android:
      return AndroidSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        foregroundNotificationConfig: ForegroundNotificationConfig(
          notificationTitle: title,
          notificationText: text,
          notificationChannelName: title,
          enableWakeLock: true,
          setOngoing: true,
        ),
      );
    case TargetPlatform.iOS:
      return AppleSettings(
        accuracy: accuracy,
        distanceFilter: distanceFilter,
        activityType: ActivityType.automotiveNavigation,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: true,
        allowBackgroundLocationUpdates: true,
      );
    default:
      return const LocationSettings(accuracy: accuracy, distanceFilter: distanceFilter);
  }
}

class GpsPositions implements PositionSource {
  final _controller = StreamController<LatLng>.broadcast();
  StreamSubscription<Position>? _subscription;

  /// Prosi o zgodę na lokalizację; `null` – GPS działa. Na Androidzie pozycje płyną też przy
  /// wygaszonym ekranie i w tle (usługa pierwszoplanowa z powiadomieniem [notificationTitle] /
  /// [notificationText]), na iOS – w trybie tła nawigacji (niebieski wskaźnik na pasku).
  Future<GpsProblem?> start({String notificationTitle = 'TruckMaps', String notificationText = ''}) async {
    if (!await Geolocator.isLocationServiceEnabled()) return GpsProblem.disabled;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return GpsProblem.denied;
    }
    _subscription = Geolocator.getPositionStream(
      locationSettings: navigationLocationSettings(notificationTitle, notificationText),
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
    this.viaNames = const [],
    this.avoidDifficult = true,
    this.reports = const [],
    this.bans = const [],
    this.deadline,
  });

  final String vehicleId;
  final PlannedRoute route;
  final LatLng destination;
  final List<LatLng> via;
  final List<String> viaNames;
  final bool avoidDifficult;

  /// Zgłoszenia kierowców i zakazy ruchu na tej trasie (z odpowiedzi planera).
  final List<DriverReport> reports;
  final List<RoutePlace> bans;

  /// Koniec okna rozładunku (ze zlecenia) – godzina przyjazdu na czerwono, gdy później.
  final DateTime? deadline;
}

/// Ile kolejnych pozycji poza trasą (nie na drodze czerwonej), zanim trasa jest przeliczana.
const offRouteFixes = 3;

/// Najmniejszy przejazd między pozycjami, z którego liczony jest kierunek jazdy.
const headingMinStepM = 8.0;

/// Punkt pośredni jest „minięty”, gdy pojazd jest o tyle bliżej celu niż on i o tyle od niego
/// daleko – kierowca pojechał inaczej. „Jedź przez” jest wtedy odpuszczany, przystanek – po pytaniu.
const viaPassedM = 1000.0;

/// Czy punkt [via] został minięty: pojazd w [position] jest wyraźnie bliżej [destination].
bool viaPassed(LatLng via, LatLng position, LatLng destination) =>
    distanceM(position, destination) + viaPassedM < distanceM(via, destination) &&
    distanceM(position, via) > viaPassedM;

/// Zapowiedź głosowa zdarzeń na trasie (fotoradar, przejazd kolejowy, zgłoszenia, zakazy).
const _spokenKinds = {'speed_camera', 'average_speed', 'level_crossing', 'ban', 'red', 'orange'};
const eventVoiceM = 500.0;

/// Poniżej tej prędkości (m/s, ok. 3 km/h) pojazd stoi – przestój w statystykach.
const idleSpeedMs = 0.8;

enum MapTheme { auto, day, night }

/// Mapa nocą: odwrócone jasności kafelków w szarościach (bez osobnego stylu mapy).
const _nightTiles = ColorFilter.matrix([
  -0.2126, -0.7152, -0.0722, 0, 235, //
  -0.2126, -0.7152, -0.0722, 0, 235,
  -0.2126, -0.7152, -0.0722, 0, 245,
  0, 0, 0, 1, 0,
]);

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({
    super.key,
    required this.api,
    required this.request,
    this.source,
    this.alarmSound = true,
    this.speaker,
    this.clock,
    this.liveConsent,
  });

  final CoreApi api;
  final NavigationRequest request;

  /// Źródło pozycji podane z góry (testy); zwykle GPS z symulacją pod ręką.
  final PositionSource? source;
  final bool alarmSound;

  /// Głos podany z góry (testy); zwykle syntezator mowy systemu w języku aplikacji.
  final Speaker? speaker;

  /// Zegar podany z góry (testy prędkości i trybu nocnego).
  final DateTime Function()? clock;

  /// Zgoda na udostępnianie pozycji firmie (testy); zwykle zapisana na urządzeniu.
  final LiveConsentStore? liveConsent;

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> with SingleTickerProviderStateMixin {
  final _map = MapController();
  final _simulation = SimulatedPositions();
  final _player = AudioPlayer();
  late final AnimationController _blink;
  GpsPositions? _gps;
  final List<StreamSubscription<LatLng>> _subscriptions = [];

  late PlannedRoute _route = widget.request.route;
  late List<LatLng> _via = widget.request.via;
  late List<String> _viaNames = widget.request.viaNames;

  /// Które punkty pośrednie są przystankami (parking, MOP dodany w trakcie jazdy), a które
  /// tylko „Jedź przez”. Przystanku nie odpuszczamy bez pytania.
  late List<bool> _viaStops = [for (final _ in widget.request.via) false];
  late List<DriverReport> _reports = widget.request.reports;
  late List<RoutePlace> _bans = widget.request.bans;
  Corridor? _corridor;
  String? _corridorError;
  LatLng? _position;

  /// Kierunek jazdy z ostatnich pozycji – przy przeliczaniu trasy silnik nie każe zawracać.
  double? _headingDeg;
  LatLng? _headingFrom;
  PositionCheck? _check;
  int _offRoute = 0;

  /// Przejazd do statystyk pojazdu: tylko pozycje prawdziwe (GPS albo podane z góry), bez symulacji.
  DateTime? _tripStart;
  LatLng? _tripLast;
  double _tripM = 0;

  /// Przestoje: czas między pozycjami, gdy pojazd prawie stoi (do statystyk pojazdu).
  DateTime? _tripLastAt;
  Duration _idle = Duration.zero;

  /// Z ładunkiem albo pusty przejazd – kierowca przełącza (puste km w statystykach).
  bool _loaded = true;

  /// Ile trasy przejechano przy ostatniej pozycji na trasie (do pominięcia minionych punktów).
  double _lastAlongM = 0;
  bool _recalculating = false;
  String? _notice;
  bool _follow = true;
  Guidance? _guidance;
  bool _voice = true;
  MapTheme _theme = MapTheme.auto;
  final _speedMeter = SpeedMeter();
  double? _speedKmh;
  final _eventsSpoken = <(String, int)>{};
  // Tworzony przy pierwszym komunikacie (potrzebny język z kontekstu), zamykany tylko, gdy powstał.
  Speaker? _speakerOrNull;
  Speaker get _speaker =>
      _speakerOrNull ??= widget.speaker ?? systemSpeaker(_speechLanguage(Localizations.localeOf(context)));

  DateTime _now() => widget.clock?.call() ?? DateTime.now();

  /// Linie trasy i dróg nieprzejezdnych – budowane raz dla trasy i korytarza, nie przy każdej
  /// pozycji GPS (mapa porównuje linie po zawartości, a trasa ma tysiące punktów).
  List<Polyline> _lines = const [];
  (PlannedRoute, Corridor?)? _linesFor;

  List<Polyline> get _routeLines {
    final key = (_route, _corridor);
    if (_linesFor != key) {
      _linesFor = key;
      _lines = [
        for (final item in _corridor?.items ?? <CorridorItem>[])
          if (item.level == 'red' && item.line.length > 1)
            Polyline(points: item.line, strokeWidth: 3, color: levelColor('red').withOpacity(0.6)),
        for (final (points, level) in _route.coloredParts)
          Polyline(points: points, strokeWidth: 6, color: levelColor(level), borderStrokeWidth: 2, borderColor: Colors.white),
      ];
    }
    return _lines;
  }

  /// Zdarzenia i ograniczenia prędkości – liczone raz dla trasy.
  late List<NavEvent> _events;
  late SpeedLimits _limits;
  late double _lengthM;

  void _prepareRoute() {
    _lengthM = cumulativeM(_route.points).last;
    _limits = SpeedLimits(_route.points, _route.speedLimits);
    _events = navEvents(
      route: _route,
      lengthM: _lengthM,
      reports: _reports,
      bans: _bans,
      via: _via,
      destination: widget.request.destination,
      alongOf: _alongOf,
    );
    _eventMarkers = [
      for (final e in _events)
        if (e.kind != 'traffic_signals' && e.kind != 'destination')
          Marker(
            point: e.point,
            width: 26,
            height: 26,
            child: CircleAvatar(
              backgroundColor: navPanelColor,
              child: Icon(eventIcon(e), size: 15, color: eventColor(e)),
            ),
          ),
    ];
  }

  /// Znaczniki zdarzeń – budowane raz dla trasy, nie przy każdej pozycji GPS.
  late List<Marker> _eventMarkers;

  @override
  void initState() {
    super.initState();
    _blink = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _prepareRoute();
    _loadCorridor();
    _listen(widget.source ?? _simulation, real: widget.source != null);
    if (widget.source == null) _startGps();
  }

  /// Centrala & Live Map: pozycja pojazdu firmy wysyłana co 30 s (za zgodą kierowcy).
  LiveSharing? _live;

  Future<void> _startLive() async {
    final live = LiveSharing(
      api: widget.api,
      vehicleId: widget.request.vehicleId,
      consent: widget.liveConsent ?? const SecureLiveConsentStore(),
      ask: _askLiveConsent,
      current: _liveFix,
    );
    _live = live;
    if (await live.start() && mounted) setState(() => _notice = context.l.liveSharingOn);
  }

  Future<bool> _askLiveConsent() async {
    if (!mounted) return false;
    final allowed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text(context.l.liveConsentTitle),
        content: Text(context.l.liveConsentText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l.liveConsentDeny)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l.liveConsentAllow)),
        ],
      ),
    );
    return allowed ?? false;
  }

  LiveFix? _liveFix() {
    final position = _position;
    if (position == null) return null;
    final total = _route.distanceKm;
    final remaining = (total - _lastAlongM / 1000).clamp(0.0, total);
    final minutes = total > 0 ? _route.durationMin * remaining / total : null;
    return LiveFix(
      lat: position.latitude,
      lon: position.longitude,
      speedKmh: _speedKmh,
      heading: _headingDeg,
      remainingKm: remaining,
      eta: minutes == null ? null : _now().add(Duration(seconds: (minutes * 60).round())),
    );
  }

  Future<void> _startGps() async {
    final gps = GpsPositions();
    final problem = await gps.start(
      notificationTitle: context.l.navBackgroundTitle,
      notificationText: context.l.navBackgroundText,
    );
    if (!mounted) return;
    if (problem != null) {
      setState(() => _notice = problem == GpsProblem.disabled ? context.l.gpsDisabled : context.l.gpsDenied);
      await gps.dispose();
      return;
    }
    _gps = gps;
    _listen(gps);
    _startLive();
  }

  void _listen(PositionSource source, {bool real = true}) => _subscriptions.add(source.positions.listen((position) {
        if (real) _track(position);
        _onPosition(position);
      }));

  /// Skok dalej niż 2 km między pozycjami to błąd GPS, nie jazda.
  void _track(LatLng position) {
    final now = _now().toUtc();
    _tripStart ??= now;
    if (_tripLast case final last?) {
      final step = distanceM(last, position);
      if (step < 2000) _tripM += step;
      final elapsed = now.difference(_tripLastAt ?? now);
      // Wolniej niż ok. 3 km/h przez dłużej niż 10 s – postój (korek, załadunek, przerwa).
      if (elapsed.inSeconds >= 10 && elapsed.inSeconds < 3600 && step / elapsed.inSeconds < idleSpeedMs) {
        _idle += elapsed;
      }
    }
    _tripLast = position;
    _tripLastAt = now;
  }

  /// Koniec nawigacji: przejazd od 0,5 km trafia do statystyk pojazdu (bez sieci – przepada).
  void _saveTrip() {
    final start = _tripStart;
    if (start == null || _tripM < 500) return;
    final cost = widget.request.route.cost;
    widget.api.post('/api/vehicles/${widget.request.vehicleId}/trips', {
      'started_at': start.toIso8601String(),
      'ended_at': DateTime.now().toUtc().toIso8601String(),
      'distance_km': double.parse((_tripM / 1000).toStringAsFixed(2)),
      'planned_km': _route.distanceKm,
      if (cost != null) 'cost_amount': cost.amount,
      if (cost != null) 'cost_currency': cost.currency,
      'loaded': _loaded,
      'idle_min': double.parse((_idle.inSeconds / 60).toStringAsFixed(1)),
    }).ignore();
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    _live?.stop();
    _gps?.dispose();
    _simulation.dispose();
    _player.dispose();
    _speakerOrNull?.dispose();
    _blink.dispose();
    _saveTrip();
    // Koniec jazdy: pojazd przestaje być „w użyciu” (bez sieci – serwer zwolni go sam po czasie).
    widget.api.post('/api/vehicles/${widget.request.vehicleId}/release', {}).ignore();
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
    final speed = _speedMeter.add(position, _now());
    // Kierunek dopiero po kilku metrach jazdy – na postoju GPS „pływa”.
    final from = _headingFrom;
    if (from == null) {
      _headingFrom = position;
    } else if (distanceM(from, position) >= headingMinStepM) {
      _headingDeg = bearingDeg(from, position);
      _headingFrom = position;
    }
    setState(() {
      _position = position;
      _check = check;
      _speedKmh = speed;
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

  /// Pozycja na mapie: na trasie – dopasowana do linii trasy (bez skakania obok drogi).
  LatLng? get _shownPosition {
    final along = _check?.alongM;
    final corridor = _corridor;
    if (_check?.onRoute == true && along != null && corridor != null) return corridor.pointAt(along) ?? _position;
    return _position;
  }

  /// Zgłoszenie w miejscu pojazdu jednym dotknięciem; przy celu najpierw punkty dostawy.
  Future<void> _report(LatLng position) async {
    final nearEnd = distanceM(position, widget.request.destination) < 500;
    final saved = await showReportSheet(context, widget.api, position, deliveryFirst: nearEnd);
    if (saved != null && mounted) setState(() => _notice = context.l.reportSaved(saved.message));
  }

  /// Komunikaty głosowe przy tej pozycji na trasie (najwyżej raz każdy).
  void _announce(double alongM) {
    final l = context.l;
    final texts = [..._guidance?.announce(alongM, l, speedKmh: _speedKmh) ?? const <String>[]];
    for (final e in upcoming(_events, alongM, withinM: eventVoiceM, signals: false)) {
      final spoken = _spokenKinds.contains(e.kind) || e.kind.startsWith('report:');
      if (spoken && e.alongM > alongM && _eventsSpoken.add((e.kind, e.alongM.round()))) {
        final label = eventLabel(l, e);
        texts.add(l.voiceIn(Guidance.spoken(l, e.alongM - alongM), label[0].toLowerCase() + label.substring(1)));
      }
    }
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

  /// Zjazd z trasy (nie na drogę nieprzejezdną): nowa trasa od pozycji do celu; [stop] –
  /// nowy przystanek (parking, MOP) przed pozostałymi punktami pośrednimi.
  Future<void> _recalculate(LatLng position, {Place? stop}) async {
    setState(() => _recalculating = true);
    // Punkty pośrednie już przejechane nie są potrzebne w nowej trasie. Ominięty punkt
    // „Jedź przez” odpuszczamy sam, ominięty przystanek – tylko gdy kierowca potwierdzi.
    final skipped = <String>[];
    final remaining = <(LatLng, String, bool)>[
      if (stop != null) (stop.point, stop.label, true),
    ];
    for (final (i, via) in _via.indexed) {
      if (_alongOf(via) <= _lastAlongM) continue;
      final name = i < _viaNames.length ? _viaNames[i] : '';
      final isStop = i < _viaStops.length && _viaStops[i];
      if (stop == null && viaPassed(via, position, widget.request.destination)) {
        if (!isStop) {
          skipped.add(name);
          continue;
        }
        if (await _confirmSkipStop(name)) continue;
      }
      remaining.add((via, name, isStop));
    }
    try {
      final body = await widget.api.post('/api/routes', {
        'origin': {
          'lat': position.latitude,
          'lon': position.longitude,
          if (_headingDeg case final heading?) 'heading': heading,
        },
        'destination': {'lat': widget.request.destination.latitude, 'lon': widget.request.destination.longitude},
        'via': [for (final (v, _, _) in remaining) {'lat': v.latitude, 'lon': v.longitude}],
        'vehicle_id': widget.request.vehicleId,
        'avoid_difficult': widget.request.avoidDifficult,
        // Przeliczenie w trakcie jazdy nie zużywa limitu tras planu.
        'reroute': true,
      }) as Map<String, dynamic>;
      final result = RouteResult.fromJson(body);
      setState(() {
        _route = result.route;
        _reports = result.driverReports;
        _bans = result.timeBans;
        _via = [for (final (v, _, _) in remaining) v];
        _viaNames = [for (final (_, name, _) in remaining) name];
        _viaStops = [for (final (_, _, isStop) in remaining) isStop];
        _offRoute = 0;
        _lastAlongM = 0;
        _eventsSpoken.clear();
        _prepareRoute();
        _notice = [
          stop != null ? context.l.navStopAdded(stop.label) : context.l.rerouted,
          for (final name in skipped) context.l.navViaSkipped(name.isEmpty ? '–' : name),
          // Start albo cel przesunięty (np. zamknięta droga przy celu) – prowadzimy dalej.
          ...result.issues,
        ].join(' ');
      });
      await _loadCorridor();
    } catch (error) {
      if (mounted) setState(() => _notice = context.l.rerouteFailed('$error'));
    } finally {
      if (mounted) setState(() => _recalculating = false);
    }
  }

  double _alongOf(LatLng point) {
    if (_route.points.length < 2) return 0;
    final (_, segment, t) = nearestOnLine(point, _route.points);
    var along = 0.0;
    for (var i = 0; i < segment; i++) {
      along += distanceM(_route.points[i], _route.points[i + 1]);
    }
    return along + t * distanceM(_route.points[segment], _route.points[segment + 1]);
  }

  /// Pytanie, czy pominąć ominięty przystanek (domyślnie – nie, trasa wraca do niego).
  Future<bool> _confirmSkipStop(String name) async {
    if (!mounted) return false;
    final skip = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.l.navSkipStopTitle),
        content: Text(context.l.navSkipStopQuestion(name.isEmpty ? '–' : name)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.l.navSkipStopKeep)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.l.navSkipStopSkip)),
        ],
      ),
    );
    return skip ?? false;
  }

  /// „+”: zgłoszenie albo nowy przystanek (parking, MOP) w miejscu pojazdu.
  Future<void> _more() async {
    final position = _position;
    if (position == null) return;
    final l = context.l;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.campaign_outlined),
            title: Text(l.navReportAction),
            onTap: () => Navigator.pop(context, 'report'),
          ),
          ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: Text(l.navAddStop),
            onTap: () => Navigator.pop(context, 'stop'),
          ),
        ]),
      ),
    );
    if (!mounted) return;
    if (choice == 'report') await _report(position);
    if (choice == 'stop') await _poi();
  }

  /// „POI”: parkingi dla ciężarówek i MOP-y w pobliżu; „Jedź tutaj” – przystanek na trasie.
  Future<void> _poi() async {
    final position = _position;
    if (position == null) return;
    final stop = await showModalBottomSheet<Place>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => PoiSheet(api: widget.api, position: position),
    );
    if (stop != null && mounted) await _recalculate(_position ?? position, stop: stop);
  }

  bool get _night => switch (_theme) {
        MapTheme.night => true,
        MapTheme.day => false,
        MapTheme.auto => isDark(_now(), _position ?? widget.request.destination),
      };

  @override
  Widget build(BuildContext context) {
    final check = _check;
    final alarm = check?.alarm;
    final l = context.l;
    final along = check?.alongM ?? _lastAlongM;
    final next = alarm == null && check?.alongM != null ? _guidance?.next(along) : null;
    final then = next == null ? null : _guidance?.after(next.maneuver);
    final lengthM = _corridor?.lengthM ?? _lengthM;
    final remainingM = (lengthM - along).clamp(0.0, double.infinity);
    final remainingMin = lengthM > 0 ? _route.durationMin * remainingM / lengthM : _route.durationMin;
    final arrival = _now().add(Duration(seconds: (remainingMin * 60).round()));
    final deadline = widget.request.deadline;
    final ahead = upcoming(_events, along, withinM: 10000, signals: false)
        .where((e) => e.kind != 'destination' && (check?.alongM != null))
        .take(3)
        .toList();
    final nextVia = _events.where((e) => e.kind == 'via' && e.alongM > along).firstOrNull;
    final showStatus = _corridorError != null ||
        _corridor == null ||
        check == null ||
        !check.onRoute ||
        _notice != null ||
        _recalculating;
    final position = _shownPosition;
    return Scaffold(
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
            if (_night) nightMapTiles?.call() ?? ColorFiltered(colorFilter: _nightTiles, child: mapTiles()) else mapTiles(),
            PolylineLayer(polylines: _routeLines),
            ClusteredMarkerLayer(color: navPanelColor, markers: _eventMarkers),
            MarkerLayer(markers: [
              Marker(
                point: widget.request.destination,
                width: 34,
                height: 34,
                child: const CircleAvatar(
                  backgroundColor: navPanelColor,
                  child: Icon(Icons.sports_score, color: Colors.white, size: 20),
                ),
              ),
              if (position != null)
                Marker(
                  point: position,
                  width: 26,
                  height: 26,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: alarm != null ? levelColor('red') : TruckPalette.start,
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
        SafeArea(
          child: LayoutBuilder(builder: (context, size) {
            final wide = size.maxWidth >= 700;
            final tall = size.maxHeight >= 640;
            final cardWidth = wide ? 420.0 : size.maxWidth - 88;
            return Stack(children: [
              Positioned(
                left: 12,
                top: 12,
                width: cardWidth,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (next != null) ManeuverPanel(next: next),
                  if (then != null) ...[
                    const SizedBox(height: 6),
                    NextStreetPill(maneuver: then),
                  ],
                  if (showStatus) ...[
                    const SizedBox(height: 6),
                    _StatusBanner(
                      check: check,
                      corridor: _corridor,
                      corridorError: _corridorError,
                      recalculating: _recalculating,
                      notice: _notice,
                    ),
                  ],
                  if (ahead.isNotEmpty && tall) ...[
                    const SizedBox(height: 6),
                    UpcomingList(events: ahead, alongM: along),
                  ],
                ]),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: Column(children: [
                  RoundButton(
                    tooltip: _voice ? l.voiceOn : l.voiceOff,
                    icon: _voice ? Icons.volume_up_outlined : Icons.volume_off_outlined,
                    size: 44,
                    onPressed: () {
                      setState(() => _voice = !_voice);
                      if (!_voice) _speaker.stop();
                    },
                  ),
                  const SizedBox(height: 8),
                  RoundButton(
                    tooltip: _follow ? l.followingVehicle : l.backToVehicle,
                    icon: _follow ? Icons.gps_fixed : Icons.gps_not_fixed,
                    size: 44,
                    onPressed: () {
                      setState(() => _follow = true);
                      if (_position != null) _map.move(_position!, 16);
                    },
                  ),
                  const SizedBox(height: 8),
                  RoundButton(
                    tooltip: switch (_theme) {
                      MapTheme.auto => l.navThemeAuto,
                      MapTheme.day => l.navThemeDay,
                      MapTheme.night => l.navThemeNight,
                    },
                    icon: switch (_theme) {
                      MapTheme.auto => Icons.brightness_auto_outlined,
                      MapTheme.day => Icons.light_mode_outlined,
                      MapTheme.night => Icons.dark_mode_outlined,
                    },
                    size: 44,
                    onPressed: () => setState(() => _theme = MapTheme.values[(_theme.index + 1) % 3]),
                  ),
                  const SizedBox(height: 8),
                  RoundButton(
                    tooltip: _loaded ? l.navLoaded : l.navEmpty,
                    icon: _loaded ? Icons.inventory_2 : Icons.inventory_2_outlined,
                    size: 44,
                    onPressed: () => setState(() => _loaded = !_loaded),
                  ),
                  if (tall && check?.alongM != null) ...[
                    const SizedBox(height: 8),
                    RouteStrip(events: _events, alongM: along, height: wide ? 300 : 200),
                  ],
                ]),
              ),
              Positioned(
                left: 12,
                right: 12,
                bottom: 12,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        SpeedPanel(
                          limit: check?.alongM == null ? null : _limits.at(along),
                          change: check?.alongM == null ? null : _limits.nextChange(along),
                          speedKmh: _speedKmh,
                        ),
                        const SizedBox(height: 8),
                        _simulationControls(),
                      ]),
                    ),
                    if (_position != null)
                      Column(mainAxisSize: MainAxisSize.min, children: [
                        RoundButton(tooltip: l.navPoi, icon: Icons.local_parking, onPressed: _poi),
                        const SizedBox(height: 8),
                        RoundButton(tooltip: l.navMore, icon: Icons.add, onPressed: _more),
                      ]),
                  ]),
                  const SizedBox(height: 8),
                  BottomPanel(
                    arrival: arrival,
                    remainingM: remainingM,
                    remainingMin: remainingMin,
                    late: deadline != null && arrival.isAfter(deadline),
                    nextVia: nextVia == null
                        ? null
                        : (
                            nextVia.index ?? 1,
                            _via.length,
                            lengthM > 0 ? _route.durationMin * (nextVia.alongM - along) / lengthM : 0,
                            nextVia.alongM - along,
                          ),
                    onEnd: () => Navigator.of(context).maybePop(),
                    progress: RouteProgress(alongM: along, lengthM: lengthM, events: _events),
                  ),
                ]),
              ),
            ]);
          }),
        ),
        if (alarm != null)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _blink,
              builder: (context, child) => ColoredBox(
                color: Color.lerp(TruckPalette.navAlarm, TruckPalette.navAlarmDark, _blink.value)!,
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
    return NavPanel(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 0),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Tooltip(message: l.simulationHint, child: const Icon(Icons.science_outlined, size: 18, color: Colors.white70)),
        const SizedBox(width: 4),
        for (final speed in [60.0, 600.0])
          TextButton(
            onPressed: () => setState(() => _simulation.drive(_route.points, fromM: _lastAlongM, speedKmh: speed)),
            child: Text(speed < 100 ? l.simulationDrive : l.simulationFast, style: const TextStyle(color: navAccent)),
          ),
        if (_simulation.driving)
          TextButton(
            onPressed: () => setState(_simulation.stopDriving),
            child: Text(l.simulationStop, style: const TextStyle(color: navAccent)),
          ),
      ]),
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
      _ when corridorError != null => (TruckPalette.navOffRoute, corridorError!),
      (_, null) => (navPanelColor, l.loadingCorridor),
      (null, _) => (navPanelColor, l.waitingForPosition),
      (final c?, final k?) when c.onRoute =>
        (TruckPalette.navOnRoute, l.onRouteRemaining(l.km((k.lengthM - (c.alongM ?? 0)) / 1000))),
      (final c?, _) when c.alarm != null => (TruckPalette.navAlarm, c.alarm!.message),
      _ => (TruckPalette.navOffRoute, recalculating ? l.offRouteRecalculating : l.offRoute),
    };
    return NavPanel(
      color: color,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        if (notice != null) Text(notice!, style: const TextStyle(color: Colors.white70)),
      ]),
    );
  }
}

/// Parkingi dla ciężarówek i MOP-y w promieniu 20 km; wybór zwraca przystanek.
class PoiSheet extends StatefulWidget {
  const PoiSheet({super.key, required this.api, required this.position});

  final CoreApi api;
  final LatLng position;

  @override
  State<PoiSheet> createState() => _PoiSheetState();
}

class _PoiSheetState extends State<PoiSheet> {
  late final Future<dynamic> _parkings = widget.api
      .get('/api/routes/parkings?lat=${widget.position.latitude}&lon=${widget.position.longitude}');

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.navPoiTitle, style: Theme.of(context).textTheme.titleMedium),
          Text(l.navPoiHint, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 8),
          FutureBuilder<dynamic>(
            future: _parkings,
            builder: (context, snapshot) {
              if (snapshot.hasError) return Text('${snapshot.error}');
              if (!snapshot.hasData) return const LinearProgressIndicator();
              final items = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
              if (items.isEmpty) return Text(l.navPoiEmpty);
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.5),
                child: ListView(shrinkWrap: true, children: [
                  for (final p in items)
                    ListTile(
                      leading: Icon(p['kind'] == 'truck_parking' ? Icons.local_parking : Icons.local_cafe_outlined),
                      title: Text('${p['name'] ?? p['kind_label']}'),
                      subtitle: Text([
                        if (p['name'] != null) '${p['kind_label']}',
                        '${l.km((p['distance_m'] as num) / 1000)} km',
                        if (p['hgv_capacity'] != null) l.navPoiCapacity(p['hgv_capacity'] as int),
                      ].join(' · ')),
                      trailing: Text(l.navPoiGo, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
                      onTap: () => Navigator.pop(
                        context,
                        Place('${p['name'] ?? p['kind_label']}',
                            LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble())),
                      ),
                    ),
                ]),
              );
            },
          ),
        ]),
      ),
    );
  }
}
