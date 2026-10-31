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
        if (request.method == 'PUT' && request.url.path.endsWith('/trailer')) {
          final id = request.url.pathSegments[2];
          final trailerId = body!['trailer_id'];
          vehicles = [
            for (final v in vehicles)
              if (v['id'] == id)
                {...v, 'trailer_id': trailerId}
              else if (v['id'] == trailerId)
                {...v, 'in_use': true, 'coupled_to_id': id}
              else
                v
          ];
          return json(vehicles.firstWhere((v) => v['id'] == id));
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
    // Nowy pojazd zaczyna jako ciągnik z typowymi wartościami (2 osie, DMC 18 t).
    expect((sent['name'], sent['plate'], sent['height_m'], sent['axle_count'], sent['kind'], sent['gvw_t']),
        ('Solówka 12 t', 'kr 1abc', 3.6, 2, 'tractor', 18.0));
    expect((sent['trailer_type'], sent['pallet_places'], sent['cost_currency']), ('curtain', null, 'EUR'));
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

  testWidgets('naczepa cysterna z pojemnością; „Podepnij” – zajęte na czerwono, nie do wybrania', (tester) async {
    vehicles = [
      {...truck, 'id': 't1', 'name': 'MAN TGX', 'plate': null, 'kind': 'tractor', 'trailer_type': 'none'},
      {...truck, 'id': 'n0', 'name': 'Chłodnia', 'plate': null, 'kind': 'semitrailer', 'trailer_type': 'reefer',
        'in_use': true, 'coupled_to_id': 'x', 'coupled_to_name': 'Volvo FH'},
      {...truck, 'id': 'p1', 'name': 'Przyczepa', 'plate': null, 'kind': 'trailer', 'trailer_type': 'box'},
    ];
    await pump(tester);
    expect(find.text('Samochody'), findsOneWidget);
    expect(find.text('Naczepy i przyczepy'), findsOneWidget);
    expect(find.textContaining('podpięta do: Volvo FH'), findsOneWidget);

    await tester.tap(find.text('Dodaj pojazd'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Rodzaj'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naczepa').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Zabudowa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cysterna').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Nazwa'), 'Cysterna 32');
    await tester.enterText(find.widgetWithText(TextFormField, 'Pojemność cysterny'), '32');
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    final tank = requests.singleWhere((r) => r.$1 == 'POST').$3!;
    expect((tank['kind'], tank['trailer_type'], tank['tank_volume_m3']), ('semitrailer', 'tanker', 32.0));

    await tester.tap(find.text('Podepnij'));
    await tester.pumpAndSettle();
    expect(find.text('Podepnij do: MAN TGX'), findsOneWidget);
    expect(find.text('Przyczepa'), findsOneWidget); // tylko na liście w tle – w oknie same naczepy
    await tester.tap(find.text('Chłodnia').last);
    await tester.pumpAndSettle();
    expect(find.text('Podepnij do: MAN TGX'), findsOneWidget); // zajęta – nic się nie dzieje
    await tester.tap(find.text('Cysterna 32').last);
    await tester.pumpAndSettle();

    final put = requests.singleWhere((r) => r.$1 == 'PUT');
    expect(put.$2, '/api/vehicles/t1/trailer');
    expect(put.$3, {'trailer_id': 'v2'});
    expect(find.text('Podpięta: Cysterna 32'), findsOneWidget);
  });

  testWidgets('autobus wymaga miejsc siedzących', (tester) async {
    vehicles = [];
    await pump(tester);

    await tester.tap(find.text('Dodaj pojazd'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Rodzaj'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Autobus / bus (przewóz osób)').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Nazwa'), 'Setra');
    await tester.enterText(find.widgetWithText(TextFormField, 'Wysokość'), '3,7');
    await tester.enterText(find.widgetWithText(TextFormField, 'Miejsca siedzące'), '');
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.$1 == 'POST'), isEmpty);

    await tester.enterText(find.widgetWithText(TextFormField, 'Miejsca siedzące'), '49');
    await tester.enterText(find.widgetWithText(TextFormField, 'Miejsca stojące'), '10');
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    final bus = requests.singleWhere((r) => r.$1 == 'POST').$3!;
    expect((bus['kind'], bus['seats'], bus['standing_places']), ('bus', 49, 10));
    expect(find.textContaining('49 miejsc siedz. + 10 stoj.'), findsOneWidget);
  });

  testWidgets('formularz według rodzaju: ciągnik bez zabudowy, naczepa bez silnika i stawek', (tester) async {
    vehicles = [];
    await pump(tester);
    await tester.tap(find.text('Dodaj pojazd'));
    await tester.pumpAndSettle();

    // Ciągnik (domyślny): silnik, tachograf, stawki; bez zabudowy i palet.
    expect(find.text('Klasa emisji spalin'), findsOneWidget);
    expect(find.text('Legalizacja tachografu do'), findsOneWidget);
    expect(find.text('Za km'), findsOneWidget);
    expect(find.text('Zabudowa'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Miejsca paletowe (EUR)'), findsNothing);

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Rodzaj'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Naczepa').last);
    await tester.pumpAndSettle();
    expect(find.text('Klasa emisji spalin'), findsNothing);
    expect(find.text('Legalizacja tachografu do'), findsNothing);
    expect(find.text('Za km'), findsNothing);
    expect(find.widgetWithText(TextFormField, 'Miejsca paletowe (EUR)'), findsOneWidget);
    String value(String label) => tester.widget<TextFormField>(find.widgetWithText(TextFormField, label)).controller!.text;
    expect((value('Długość'), value('DMC'), value('Liczba osi')), ('13,6', '36', '3'));
  });

  testWidgets('mechanik: tylko terminy; ostrzeżenie o terminie na liście', (tester) async {
    final soon = DateTime.now().add(const Duration(days: 10));
    final iso = '${soon.year}-${soon.month.toString().padLeft(2, '0')}-${soon.day.toString().padLeft(2, '0')}';
    vehicles = [
      {...truck, 'kind': 'tractor', 'can_edit': false, 'can_service': true, 'inspection_until': iso},
    ];
    await pump(tester);
    expect(find.textContaining('Wkrótce – Przegląd techniczny ważny do'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    expect(find.text('Zmień'), findsNothing);
    expect(find.text('Terminy przeglądów'), findsOneWidget);
  });
}
