import 'dart:async';
import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/navigation/navigation_screen.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';
import 'package:truckmaps_app/src/planner/route.dart';

import 'corridor_test.dart' show routeLine, sideRoad;

class FakePositions implements PositionSource {
  final controller = StreamController<LatLng>.broadcast();

  @override
  Stream<LatLng> get positions => controller.stream;

  @override
  Future<void> dispose() => controller.close();
}

http.Response json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

final route = PlannedRoute.fromJson({
  'distance_km': 2.9,
  'duration_min': 4.0,
  'geometry': [[20.98, 50.0], [21.0, 50.0], [21.02, 50.0]],
  'analysis': {'level': 'green', 'segments': [{'start_index': 0, 'end_index': 2, 'level': 'green'}], 'warnings': []},
});

void main() {
  setUp(() => mapTiles = () => const SizedBox());

  testWidgets('na trasie spokój, na drodze nieprzejezdnej alarm, po zjeździe – nowa trasa', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      if (request.url.path == '/api/corridor') {
        return json({
          'route': routeLine,
          'items': [
            {'id': 1, 'level': 'red', 'kind': 'height', 'message': 'Ograniczenie wysokości 3,5 m (znak), pojazd 4 m', 'line': sideRoad},
          ],
        });
      }
      return json({
        'distance_km': 3.1,
        'duration_min': 5.0,
        'geometry': [[21.01, 50.003], [21.02, 50.0]],
        'analysis': null,
      });
    });
    final positions = FakePositions();
    await tester.pumpWidget(MaterialApp(
      home: NavigationScreen(
        api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
        request: NavigationRequest(vehicleId: 'v1', route: route, destination: const LatLng(50, 21.02)),
        source: positions,
        alarmSound: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));

    positions.controller.add(const LatLng(50.0001, 20.99));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Na trasie – zostało'), findsOneWidget);

    positions.controller.add(const LatLng(50.002, 21.0));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('STOP – ta droga jest nieprzejezdna'), findsOneWidget);
    expect(find.text('Ograniczenie wysokości 3,5 m (znak), pojazd 4 m'), findsWidgets);

    // Zjazd w inną drogę (nie czerwoną): po kilku pozycjach poza trasą – przeliczenie.
    for (var i = 0; i < offRouteFixes; i++) {
      positions.controller.add(LatLng(50.003, 21.01 + i * 0.0001));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('STOP – ta droga jest nieprzejezdna'), findsNothing);
    expect(requests.where((p) => p == '/api/routes').length, 1);
    expect(find.text('Trasa przeliczona od twojej pozycji.'), findsOneWidget);
    expect(requests.where((p) => p == '/api/corridor').length, 2);

    await tester.pumpWidget(const SizedBox());
  });

  test('pozycja w symulacji jazdy po trasie', () {
    final line = [const LatLng(50, 20.98), const LatLng(50, 21.0)];
    expect(pointAlong(line, 0), const LatLng(50, 20.98));
    expect(pointAlong(line, 1e6), isNull);
  });
}
