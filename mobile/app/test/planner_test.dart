import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';
import 'localized.dart';

http.Response json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const route = {
  'distance_km': 22.4,
  'duration_min': 31.0,
  'geometry': [[20.98, 50.0], [21.0, 49.95], [21.05, 49.9]],
  'analysis': {
    'level': 'yellow',
    'segments': [{'start_index': 0, 'end_index': 2, 'level': 'yellow'}],
    'warnings': [
      {'level': 'yellow', 'message': 'Ostry zakręt – promień ok. 14 m', 'km': 16.7, 'lat': 49.95, 'lon': 21.0},
    ],
  },
  'cost': null,
  'alternatives': [],
  'stop_issues': [],
  'time_bans': {'bans': [], 'arrival': '2026-10-29T18:31:00+01:00', 'wait_min': 0, 'free_departure': null},
};

Future<void> pumpPlanner(WidgetTester tester, Future<http.Response> Function(http.Request) handler) async {
  tester.view.physicalSize = const Size(1600, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = CoreApi(baseUrl: 'http://serwer.test', token: 't', client: MockClient(handler));
  await tester.pumpWidget(localized(Scaffold(body: PlannerScreen(api: api))));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> tapMapTwice(WidgetTester tester) async {
  await tester.tapAt(const Offset(900, 400));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tapAt(const Offset(1100, 600));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUp(() => mapTiles = () => const SizedBox());
  dragTests();

  testWidgets('dwa dotknięcia mapy: start i cel → trasa z oceną', (tester) async {
    Map<String, dynamic>? sent;
    await pumpPlanner(tester, (request) async {
      switch (request.url.path) {
        case '/api/vehicles':
          return json([{'id': 'v1', 'name': 'Zestaw 40 t'}]);
        case '/api/geocode/reverse':
          return json({'label': 'Tarnów, Rynek', 'lat': 50.0, 'lon': 21.0});
        case '/api/routes':
          sent = jsonDecode(request.body) as Map<String, dynamic>;
          return json(route);
      }
      return json(null, 404);
    });

    await tapMapTwice(tester);

    expect(sent?['vehicle_id'], 'v1');
    expect(sent?['avoid_difficult'], isTrue);
    expect(find.text('22 km · 0 h 31 min'), findsOneWidget);
    expect(find.text('Uwaga: trudne miejsca na trasie'), findsOneWidget);
    expect(find.textContaining('Ostry zakręt'), findsOneWidget);
    expect(find.textContaining('Przyjazd ok.'), findsOneWidget);
  });

  testWidgets('brak trasy – okno z wyjaśnieniem serwera', (tester) async {
    await pumpPlanner(tester, (request) async {
      switch (request.url.path) {
        case '/api/vehicles':
          return json([{'id': 'v1', 'name': 'Zestaw 40 t'}]);
        case '/api/geocode/reverse':
          return json(null);
        case '/api/routes':
          return json({'detail': 'Brak trasy dla tego pojazdu: nacisk osi 10 t.'}, 422);
      }
      return json(null, 404);
    });

    await tapMapTwice(tester);

    expect(find.text('Nie da się wyznaczyć trasy'), findsOneWidget);
    expect(find.text('Brak trasy dla tego pojazdu: nacisk osi 10 t.'), findsOneWidget);
  });
}

void dragTests() {
  testWidgets('przeciągnięcie punktu A przesuwa start i liczy trasę od nowa', (tester) async {
    final origins = <Map>[];
    await pumpPlanner(tester, (request) async {
      switch (request.url.path) {
        case '/api/vehicles':
          return json([{'id': 'v1', 'name': 'Zestaw 40 t'}]);
        case '/api/geocode/reverse':
          return json({'label': 'Punkt ${request.url.queryParameters['lon']}', 'lat': 50.0, 'lon': 21.0});
        case '/api/routes':
          final body = jsonDecode(request.body) as Map;
          origins.add(body['origin'] as Map);
          // Trasa przez wybrane punkty – po dopasowaniu widoku A i B zostają na ekranie.
          final ends = [for (final p in [body['origin'], body['destination']]) [p['lon'], p['lat']]];
          return json({...route, 'geometry': ends, 'analysis': null});
      }
      return json(null, 404);
    });
    await tapMapTwice(tester);
    expect(origins, hasLength(1));

    await tester.drag(find.text('A'), const Offset(-120, 0));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(origins, hasLength(2));
    expect((origins.last['lon'] as num) < (origins.first['lon'] as num), isTrue);
  });
}
