import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/main.dart';
import 'package:truckmaps_app/src/auth.dart';
import 'package:truckmaps_app/src/home.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';

import 'localized.dart';

http.Response json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Session session(Map<String, Object> responses) {
  final client = MockClient((request) async => json(responses[request.url.path] ?? {}));
  return Session(
    api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
    userName: 'Anna Kowalska',
  );
}

void main() {
  setUp(() => mapTiles = () => const SizedBox());
  pageMemoryTests();

  testWidgets('bez zapisanej sesji – ekran logowania', (tester) async {
    await tester.pumpWidget(
        TruckMapsApp(login: BrowserLogin('http://serwer.test', store: MemoryStore()), locale: const Locale('pl')));
    await tester.pumpAndSettle();

    expect(find.text('Zaloguj się e-mailem'), findsOneWidget);
  });

  testWidgets('bez logowania – menu widoczne, ale tylko powitanie i mapa do otwarcia', (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
        TruckMapsApp(login: BrowserLogin('http://serwer.test', store: MemoryStore()), locale: const Locale('pl')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Pojazdy'));
    await tester.pumpAndSettle();
    expect(find.text('Zaloguj się e-mailem'), findsOneWidget);  // wyłączone – bez zmiany ekranu

    await tester.tap(find.text('Mapa'));
    await tester.pumpAndSettle();
    expect(find.text('Zaloguj się e-mailem'), findsNothing);
    expect(find.text('Pozostałe funkcje po zalogowaniu.'), findsOneWidget);
  });

  testWidgets('po zalogowaniu – pojazdy, moduły z dostępem i „Kup moduł”', (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TruckMapsApp(
      locale: const Locale('pl'),
      session: session({
        '/api/vehicles': [
          {'id': 'v1', 'name': 'Zestaw 40 t', 'height_m': 4.0, 'width_m': 2.55, 'length_m': 16.5, 'weight_t': 40,
           'gvw_t': 40, 'axle_load_t': 11.5, 'company_id': null, 'can_edit': true},
        ],
        '/api/me/modules': [
          {'id': 'hello', 'name': 'Hello', 'version': '0.1.0', 'granted': true},
          {'id': 'tolls', 'name': 'Opłaty drogowe', 'version': '0.1.0', 'granted': false},
        ],
        '/api/m/hello/greeting': {'message': 'Witaj w TruckMaps!', 'core_version': '0.1.0'},
      }),
    ));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));  // moduły wczytane → powitanie z serwera

    // Bez zapamiętanego ekranu – pulpit; ekran modułu (Powitanie) jest w menu.
    expect(find.text('Pulpit'), findsWidgets);
    expect(find.textContaining(', Anna Kowalska'), findsOneWidget);  // powitanie na pulpicie
    expect(find.text('Zaplanuj trasę'), findsOneWidget);
    await tester.tap(find.text('Powitanie'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Witaj w TruckMaps!'), findsOneWidget);

    await tester.tap(find.text('Pojazdy'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Zestaw 40 t'), findsWidgets);
    expect(find.text('Witaj w TruckMaps!'), findsNothing);

    await tester.tap(find.text('Moduły'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Aktywny'), findsOneWidget);
    expect(find.text('Wymaga nowszej wersji aplikacji.'), findsOneWidget);
  });

  testWidgets('po angielsku – ekrany i odpowiedzi serwera w języku aplikacji', (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final languages = <String?>{};
    final client = MockClient((request) async {
      languages.add(request.headers['Accept-Language']);
      return json(request.url.path == '/api/vehicles' ? [] : {});
    });
    await tester.pumpWidget(TruckMapsApp(
      locale: const Locale('en'),
      session: Session(api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client), userName: 'Anna'),
    ));
    await tester.pump(const Duration(seconds: 1));

    expect(find.text('Plan a route'), findsOneWidget);  // pulpit
    await tester.tap(find.text('Vehicles'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('No vehicles. Add the first one with “Add vehicle”.'), findsOneWidget);
    expect(languages, {'en'});
  });

  test('język systemu bez tłumaczenia → polski', () {
    const supported = [Locale('en'), Locale('pl')];
    expect(resolveLocale(const Locale('en', 'GB'), supported), const Locale('en'));
    expect(resolveLocale(const Locale('fr'), supported), const Locale('pl'));
    expect(resolveLocale(null, supported), const Locale('pl'));
  });
}

class MemoryStore implements SessionStore {
  Tokens? tokens;

  @override
  Future<Tokens?> load() async => tokens;

  @override
  Future<void> save(Tokens value) async => tokens = value;

  @override
  Future<void> clear() async => tokens = null;
}

class FakePageMemory implements PageMemory {
  FakePageMemory(this.saved);

  String? saved;

  @override
  Future<String?> load() async => saved;

  @override
  Future<void> save(String pageId) async => saved = pageId;
}

void pageMemoryTests() {
  testWidgets('aplikacja wraca do ostatnio używanego ekranu i go zapamiętuje', (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final memory = FakePageMemory('vehicles');
    await tester.pumpWidget(localized(HomeScreen(
      session: session({
        '/api/vehicles': [
          {'id': 'v1', 'name': 'Zestaw 40 t', 'height_m': 4.0, 'width_m': 2.55, 'length_m': 16.5, 'weight_t': 40,
           'gvw_t': 40, 'axle_load_t': 11.5, 'company_id': null, 'can_edit': true},
        ],
        '/api/me/modules': [],
      }),
      registry: modules,
      onLogout: () {},
      pageMemory: memory,
    )));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Zestaw 40 t'), findsWidgets);

    await tester.tap(find.text('Konto'));
    await tester.pump(const Duration(seconds: 1));
    expect(memory.saved, 'account');
  });

  testWidgets('kierowca na telefonie: dolna nawigacja, Tachograf i e-CMR – ekran „W budowie”', (tester) async {
    tester.view.physicalSize = const Size(700, 900); // węższy niż 720 – telefon (podpis mapy mieści się)
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final memory = FakePageMemory('route');
    await tester.pumpWidget(localized(HomeScreen(
      session: session({'/api/vehicles': [], '/api/me/modules': []}),
      registry: modules,
      onLogout: () {},
      pageMemory: memory,
    )));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Tachograf'), findsOneWidget);
    expect(find.text('e-CMR'), findsOneWidget);
    await tester.tap(find.byKey(const Key('bottom-tachograph')));
    await tester.pumpAndSettle();
    expect(find.text('W BUDOWIE'), findsOneWidget);
    expect(memory.saved, isNot('tachograph'));
    await tester.tap(find.text('Wróć'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('bottom-vehicles')));
    await tester.pump(const Duration(seconds: 1));
    expect(memory.saved, 'vehicles');
  });
}
