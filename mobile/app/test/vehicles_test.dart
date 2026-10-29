import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/vehicles_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const truck = {
  'id': 'v1',
  'name': 'Zestaw 40 t',
  'plate': 'KTA 12345',
  'height_m': 4.0,
  'width_m': 2.55,
  'length_m': 16.5,
  'weight_t': 40,
  'gvw_t': 40,
  'axle_load_t': 11.5,
  'axle_count': 5,
  'trailer_type': 'curtain',
  'hazmat': false,
  'cost_per_km': 1.2,
  'cost_per_hour': null,
  'cost_currency': 'EUR',
  'company_id': null,
  'can_edit': true,
};

void main() {
  late List<Map<String, dynamic>> vehicles;
  late List<(String, String, Map?)> requests;
  var changes = 0;

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        final body = request.body.isEmpty ? null : (jsonDecode(request.body) as Map).cast<String, dynamic>();
        requests.add((request.method, request.url.path, body));
        switch ((request.method, request.url.path)) {
          case ('GET', '/api/vehicles'):
            return json(vehicles);
          case ('GET', '/api/companies'):
            return json([]);
          case ('GET', '/api/currencies'):
            return json({
              'currencies': [{'code': 'PLN', 'name': 'złoty'}, {'code': 'EUR', 'name': 'euro'}],
              'rates_day': '2026-10-29',
              'per_eur': {'PLN': 4.25},
            });
          case ('POST', '/api/vehicles'):
            final saved = {...truck, ...body!, 'id': 'v2'};
            vehicles = [...vehicles, saved];
            return json(saved, 201);
          case ('PUT', '/api/vehicles/v1'):
            final saved = {...truck, ...body!};
            vehicles = [saved];
            return json(saved);
          case ('DELETE', '/api/vehicles/v1'):
            vehicles = [];
            return http.Response('', 204);
        }
        return json(null, 404);
      }),
    );
    await tester.pumpWidget(localized(VehiclesScreen(api: api, onChanged: () => changes++)));
    await tester.pumpAndSettle();
  }

  setUp(() {
    vehicles = [truck];
    requests = [];
    changes = 0;
  });

  testWidgets('dodanie pojazdu z tablicą; zły wymiar zatrzymuje zapis', (tester) async {
    vehicles = [];
    await pump(tester);

    await tester.tap(find.text('Dodaj pojazd'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Nazwa'), 'Solówka 12 t');
    await tester.enterText(find.widgetWithText(TextFormField, 'Tablica rejestracyjna'), 'kr 1abc');
    await tester.enterText(find.widgetWithText(TextFormField, 'Wysokość'), '9');
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    expect(find.text('Od 1,5 do 6.'), findsOneWidget);
    expect(requests.where((r) => r.$1 == 'POST'), isEmpty);

    await tester.enterText(find.widgetWithText(TextFormField, 'Wysokość'), '3,6');
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();

    final sent = requests.singleWhere((r) => r.$1 == 'POST').$3!;
    expect((sent['name'], sent['plate'], sent['height_m'], sent['axle_count']), ('Solówka 12 t', 'kr 1abc', 3.6, 5));
    expect(find.textContaining('Solówka 12 t'), findsOneWidget);
    expect(changes, 1);
  });

  testWidgets('zmiana waluty przelicza stawki, edycja zapisuje pojazd', (tester) async {
    await pump(tester);

    await tester.tap(find.text('Zestaw 40 t · KTA 12345'));
    await tester.pumpAndSettle();
    expect(find.text('Zmień pojazd'), findsOneWidget);
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Waluta'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLN').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();

    final sent = requests.singleWhere((r) => r.$1 == 'PUT').$3!;
    expect((sent['cost_currency'], sent['cost_per_km']), ('PLN', 5.1));
  });

  testWidgets('usunięcie pojazdu po potwierdzeniu', (tester) async {
    await pump(tester);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Usuń').last);
    await tester.pumpAndSettle();
    expect(find.text('Usunąć pojazd?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Usuń'));
    await tester.pumpAndSettle();

    expect(requests.any((r) => r.$1 == 'DELETE'), isTrue);
    expect(find.text('Brak pojazdów. Dodaj pierwszy przyciskiem „Dodaj pojazd”.'), findsOneWidget);
    expect(changes, 1);
  });
}
