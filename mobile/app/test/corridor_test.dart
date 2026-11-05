import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/navigation/corridor.dart';
import 'package:truckmaps_app/src/navigation/navigation_screen.dart' show pointAlong;

// Te same dane co na serwerze (truckmaps.core.polyline / corridor.check_position).
const routeLine = '_gwj~A_qo_g@?_af@?_af@';
const sideRoad = '_gwj~A_sv`g@_yF?';

void main() {
  test('najbliższy odcinek linii – ten sam co przy liczeniu odległości do każdego odcinka', () {
    final random = math.Random(7);
    final line = [for (var i = 0; i < 300; i++) LatLng(50 + random.nextDouble() * 0.2, 20 + random.nextDouble() * 0.3)];
    for (var k = 0; k < 200; k++) {
      final p = LatLng(50 + random.nextDouble() * 0.2, 20 + random.nextDouble() * 0.3);
      var best = double.infinity;
      for (var i = 0; i < line.length - 1; i++) {
        best = math.min(best, distanceToSegment(p, line[i], line[i + 1]).$1);
      }
      expect(nearestOnLine(p, line).$1, closeTo(best, 0.5));
    }
  });


  test('polilinia 1e-6 zgodna z serwerem', () {
    final points = decodePolyline6(routeLine);
    expect(points, [const LatLng(50, 20.98), const LatLng(50, 21), const LatLng(50, 21.02)]);
    expect(encodePolyline6(points), routeLine);
  });

  test('sprawdzanie pozycji jak na serwerze', () {
    final corridor = Corridor.fromJson({
      'route': routeLine,
      'items': [
        {'id': 1, 'level': 'red', 'kind': 'height', 'message': 'Ograniczenie wysokości 3,5 m', 'line': sideRoad},
        {'id': 2, 'level': 'orange', 'kind': 'narrow', 'message': 'Wąsko', 'line': sideRoad},
      ],
    });

    final onRoute = corridor.check(const LatLng(50.0001, 21.01));
    expect(onRoute.onRoute, isTrue);
    expect(onRoute.alongM, closeTo(2143, 5));

    final onRedRoad = corridor.check(const LatLng(50.002, 21.0));
    expect((onRedRoad.onRoute, onRedRoad.alarm?.message), (false, 'Ograniczenie wysokości 3,5 m'));

    final elsewhere = corridor.check(const LatLng(50.003, 21.01));
    expect((elsewhere.onRoute, elsewhere.alarm), (false, null));
  });

  test('punkt na trasie po metrach – ten sam co przy przejściu całej linii', () {
    final route = [for (var i = 0; i < 300; i++) LatLng(52.4 - i * 0.0004 * math.sin(i / 7), 16.9 + i * 0.0008)];
    final corridor = Corridor(route: [...route, route.last], items: const []);
    for (var along = 0.0; along <= corridor.lengthM; along += 37.3) {
      final a = corridor.pointAt(along)!, b = pointAlong(route, along)!;
      expect(distanceM(a, b), lessThan(0.001));
    }
    expect(corridor.pointAt(corridor.lengthM + 1), isNull);
  });
}
