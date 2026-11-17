import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_documents/module_documents.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';
import 'package:truckmaps_app/src/planner/route_actions.dart';
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
  tester.view.physicalSize = const Size(1600, 1300);
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
          return json([
            {'id': 'v1', 'name': 'MAN TGX', 'trailer_name': 'Firanka', 'gvw_t': 40, 'height_m': 4.0}
          ]);
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
    expect(find.text('MAN TGX + Firanka · 40 t · 4 m'), findsOneWidget); // pojazd w nagłówku trasy
    expect(find.text('Uwaga: trudne miejsca na trasie'), findsOneWidget);
    expect(find.textContaining('Ostry zakręt'), findsOneWidget);
    expect(find.textContaining('Przyjazd ok.'), findsOneWidget);
  });

  testWidgets('ograniczenie zgłoszone przez kierowców: znak „ominięto” i objazd', (tester) async {
    await pumpPlanner(tester, (request) async {
      switch (request.url.path) {
        case '/api/vehicles':
          return json([
            {'id': 'v1', 'name': 'MAN TGX', 'gvw_t': 40, 'height_m': 4.0}
          ]);
        case '/api/geocode/reverse':
          return json({'label': 'Tarnów', 'lat': 50.0, 'lon': 21.0});
        case '/api/routes':
          return json({
            ...route,
            'avoided_warnings': [
              {
                'level': 'orange',
                'kind': 'reported',
                'message': 'Ograniczenie masy rzeczywistej 3,5 t, pojazd 40 t – zgłoszenie innych kierowców',
                'km': 2.1,
                'lat': 50.0023,
                'lon': 20.9874,
                'limit': '3,5 t',
              },
            ],
          });
      }
      return json(null, 404);
    });

    await tapMapTwice(tester);

    expect(find.text('3,5 t'), findsOneWidget); // znak na mapie
    expect(find.text('ominięto'), findsOneWidget);
    expect(find.text('Ominięte – trasa jedzie objazdem'), findsOneWidget);
    expect(find.textContaining('zgłoszenie innych kierowców'), findsOneWidget);
  });

  testWidgets('trasa omija ograniczenie masy: pytanie o zezwolenie; pojazd firmy – „Wyślij kierowcy”',
      (tester) async {
    await pumpPlanner(tester, (request) async {
      switch (request.url.path) {
        case '/api/vehicles':
          return json([
            {'id': 'v1', 'name': 'MAN TGX', 'gvw_t': 40, 'height_m': 4.0, 'company_id': 'c1'}
          ]);
        case '/api/geocode/reverse':
          return json({'label': 'Tarnów', 'lat': 50.0, 'lon': 21.0});
        case '/api/routes':
          return json({
            ...route,
            'avoided_warnings': [
              {
                'level': 'red',
                'kind': 'weight',
                'message': 'Ograniczenie masy rzeczywistej 12 t, pojazd 40 t',
                'km': 2.1,
                'lat': 50.0023,
                'lon': 20.9874,
                'limit': '12 t',
              },
            ],
          });
      }
      return json(null, 404);
    });

    await tapMapTwice(tester);

    expect(find.text('Masz zezwolenie na przejazd?'), findsOneWidget);
    expect(find.text('• Ograniczenie masy rzeczywistej 12 t, pojazd 40 t'), findsOneWidget);
    await tester.tap(find.text('Nie'));
    await tester.pumpAndSettle();
    expect(find.text('Masz zezwolenie na przejazd?'), findsNothing);
    expect(find.byKey(const Key('planner-send-driver')), findsOneWidget);
  });

  testWidgets('akcja modułu przy trasie („Dokument”): przystanki z krajem i ETA, koszt, plan załadunku',
      (tester) async {
    RouteData? data;
    routeActions.value = [
      RouteAction(id: 'documents', label: (_) => 'Dokument', icon: Icons.description, run: (_, d) async => data = d),
    ];
    currentCargo.value = {
      'vehicle_id': 'v1',
      'items': [
        {'kind': 'euro', 'count': 10, 'weight_kg': 500.0, 'label': 'Paleta EUR'}
      ],
      'ldm': 4.0,
    };
    addTearDown(() {
      routeActions.value = const [];
      currentCargo.value = null;
    });
    Map<String, dynamic> country(String code, double km) =>
        {'country': code, 'name': code, 'km': km, 'lat': 50.0, 'lon': 21.0, 'bans': 'no_ban', 'enter_at': null};
    await pumpPlanner(tester, (request) async {
      switch (request.url.path) {
        case '/api/vehicles':
          return json([
            {'id': 'v1', 'name': 'MAN TGX', 'gvw_t': 40, 'height_m': 4.0, 'company_id': 'c1'}
          ]);
        case '/api/geocode/reverse':
          return json({'label': 'Tarnów', 'lat': 50.0, 'lon': 21.0});
        case '/api/routes':
          return json({
            ...route,
            'cost': {'amount': 120.5, 'currency': 'PLN'},
            'departure': '2026-10-29T18:00:00+01:00',
            'countries': [country('PL', 0), country('SK', 10)],
          });
      }
      return json(null, 404);
    });

    await tapMapTwice(tester);
    await tester.tap(find.byKey(const Key('route-action-documents')));
    await tester.pump();

    expect(data?['company_id'], 'c1');
    expect(data?['vehicle_id'], 'v1');
    final sent = data!['route'] as Map<String, dynamic>;
    final stops = (sent['stops'] as List).cast<Map<String, dynamic>>();
    expect([for (final s in stops) (s['label'], s['country'], s['type'])],
        [('Tarnów', 'PL', 'loading'), ('Tarnów', 'SK', 'unloading')]);
    expect(DateTime.parse(stops.first['at'] as String), DateTime.parse('2026-10-29T17:00:00Z'));
    expect(DateTime.parse(stops.last['at'] as String), DateTime.parse('2026-10-29T17:31:00Z')); // przyjazd
    expect(sent['distance_km'], 22.4);
    expect(sent['duration_min'], 31.0);
    expect((sent['cost_amount'], sent['cost_currency']), (120.5, 'PLN'));
    expect(data?['cargo'], {
      'items': [
        {'kind': 'euro', 'count': 10, 'weight_kg': 500.0, 'label': 'Paleta EUR'}
      ],
      'ldm': 4.0,
    });
  });

  test('akcje trasy tylko z aktywnych modułów', () async {
    addTearDown(() => routeActions.value = const []);
    var granted = true;
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async => json([
            {'id': 'documents', 'name': 'Dokumenty', 'granted': granted}
          ])),
    );
    final registry = ModuleRegistry([DocumentsModule()]);
    await loadRouteActions(api, registry);
    expect([for (final a in routeActions.value) a.id], ['documents']);
    granted = false;
    await loadRouteActions(api, registry);
    expect(routeActions.value, isEmpty);
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
