import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_service/module_service.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> order(String status, {bool handle = true}) => {
      'id': 'o1',
      'vehicle_id': 'v1',
      'vehicle_name': 'MAN TGX',
      'vehicle_plate': 'KTA 12345',
      'company_id': 'c1',
      'reporter_name': 'Jan',
      'description': 'Wycieka olej',
      'urgency': 'stopped',
      'status': status,
      'mechanic_name': status == 'new' ? null : 'Marek',
      'work_done': null,
      'parts': <Object>[],
      'labour_hours': null,
      'odometer_km': null,
      'notes': null,
      'reject_reason': null,
      'created_at': '2026-10-31T08:00:00Z',
      'updated_at': '2026-10-31T08:00:00Z',
      'completed_at': null,
      'can_handle': handle,
    };

void main() {
  late List<(String, String, Object?)> requests;
  late Map<String, dynamic> current;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          requests.add((request.method, request.url.path, body));
          final path = request.url.path;
          if (path == '/api/vehicles') {
            return json([
              {'id': 'v1', 'name': 'MAN TGX', 'plate': 'KTA 12345'}
            ]);
          }
          if (path == '/api/m/service/orders' && request.method == 'GET') return json([current]);
          if (path == '/api/m/service/orders') return json(order('new'), 201);
          if (path.endsWith('/accept')) return json(current = order('accepted'));
          if (path.endsWith('/complete')) {
            return json(current = {...order('done'), 'work_done': (body as Map)['work_done'], 'parts': body['parts']});
          }
          return json(null, 404);
        }),
      );

  setUp(() {
    requests = [];
    current = order('new');
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // Pakiet nie ma tłumaczeń Materiala – testy ekranów po angielsku (polskie teksty sprawdza test nazwy).
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
    await tester.pumpAndSettle();
  }

  testWidgets('moduł: nazwa w języku i ekran Serwis w menu', (tester) async {
    final module = ServiceModule();
    expect(module.name(const Locale('en')), 'Service');
    final entries = module.entries(ModuleContext(api: api(), userName: 'Anna'));
    expect(entries.single.title, 'Serwis');
    expect(ServiceTexts(const Locale('pl')).status('in_progress'), 'W naprawie');
  });

  testWidgets('zgłoszenie usterki: pojazd stoi', (tester) async {
    await pump(tester, ReportScreen(api: api()));

    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a vehicle.'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MAN TGX · KTA 12345').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Wycieka olej');
    await tester.tap(find.text('Vehicle is off the road'));
    await tester.tap(find.text('Send'));
    await tester.pumpAndSettle();

    final sent = requests.singleWhere((r) => r.$1 == 'POST');
    expect(sent.$3, {'vehicle_id': 'v1', 'description': 'Wycieka olej', 'urgency': 'stopped'});
  });

  testWidgets('mechanik: przyjęcie i zamknięcie protokołem z częścią', (tester) async {
    await pump(tester, ServiceScreen(api: api()));
    await tester.tap(find.text('MAN TGX · KTA 12345'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(find.text('Mechanic: Marek'), findsOneWidget);

    await tester.tap(find.text('Close with protocol'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Work done'), 'Wymiana uszczelki');
    await tester.tap(find.text('Add part'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Name'), 'Uszczelka');
    await tester.enterText(find.widgetWithText(TextFormField, 'Price'), '120,5');
    await tester.enterText(find.widgetWithText(TextFormField, 'Labour'), '2,5');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final protocol = requests.singleWhere((r) => r.$2.endsWith('/complete')).$3 as Map;
    expect(protocol['work_done'], 'Wymiana uszczelki');
    expect(protocol['parts'], [
      {'name': 'Uszczelka', 'quantity': 1.0, 'price': 120.5}
    ]);
    expect(protocol['labour_hours'], 2.5);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Repair protocol'), findsOneWidget);
  });

  testWidgets('kierowca nie prowadzi zlecenia', (tester) async {
    await pump(tester, OrderScreen(api: api(), order: order('new', handle: false)));
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Vehicle is off the road'), findsOneWidget);
  });
}
