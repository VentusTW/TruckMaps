import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';
import 'package:truckmaps_app/src/planner/restriction_signs.dart';
import 'package:truckmaps_app/src/planner/vector_tiles.dart';

void main() {
  test('bez kafelków na serwerze albo bez serwera zostaje mapa obrazkowa', () async {
    Widget raster() => const SizedBox();
    mapTiles = raster;
    final empty = MockClient((request) async {
      expect(request.url.path, '/api/tiles');
      return http.Response('[]', 200);
    });
    final down = MockClient((request) async => throw http.ClientException('brak sieci'));

    expect(await useVectorMap('http://serwer.test', client: empty), isFalse);
    expect(await useVectorMap('http://serwer.test', client: down), isFalse);
    expect(mapTiles, same(raster));
  });

  test('znaki ograniczeń: tony i metry jak na znaku', () {
    expect(const RestrictionSign('weight', 12, LatLng(50, 20)).label, '12t');
    expect(const RestrictionSign('axle_load', 11.5, LatLng(50, 20)).label, '11,5t');
    expect(const RestrictionSign('height', 3.5, LatLng(50, 20)).label, '3,5m');
  });
}
