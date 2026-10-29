import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Korytarz danych dla telefonu (`POST /api/corridor`) i sprawdzanie pozycji bez sieci –
/// to samo co `truckmaps.core.corridor.check_position` na serwerze.
///
/// Na trasie alarmu nie ma (planowanie omija drogi nieprzejezdne). Poza trasą alarm daje
/// najbliższa droga czerwona dla pojazdu w promieniu [onRoadM].
const offRouteM = 40.0;
const onRoadM = 15.0;

/// Polilinia 1e-6 (format Valhalli) → punkty.
List<LatLng> decodePolyline6(String encoded) {
  final points = <LatLng>[];
  var index = 0, lat = 0, lon = 0;
  while (index < encoded.length) {
    final deltas = <int>[];
    for (var i = 0; i < 2; i++) {
      var shift = 0, result = 0, byte = 0;
      do {
        byte = encoded.codeUnitAt(index++) - 63;
        result |= (byte & 0x1F) << shift;
        shift += 5;
      } while (byte >= 0x20);
      deltas.add((result & 1) != 0 ? ~(result >> 1) : result >> 1);
    }
    lat += deltas[0];
    lon += deltas[1];
    points.add(LatLng(lat / 1e6, lon / 1e6));
  }
  return points;
}

/// Punkty → polilinia 1e-6.
String encodePolyline6(List<LatLng> points) {
  final out = StringBuffer();
  var lastLat = 0, lastLon = 0;
  for (final p in points) {
    final lat = (p.latitude * 1e6).round(), lon = (p.longitude * 1e6).round();
    for (var delta in [lat - lastLat, lon - lastLon]) {
      var value = delta < 0 ? ~(delta << 1) : delta << 1;
      while (value >= 0x20) {
        out.writeCharCode((0x20 | (value & 0x1F)) + 63);
        value >>= 5;
      }
      out.writeCharCode(value + 63);
    }
    lastLat = lat;
    lastLon = lon;
  }
  return out.toString();
}

double _rad(double degrees) => degrees * math.pi / 180;

/// Odległość w metrach (przybliżenie równoprostokątne, jak na serwerze).
double distanceM(LatLng a, LatLng b) {
  final x = _rad(b.longitude - a.longitude) * math.cos(_rad((a.latitude + b.latitude) / 2));
  final y = _rad(b.latitude - a.latitude);
  return 6371000 * math.sqrt(x * x + y * y);
}

/// Odległość punktu od odcinka a–b i miejsce na nim (ułamek 0–1).
(double, double) distanceToSegment(LatLng p, LatLng a, LatLng b) {
  final scale = math.cos(_rad(p.latitude));
  final px = (p.longitude - a.longitude) * scale, py = p.latitude - a.latitude;
  final dx = (b.longitude - a.longitude) * scale, dy = b.latitude - a.latitude;
  final length2 = dx * dx + dy * dy;
  final t = length2 == 0 ? 0.0 : ((px * dx + py * dy) / length2).clamp(0.0, 1.0);
  final nearest = LatLng(a.latitude + t * (b.latitude - a.latitude), a.longitude + t * (b.longitude - a.longitude));
  return (distanceM(p, nearest), t);
}

/// Najbliższe miejsce na linii: odległość, indeks odcinka i ułamek na nim.
(double, int, double) nearestOnLine(LatLng p, List<LatLng> line) {
  if (line.length == 1) return (distanceM(p, line.first), 0, 0);
  var best = (double.infinity, 0, 0.0);
  for (var i = 0; i < line.length - 1; i++) {
    final (distance, t) = distanceToSegment(p, line[i], line[i + 1]);
    if (distance < best.$1) best = (distance, i, t);
  }
  return best;
}

class CorridorItem {
  CorridorItem({required this.level, required this.kind, required this.message, required this.line, this.limit});

  factory CorridorItem.fromJson(Map<String, dynamic> json) => CorridorItem(
        level: json['level'] as String,
        kind: json['kind'] as String,
        message: json['message'] as String,
        limit: json['limit'] as String?,
        line: decodePolyline6(json['line'] as String),
      );

  final String level;
  final String kind;
  final String message;
  final String? limit;
  final List<LatLng> line;
}

class Corridor {
  Corridor({required this.route, required this.items});

  factory Corridor.fromJson(Map<String, dynamic> json) => Corridor(
        route: decodePolyline6(json['route'] as String),
        items: [for (final i in json['items'] as List<dynamic>) CorridorItem.fromJson(i as Map<String, dynamic>)],
      );

  final List<LatLng> route;
  final List<CorridorItem> items;

  late final List<CorridorItem> _red = items.where((i) => i.level == 'red').toList();

  PositionCheck check(LatLng position) {
    final (fromRoute, segment, t) = nearestOnLine(position, route);
    if (fromRoute <= offRouteM) {
      return PositionCheck(onRoute: true, distanceFromRouteM: fromRoute, alongM: _along(segment, t));
    }
    CorridorItem? alarm;
    var best = onRoadM;
    for (final item in _red) {
      final (distance, _, _) = nearestOnLine(position, item.line);
      if (distance <= best) {
        best = distance;
        alarm = item;
      }
    }
    return PositionCheck(onRoute: false, distanceFromRouteM: fromRoute, alarm: alarm);
  }

  late final List<double> _cumulative = () {
    final out = [0.0];
    for (var i = 1; i < route.length; i++) {
      out.add(out.last + distanceM(route[i - 1], route[i]));
    }
    return out;
  }();

  double get lengthM => _cumulative.last;

  double _along(int segment, double t) {
    if (route.length < 2) return 0;
    return _cumulative[segment] + t * (_cumulative[segment + 1] - _cumulative[segment]);
  }
}

class PositionCheck {
  const PositionCheck({required this.onRoute, required this.distanceFromRouteM, this.alarm, this.alongM});

  final bool onRoute;
  final double distanceFromRouteM;

  /// Droga nieprzejezdna dla pojazdu, na której jest pozycja (poza trasą).
  final CorridorItem? alarm;

  /// Ile metrów trasy już przejechano (gdy pozycja jest na trasie).
  final double? alongM;
}
