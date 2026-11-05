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

// Najmniejszy PNG 1×1 – do miniatury zdjęcia.
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

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
            return json(current = {
              ...order('done'),
              'work_done': (body as Map)['work_done'],
              'parts': body['parts'],
              'inspection_until': body['inspection_until'],
            });
          }
          if (path.endsWith('/photos')) {
            return json(
                current = {
                  ...current,
                  'photos': [
                    {'id': 'p1', 'stage': (body as Map)['stage'], 'created_at': '2026-11-01T08:00:00Z'}
                  ],
                },
                201);
          }
          if (path == '/api/m/service/photos/p1') return json({'content_type': 'image/png', 'image': png});
          if (path.endsWith('/protocol')) return json({'html': '<h1>Protokół</h1>', 'filename': '2026-11-01-KTA'});
          if (path.endsWith('/protocol/link')) return json({'path': '/api/shared/klucz', 'filename': '2026-11-01-KTA'});
          if (path == '/api/m/service/costs') {
            return json([
              {
                'vehicle_id': 'v1',
                'vehicle_name': 'MAN TGX',
                'vehicle_plate': 'KTA 12345',
                'currency': 'PLN',
                'orders': 2,
                'parts_total': 1900.5,
                'labour_hours': 3.5,
              }
            ]);
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
    await tester.ensureVisible(find.text('Roadworthiness test done'));
    await tester.tap(find.text('Roadworthiness test done'));
    await tester.pumpAndSettle();
    expect(find.text('Test valid until'), findsOneWidget);
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    final protocol = requests.singleWhere((r) => r.$2.endsWith('/complete')).$3 as Map;
    expect(protocol['work_done'], 'Wymiana uszczelki');
    expect(protocol['parts'], [
      {'name': 'Uszczelka', 'quantity': 1.0, 'price': 120.5}
    ]);
    expect(protocol['labour_hours'], 2.5);
    final until = DateTime.parse(protocol['inspection_until'] as String);
    expect(until.difference(DateUtils.dateOnly(DateTime.now())).inDays, 365); // domyślnie rok
    expect(find.textContaining('Roadworthiness test valid until'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Repair protocol'), findsOneWidget);
  });

  testWidgets('kierowca nie prowadzi zlecenia', (tester) async {
    await pump(tester, OrderScreen(api: api(), order: order('new', handle: false)));
    expect(find.text('Accept'), findsNothing);
    expect(find.text('Vehicle is off the road'), findsOneWidget);
  });

  testWidgets('zdjęcie usterki, protokół do druku i koszty napraw', (tester) async {
    final opened = <String>[];
    await pump(
      tester,
      OrderScreen(
        api: api(),
        order: order('new', handle: false),
        photoPicker: () async => base64Decode(png),
        htmlOpener: (html, name) async {
          opened.add('$name:$html');
          return true;
        },
      ),
    );
    await tester.tap(find.text('Add photo'));
    await tester.pumpAndSettle();
    final sent = requests.singleWhere((r) => r.$2.endsWith('/photos')).$3 as Map;
    expect((sent['stage'], sent['image']), ('report', png));
    expect(find.byType(Image), findsOneWidget);

    await pump(
        tester,
        OrderScreen(
            key: const ValueKey('done'),
            api: api(),
            order: order('done'),
            byLink: false, // komputer: plik HTML w przeglądarce
            htmlOpener: (html, name) async {
              opened.add('$name:$html');
              return true;
            }));
    await tester.tap(find.text('Printable protocol / PDF'));
    await tester.pumpAndSettle();
    expect(opened, ['2026-11-01-KTA:<h1>Protokół</h1>']);

    // Telefon: protokół przez krótki link otwierany w przeglądarce systemu.
    await pump(
        tester,
        OrderScreen(
            key: const ValueKey('phone'),
            api: api(),
            order: order('done'),
            byLink: true,
            linkOpener: (link) async {
              opened.add('$link');
              return true;
            }));
    await tester.tap(find.text('Printable protocol / PDF'));
    await tester.pumpAndSettle();
    expect(opened.last, 'http://serwer.test/api/shared/klucz');

    await pump(tester, CostsScreen(api: api()));
    expect(find.text('MAN TGX · KTA 12345'), findsOneWidget);
    expect(find.text('Repairs: 2 · parts: 1,900.50 PLN · labour: 3.5 h'), findsOneWidget);
  });
}
