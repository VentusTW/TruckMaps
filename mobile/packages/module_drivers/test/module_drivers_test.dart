import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_drivers/module_drivers.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> driver({List<Map<String, dynamic>> vehicles = const []}) => {
      'id': 'd1',
      'company_id': 'c1',
      'name': 'Jan Kowalski',
      'phone': '+48 600 100 200',
      'email': null,
      'hired_on': '2024-03-01',
      'notes': null,
      'has_account': true,
      'member_id': 'm1',
      'member_name': 'Jan',
      'license_categories': ['C'],
      'license_until': null,
      'code95_until': '2026-11-20',
      'medical_until': null,
      'psych_until': null,
      'card_until': null,
      'card_downloaded_on': null,
      'card_download_until': null,
      'adr_until': null,
      'adr_tank': false,
      'attestation_until': null,
      'vehicles': vehicles,
      'dues': [
        {'field': 'code95_until', 'day': '2026-11-20', 'state': 'soon'}
      ],
      'can_edit': true,
      'updated_at': '2026-11-05T08:00:00Z',
    };

void main() {
  late List<(String, String, Object?)> requests;
  late Map<String, dynamic> current;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          final path = request.url.path;
          requests.add((request.method, path, body));
          if (path == '/api/companies') {
            return json([
              {'id': 'c1', 'name': 'Trans-Miś', 'role': 'owner'}
            ]);
          }
          if (path == '/api/m/drivers/drivers' && request.method == 'GET') return json([current]);
          if (path == '/api/m/drivers/drivers') return json(current = {...driver(), 'name': (body as Map)['name']}, 201);
          if (path == '/api/m/drivers/candidates') {
            return json([
              {'member_id': 'm1', 'name': 'Jan', 'role': 'driver'}
            ]);
          }
          if (path == '/api/m/drivers/drivers/d1') return json(current);
          if (path == '/api/vehicles') {
            return json([
              {'id': 'v1', 'name': 'MAN TGX', 'plate': 'KTA 1', 'kind': 'tractor', 'company_id': 'c1'},
              {'id': 'v2', 'name': 'Krone', 'plate': null, 'kind': 'semitrailer', 'company_id': 'c1'},
            ]);
          }
          if (path.endsWith('/check')) {
            return json({
              'required_category': 'CE',
              'warnings': ['brak kategorii CE (ma: C).']
            });
          }
          if (path.endsWith('/assign')) {
            current = driver(vehicles: [
              {'vehicle_id': 'v1', 'name': 'MAN TGX', 'plate': 'KTA 1', 'since': '2026-11-05T08:00:00Z'}
            ]);
            return json({'driver': current, 'warnings': <String>[]});
          }
          if (path.endsWith('/stats')) {
            return json({
              'driver_id': 'd1',
              'trips': 2,
              'distance_km': 420.0,
              'hours': 8.0,
              'empty_km': 120.0,
              'idle_hours': 1.0,
              'vehicles': 1,
              'costs': <String, dynamic>{},
              'months': [
                {'month': '2026-11', 'trips': 2, 'distance_km': 420.0, 'hours': 8.0, 'empty_km': 120.0, 'idle_hours': 1.0}
              ],
              'by_vehicle': [
                {'vehicle_id': 'v1', 'name': 'MAN TGX', 'trips': 2, 'distance_km': 420.0}
              ],
              'recent': <Object>[],
            });
          }
          if (path.endsWith('/assignments')) return json(<Object>[]);
          if (path.endsWith('/history')) {
            return json([
              {
                'id': 'h1',
                'at': '2026-11-05T08:00:00Z',
                'by_name': 'Olek',
                'action': 'updated',
                'changes': {
                  'phone': ['1', '2']
                },
              }
            ]);
          }
          return json({'detail': 'nie ma'}, 404);
        }),
      );

  setUp(() {
    requests = [];
    current = driver();
  });

  // Domyślny język MaterialApp w testach – angielski.
  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  // Wysoki ekran – cały formularz i karta bez przewijania.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('lista kierowców z terminami i dodanie kierowcy', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(DriversScreen(api: api())));
    await tester.pumpAndSettle();
    expect(find.text('Jan Kowalski'), findsOneWidget);
    expect(find.textContaining('soon: 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drivers-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('driver-name')), 'Piotr Nowak');
    await tester.tap(find.byKey(const Key('driver-category-CE')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('driver-save')));
    await tester.pumpAndSettle();
    final post = requests.firstWhere((r) => r.$1 == 'POST');
    expect((post.$3 as Map)['company_id'], 'c1');
    expect((post.$3 as Map)['license_categories'], ['CE']);
    expect((post.$3 as Map)['member_id'], isNull);
  });

  testWidgets('przydział pojazdu z ostrzeżeniem, przejazdy i historia', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(DriverScreen(api: api(), driverId: 'd1')));
    await tester.pumpAndSettle();
    expect(find.text('soon'), findsOneWidget);

    await tester.tap(find.byKey(const Key('driver-assign')));
    await tester.pumpAndSettle();
    expect(find.text('Krone'), findsNothing); // naczepa bez kierowcy
    await tester.tap(find.text('MAN TGX'));
    await tester.pumpAndSettle();
    expect(find.text('Required category: CE'), findsOneWidget);
    await tester.tap(find.text('Assign anyway'));
    await tester.pumpAndSettle();
    expect(requests.any((r) => r.$2.endsWith('/assign')), isTrue);
    expect(find.text('MAN TGX · KTA 1'), findsOneWidget);

    await tester.tap(find.text('Trips'));
    await tester.pumpAndSettle();
    expect(find.text('2026-11'), findsOneWidget);
    await tester.tap(find.text('History'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Phone: 1 → 2'), findsOneWidget);
  });

  test('teksty po angielsku', () {
    final t = DriversTexts(const Locale('en'));
    expect(t.menu, 'Drivers');
    expect(t.field('code95_until'), startsWith('Code 95'));
    expect(DriversModule().name(const Locale('pl')), 'Kierowcy');
  });
}
