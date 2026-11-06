import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/vehicles/service_dates.dart';
import 'package:truckmaps_app/src/vehicles/vehicle_form.dart';
import 'package:truckmaps_app/src/vehicles/vehicle_state.dart';
import 'package:truckmaps_app/src/vehicles/vehicles_table.dart';
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

class MemoryViewStore implements VehiclesViewStore {
  MemoryViewStore([this.table = false]);

  bool table;

  @override
  Future<bool> readTable() async => table;

  @override
  Future<void> writeTable(bool table) async => this.table = table;
}

void main() {
  late List<Map<String, dynamic>> vehicles;
  var bases = <Map<String, dynamic>>[];
  var companies = <Map<String, dynamic>>[];
  late List<(String, String, Map?)> requests;
  var changes = 0;
  late ValueNotifier<int> shown;

  Future<void> pump(WidgetTester tester, {VehiclesViewStore? store, Size size = const Size(1200, 2600)}) async {
    tester.view.physicalSize = size;
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
          case ('GET', '/api/bases'):
            return json(bases);
          case ('GET', '/api/companies'):
            return json(companies);
          case ('GET', '/api/currencies'):
            return json({
              'currencies': [
                {'code': 'PLN', 'name': 'złoty'},
                {'code': 'EUR', 'name': 'euro'}
              ],
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
          case ('POST', '/api/vehicles/registration'):
            return body!.containsKey('image') || body['code'] == 'KOD'
                ? json({
                    'name': 'MAN TGX',
                    'plate': 'WGM12345',
                    'vin': 'WMA06XZZ1KM123456',
                    'kind': 'tractor',
                    'gvw_t': 18.5,
                    'tare_t': 8.1,
                    'axle_count': 2,
                  })
                : json({'detail': 'Nie udało się odczytać kodu z dowodu rejestracyjnego.'}, 422);
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
    await tester.pumpWidget(localized(
        VehiclesScreen(api: api, onChanged: () => changes++, refresh: shown, viewStore: store ?? MemoryViewStore())));
    await tester.pumpAndSettle();
  }

  setUp(() {
    shown = ValueNotifier(0);
    vehicles = [truck];
    bases = [];
    companies = [];
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

    // Kliknięcie w kafelek – karta pojazdu; „Zmień” na karcie – formularz.
    await tester.tap(find.text('Zestaw 40 t · KTA 12345'));
    await tester.pumpAndSettle();
    expect(find.text('Terminy i przeglądy'), findsOneWidget);
    await tester.tap(find.byTooltip('Zmień'));
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

  testWidgets('pojazd prywatny: wybór bazy przypisuje go do firmy bazy', (tester) async {
    companies = [
      {'id': 'c1', 'name': 'TransportUE', 'role': 'owner', 'kind': 'carrier'},
    ];
    bases = [
      {'id': 'b1', 'name': 'Tarnów', 'company_id': 'c1', 'company_name': 'TransportUE'},
    ];
    await pump(tester);
    await tester.tap(find.text('Zestaw 40 t · KTA 12345'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Zmień'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('vehicle-base')));
    await tester.tap(find.byKey(const Key('vehicle-base')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Tarnów').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();

    final sent = requests.singleWhere((r) => r.$1 == 'PUT').$3!;
    expect((sent['company_id'], sent['base_id']), ('c1', 'b1'));
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
      {
        ...truck,
        'id': 'n0',
        'name': 'Chłodnia',
        'plate': null,
        'kind': 'semitrailer',
        'trailer_type': 'reefer',
        'in_use': true,
        'coupled_to_id': 'x',
        'coupled_to_name': 'Volvo FH'
      },
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

    // Jedna wolna pasująca naczepa – podpięcie jednym kliknięciem; inne – z okna wyboru.
    expect(find.text('Podepnij Cysterna 32'), findsOneWidget);
    await tester.tap(find.text('Inna…'));
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
    String value(String label) =>
        tester.widget<TextFormField>(find.widgetWithText(TextFormField, label)).controller!.text;
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

    // Terminy ciągnika: pobranie danych z tachografu jednym przyciskiem (+90 dni), bez ATP (to nie chłodnia).
    await tester.tap(find.text('Terminy przeglądów'));
    await tester.pumpAndSettle();
    expect(find.text('Świadectwo ATP chłodni do'), findsNothing);
    expect(find.text('Koniec leasingu'), findsOneWidget);
    await tester.tap(find.text('Pobrano dziś (+90 dni)'));
    await tester.pumpAndSettle();
    final due = DateUtils.dateOnly(DateTime.now()).add(const Duration(days: 90));
    expect(find.text(DateFormat.yMd('pl').format(due)), findsOneWidget);
  });

  testWidgets('widok tabeli: zakładki, sortowanie, szukanie; wybór zapamiętany', (tester) async {
    vehicles = [
      {...truck, 'kind': 'tractor', 'trailer_id': 't1'},
      {...truck, 'id': 'v2', 'name': 'Actros', 'plate': 'WE 777', 'kind': 'tractor', 'gvw_t': 18},
      {
        ...truck,
        'id': 't1',
        'name': 'Firanka',
        'plate': 'KTA 9N',
        'kind': 'semitrailer',
        'in_use': true,
        'coupled_to_id': 'v1',
        'coupled_to_name': 'Zestaw 40 t'
      },
    ];
    final store = MemoryViewStore();
    await pump(tester, store: store);
    await tester.tap(find.text('Tabela'));
    await tester.pumpAndSettle();
    expect(store.table, isTrue);
    expect(find.text('Samochody (2)'), findsOneWidget);
    expect(find.text('Naczepy i przyczepy (1)'), findsOneWidget);
    expect(find.text('DMC (t)'), findsOneWidget);
    expect(find.text('Firanka · KTA 9N'), findsOneWidget); // podpięta naczepa w wierszu ciągnika

    // Sortowanie po nazwie: najpierw rosnąco, po kliknięciu malejąco.
    double top(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(top('Actros'), lessThan(top('Zestaw 40 t')));
    await tester.tap(find.text('Nazwa'));
    await tester.pumpAndSettle();
    expect(top('Actros'), greaterThan(top('Zestaw 40 t')));

    await tester.enterText(find.byType(TextField), 'we777');
    await tester.pumpAndSettle();
    expect(find.text('Samochody (1)'), findsOneWidget);
    expect(find.text('Zestaw 40 t'), findsNothing);

    await tester.tap(find.text('Naczepy i przyczepy (0)'));
    await tester.pumpAndSettle();
    expect(find.text('Nic nie pasuje do wyszukiwania.'), findsOneWidget);
  });

  testWidgets('tabela z zapamiętanego wyboru; na telefonie mniej kolumn, naczepa w użyciu', (tester) async {
    vehicles = [
      {
        ...truck,
        'id': 't1',
        'name': 'Firanka',
        'kind': 'semitrailer',
        'in_use': true,
        'coupled_to_name': 'Zestaw 40 t'
      },
    ];
    await pump(tester, store: MemoryViewStore(true), size: const Size(400, 800));
    expect(find.text('Brak samochodów.'), findsOneWidget);
    await tester.tap(find.text('Naczepy i przyczepy (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Firanka'), findsOneWidget);
    expect(find.text('Tablica'), findsOneWidget);
    expect(find.text('DMC (t)'), findsNothing);

    await tester.tap(find.text('Firanka'));
    await tester.pumpAndSettle();
    await tester.dragUntilVisible(find.text('Pojazd ciągnący'), find.byType(ListView).last, const Offset(0, -200));
    expect(find.text('Pojazd ciągnący'), findsOneWidget); // karta pojazdu
    expect(find.text('w użyciu – podpięta do: Zestaw 40 t'), findsWidgets);
  });

  test('szukanie po tablicy bez spacji i najbliższy termin', () {
    expect(matchesVehicle(truck, 'kta12'), isTrue);
    expect(matchesVehicle(truck, 'zestaw'), isTrue);
    expect(matchesVehicle(truck, 'xyz'), isFalse);
    expect(nextServiceDate({'insurance_until': '2027-01-10', 'inspection_until': '2026-12-01'})?.day,
        DateTime(2026, 12, 1));
  });

  test('serwis według przebiegu: ostrzeżenie 2000 km wcześniej, ujemne po terminie', () {
    expect(serviceKmLeft({'odometer_km': 410000, 'service_due_km': 420000}), isNull);
    expect(serviceKmLeft({'odometer_km': 418500, 'service_due_km': 420000}), 1500);
    expect(serviceKmLeft({'odometer_km': 420300, 'service_due_km': 420000}), -300);
    expect(serviceKmLeft({'service_due_km': 420000}), isNull);
    expect(serviceDateApplies('ocp_until', kind: 'semitrailer', body: 'curtain', hazmat: false), isFalse);
    expect(serviceDateApplies('ocp_until', kind: 'tractor', body: 'none', hazmat: false), isTrue);
  });

  testWidgets('kolory stanu: niebieski podpięta, żółty zgłoszona usterka, czerwony w naprawie', (tester) async {
    vehicles = [
      {...truck, 'kind': 'tractor', 'repair_reported': true},
      {...truck, 'id': 'v2', 'name': 'Actros', 'kind': 'tractor', 'in_repair': true},
      {...truck, 'id': 't1', 'name': 'Firanka', 'kind': 'semitrailer', 'in_use': true, 'coupled_to_name': 'Actros'},
    ];
    await pump(tester);
    expect(find.text('w użyciu / podpięta'), findsOneWidget); // objaśnienie kolorów
    Color? cardColor(String name) =>
        tester.widget<Card>(find.ancestor(of: find.textContaining(name), matching: find.byType(Card)).first).color;
    final context = tester.element(find.byType(Card).first);
    expect(cardColor('Zestaw 40 t'), stateTint(context, VehicleState.reported));
    expect(cardColor('Actros'), stateTint(context, VehicleState.repair));
    expect(cardColor('Firanka'), stateTint(context, VehicleState.inUse));
    expect(stateTint(context, VehicleState.inUse), isNot(stateTint(context, VehicleState.repair)));
    expect(find.textContaining('zgłoszona usterka'), findsNWidgets(2)); // kafelek + objaśnienie
    expect(find.textContaining('podpięta do: Actros'), findsOneWidget);
  });

  testWidgets('dane z dowodu rejestracyjnego: zdjęcie albo tekst kodu wypełniają formularz', (tester) async {
    await pump(tester);
    await tester.tap(find.text('Dodaj pojazd'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wczytaj z dowodu rejestracyjnego'));
    await tester.pumpAndSettle();
    expect(find.text('Zrób zdjęcie kodu'), findsOneWidget); // testy działają jak Android
    await tester.tap(find.text('Wklej tekst kodu (skaner 2D)'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'KOD');
    await tester.tap(find.text('Wczytaj'));
    await tester.pumpAndSettle();
    expect(requests.last.$3, {'code': 'KOD'});
    expect(find.text('MAN TGX'), findsOneWidget);
    expect(find.text('WGM12345'), findsOneWidget);
    expect(find.text('WMA06XZZ1KM123456'), findsOneWidget);
    expect(find.text('18,5'), findsOneWidget);
    expect(find.textContaining('Sprawdź wysokość'), findsOneWidget);
  });

  testWidgets('filtr i sortowanie po bazie operacyjnej', (tester) async {
    vehicles = [
      {...truck, 'id': 'a', 'name': 'Zestaw Wesoła', 'base_id': 'b1', 'base_name': 'Wesoła'},
      {...truck, 'id': 'b', 'name': 'Auto Stryków', 'base_id': 'b2', 'base_name': 'Stryków'},
      {...truck, 'id': 'c', 'name': 'Bez przydziału'},
    ];
    // Nowa baza bez pojazdów też jest do wyboru.
    bases = [
      {'id': 'b1', 'name': 'Wesoła', 'code': 'PL-WAW-01', 'company_id': 'c1'},
      {'id': 'b2', 'name': 'Stryków', 'company_id': 'c1'},
      {'id': 'b3', 'name': 'Komorniki', 'company_id': 'c1'},
    ];
    await pump(tester);
    expect(find.textContaining('Zestaw Wesoła'), findsOneWidget);
    expect(find.textContaining('Auto Stryków'), findsOneWidget);

    expect(find.byKey(const Key('vehicles-base-b3')), findsOneWidget); // Komorniki – bez pojazdów
    await tester.tap(find.byKey(const Key('vehicles-base-b2')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Auto Stryków'), findsOneWidget);
    expect(find.textContaining('Zestaw Wesoła'), findsNothing);
    expect(find.textContaining('Bez przydziału'), findsNothing);

    await tester.tap(find.byKey(const Key('vehicles-base-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('vehicles-sort-base')));
    await tester.pumpAndSettle();
    // Stryków przed Wesołą, pojazd bez bazy na końcu.
    final y = [
      for (final n in ['Auto Stryków', 'Zestaw Wesoła', 'Bez przydziału']) tester.getTopLeft(find.textContaining(n)).dy
    ];
    expect(y[0] < y[1] && y[1] < y[2], isTrue);
  });

  testWidgets('komputer: liczby floty nad listą, „wymaga uwagi” obok', (tester) async {
    vehicles = [
      {...truck, 'in_repair': true}
    ];
    await pump(tester, size: const Size(1600, 1200));
    expect(find.text('W UŻYCIU'), findsOneWidget);
    expect(find.text('W SERWISIE'), findsOneWidget);
    expect(find.text('Pojazdy – wymaga uwagi'), findsOneWidget);
  });

  testWidgets('wejście na ekran odświeża listę: pojazd w naprawie na czerwono', (tester) async {
    await pump(tester);
    expect(find.textContaining('w naprawie'), findsNothing);

    vehicles = [
      {...truck, 'in_repair': true}
    ];
    shown.value++;
    await tester.pumpAndSettle();

    expect(find.textContaining('w naprawie'), findsNWidgets(2)); // kafelek + objaśnienie kolorów
    final tile = find.ancestor(of: find.textContaining('${truck['name']}').first, matching: find.byType(Card)).first;
    expect(tester.widget<Card>(tile).color, Theme.of(tester.element(tile)).colorScheme.errorContainer);
    expect(changes, 0); // samo odświeżenie nie powiadamia planera
  });

  testWidgets('paliwo i spalanie: jednostka według napędu, AdBlue tylko przy ON', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, dynamic>? saved;
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        if (request.method == 'PUT') {
          saved = (jsonDecode(request.body) as Map).cast<String, dynamic>();
          return json(saved);
        }
        return json(request.url.path == '/api/companies' ? [] : {'currencies': [], 'per_eur': {}});
      }),
    );
    Future<void> open(Map<String, dynamic> vehicle) async {
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(MaterialPageRoute<dynamic>(builder: (_) => VehicleFormScreen(api: api, vehicle: vehicle)));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(localized(const SizedBox()));
    await open({...truck, 'kind': 'tractor', 'fuel_type': 'lng', 'co2_class': 2, 'consumption_empty': 20});
    expect(find.text('kg/100 km'), findsNWidgets(2));
    expect(find.text('AdBlue (% spalania)'), findsNothing);
    expect(find.text('klasa 2'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Spalanie z ładunkiem'), '27,5');
    await tester.enterText(find.widgetWithText(TextFormField, 'Własna cena paliwa'), '1,4');
    await tester.ensureVisible(find.text('Zapisz'));
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    expect(saved, containsPair('consumption_loaded', 27.5));
    expect(saved, containsPair('fuel_price', 1.4));
    expect(saved, containsPair('fuel_type', 'lng'));
    expect(saved, containsPair('co2_class', 2));
    expect(saved, containsPair('adblue_percent', null));

    await open({...truck, 'kind': 'tractor'});
    expect(find.text('AdBlue (% spalania)'), findsOneWidget);
    expect(find.text('l/100 km'), findsNWidgets(2));
  });

  testWidgets('dowód: skan na żywo z aparatu (telefon) wypełnia formularz', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async => switch (request.url.path) {
            '/api/vehicles/registration' => json({'name': 'DAF XF', 'kind': 'tractor', 'axle_count': 2}),
            '/api/companies' => json([]),
            _ => json({'currencies': [], 'per_eur': {}}),
          }),
    );
    await tester.pumpWidget(localized(VehicleFormScreen(api: api, codeScanner: (_) async => 'KOD')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wczytaj z dowodu rejestracyjnego'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skanuj kod aparatem'));
    await tester.pumpAndSettle();
    expect(find.text('DAF XF'), findsOneWidget);
  });

  testWidgets('dowód z innego kraju UE: tekst ze zdjęcia idzie na serwer', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Object? sent;
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        if (request.url.path == '/api/vehicles/registration') {
          sent = jsonDecode(request.body);
          return json({'name': 'MERCEDES-BENZ ACTROS', 'vin': 'WDB9634031L123456'});
        }
        return json(request.url.path == '/api/companies' ? [] : {'currencies': [], 'per_eur': {}});
      }),
    );
    await tester.pumpWidget(localized(VehicleFormScreen(api: api, textReader: () async => 'E WDB9634031L123456')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wczytaj z dowodu rejestracyjnego'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dowód z innego kraju UE'));
    await tester.pumpAndSettle();
    expect(sent, {'text': 'E WDB9634031L123456'});
    expect(find.text('MERCEDES-BENZ ACTROS'), findsOneWidget);
  });
}
