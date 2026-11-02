import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../planner/route.dart';
import 'corridor.dart';

/// Zdarzenie na trasie do paska postępu, pionowego paska i listy nadchodzących:
/// punkty z OSM, zgłoszenia kierowców, zakazy ruchu, trudne miejsca, punkty pośrednie, cel.
class NavEvent {
  const NavEvent(this.kind, this.alongM, this.point, {this.endM, this.message, this.speedKmh, this.index});

  /// `level_crossing`, `speed_camera`, `traffic_signals`, `average_speed`, `no_overtaking`,
  /// `report:<rodzaj>`, `ban`, `red` / `orange`, `via`, `destination`.
  final String kind;
  final double alongM;
  final double? endM;
  final LatLng point;

  /// Tekst z serwera (zgłoszenie, zakaz, ostrzeżenie oceny).
  final String? message;
  final double? speedKmh;

  /// Numer punktu pośredniego (od 1).
  final int? index;

  /// Odcinek (pomiar odcinkowy, zakaz wyprzedzania) obejmuje to miejsce.
  bool covers(double alongM) => endM != null && this.alongM <= alongM && alongM <= endM!;
}

/// Zdarzenia z odpowiedzi planera. Kilometry z serwera liczone są po linii trasy – tej samej,
/// po której nawigacja liczy pozycję; punkty pośrednie rzutowane na linię ([alongOf]).
List<NavEvent> navEvents({
  required PlannedRoute route,
  required double lengthM,
  List<DriverReport> reports = const [],
  List<RoutePlace> bans = const [],
  List<LatLng> via = const [],
  LatLng? destination,
  required double Function(LatLng) alongOf,
}) {
  final events = <NavEvent>[
    for (final e in route.roadEvents)
      NavEvent(e.kind, e.km * 1000, e.point, endM: e.endKm == null ? null : e.endKm! * 1000, speedKmh: e.speedKmh),
    for (final r in reports)
      if (r.km != null) NavEvent('report:${r.kind}', r.km! * 1000, r.point, message: r.message),
    for (final b in bans) NavEvent('ban', b.km * 1000, b.point, message: b.message),
    for (final w in route.warnings)
      if (w.level == 'red' || w.level == 'orange') NavEvent(w.level, w.km * 1000, w.point, message: w.message),
    for (final (i, v) in via.indexed) NavEvent('via', alongOf(v), v, index: i + 1),
    if (destination != null) NavEvent('destination', lengthM, destination),
  ];
  events.sort((a, b) => a.alongM.compareTo(b.alongM));
  return events;
}

/// Zdarzenia przed pojazdem (najbliższe pierwsze); sygnalizacja tylko na liście pełnej –
/// w mieście jest jej za dużo, by zasłaniała resztę.
List<NavEvent> upcoming(List<NavEvent> events, double alongM,
        {double withinM = double.infinity, bool signals = true}) =>
    [
      for (final e in events)
        if ((e.alongM >= alongM - 5 || e.covers(alongM)) && e.alongM - alongM <= withinM)
          if (signals || e.kind != 'traffic_signals') e,
    ];

/// Odległości od początku linii do każdego punktu [m].
List<double> cumulativeM(List<LatLng> points) {
  final out = <double>[0];
  for (var i = 1; i < points.length; i++) {
    out.add(out.last + distanceM(points[i - 1], points[i]));
  }
  return out;
}

/// Ograniczenia prędkości po metrach linii trasy.
class SpeedLimits {
  SpeedLimits(List<LatLng> points, List<SpeedLimit> limits) {
    final along = cumulativeM(points);
    double at(int i) => along.isEmpty ? 0 : along[i.clamp(0, along.length - 1)];
    _parts = [for (final s in limits) (at(s.start), at(s.end), s)];
  }

  late final List<(double, double, SpeedLimit)> _parts;

  SpeedLimit? at(double alongM) {
    for (final (start, end, limit) in _parts) {
      if (start <= alongM && alongM < end) return limit;
      if (start > alongM) break;
    }
    return null;
  }

