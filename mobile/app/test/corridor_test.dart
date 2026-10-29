import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/navigation/corridor.dart';

// Te same dane co na serwerze (truckmaps.core.polyline / corridor.check_position).
const routeLine = '_gwj~A_qo_g@?_af@?_af@';
const sideRoad = '_gwj~A_sv`g@_yF?';

void main() {
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
}