  /// Zmiana ograniczenia w najbliższych [withinM] metrach: (nowa wartość, odległość).
  (int, double)? nextChange(double alongM, {double withinM = 500}) {
    final now = at(alongM)?.kmh;
    for (final (start, _, limit) in _parts) {
      if (start <= alongM) continue;
      if (start - alongM > withinM) break;
      if (limit.kmh != now) return (limit.kmh, start - alongM);
    }
    return null;
  }
}

/// Prędkość z kolejnych pozycji: średnia z ostatnich kilku sekund (GPS i symulacja tak samo).
class SpeedMeter {
  SpeedMeter({this.window = const Duration(seconds: 4)});

  final Duration window;
  final _samples = <(DateTime, LatLng)>[];

  /// km/h; `null` – za mało pozycji.
  double? add(LatLng position, DateTime time) {
    _samples.add((time, position));
    while (_samples.length > 2 && time.difference(_samples.first.$1) > window) {
      _samples.removeAt(0);
    }
    if (_samples.length < 2) return null;
    var meters = 0.0;
    for (var i = 1; i < _samples.length; i++) {
      meters += distanceM(_samples[i - 1].$2, _samples[i].$2);
    }
    final seconds = time.difference(_samples.first.$1).inMilliseconds / 1000;
    if (seconds <= 0) return null;
    return meters / seconds * 3.6;
  }
}

/// Przekroczenie: więcej niż ograniczenie + tolerancja (pomiar GPS jest nieco niedokładny).
bool overLimit(double? speedKmh, int? limitKmh, {double toleranceKmh = 3}) =>
    speedKmh != null && limitKmh != null && speedKmh > limitKmh + toleranceKmh;

double _rad(double degrees) => degrees * math.pi / 180;

/// Wysokość słońca nad horyzontem w stopniach (przybliżenie NOAA, dokładność ok. 1°).
double sunElevation(DateTime time, LatLng place) {
  final d = time.toUtc().difference(DateTime.utc(2000, 1, 1, 12)).inSeconds / 86400.0;
  final g = _rad(357.529 + 0.98560028 * d);
  final q = 280.459 + 0.98564736 * d;
  final longitude = _rad(q + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g));
  final tilt = _rad(23.439 - 0.00000036 * d);
  final ascension = math.atan2(math.cos(tilt) * math.sin(longitude), math.cos(longitude));
  final declination = math.asin(math.sin(tilt) * math.sin(longitude));
  final sidereal = (18.697374558 + 24.06570982441908 * d) % 24;
  final hourAngle = _rad(sidereal * 15 + place.longitude) - ascension;
  final lat = _rad(place.latitude);
  final sine = math.sin(lat) * math.sin(declination) + math.cos(lat) * math.cos(declination) * math.cos(hourAngle);
  return math.asin(sine.clamp(-1.0, 1.0)) * 180 / math.pi;
}

/// Po zmroku (słońce niżej niż 3° pod horyzontem – zmierzch cywilny, jeszcze nie pełna noc).
bool isDark(DateTime time, LatLng place) => sunElevation(time, place) < -3;

/// Numer drogi na tarczy (A4, S7, DK94, E40, B96, D1…) – z tablicy albo z nazw ulicy.
String? roadRef(Maneuver m) {
  final pattern = RegExp(r'^(A|S|E|DK|DW|B|D|R|I|II)\s?-?\d{1,4}[a-z]?$', caseSensitive: false);
  for (final name in [...m.branch, ...m.streetNames]) {
    if (pattern.hasMatch(name.trim())) return name.trim().replaceAll(' ', '');
  }
  return null;
}

/// Nazwa ulicy / drogi do pokazania (bez numeru drogi, który jest na tarczy).
String? streetName(Maneuver m) {
  final ref = roadRef(m);
  for (final name in m.streetNames) {
    if (name.replaceAll(' ', '') != ref) return name;
  }
  return null;
}
