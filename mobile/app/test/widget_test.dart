import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/main.dart';
import 'package:truckmaps_app/src/auth.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';

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

  testWidgets('bez zapisanej sesji – ekran logowania', (tester) async {
    await tester.pumpWidget(TruckMapsApp(login: BrowserLogin('http://serwer.test', store: MemoryStore())));
    await tester.pumpAndSettle();

    expect(find.text('Zaloguj się e-mailem'), findsOneWidget);
  });

  testWidgets('po zalogowaniu – pojazdy, moduły z dostępem i „Kup moduł”', (tester) async {
    tester.view.physicalSize = const Size(1800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(TruckMapsApp(
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

    expect(find.text('Wyznacz trasę'), findsOneWidget);  // pierwszy ekran: planer trasy
    expect(find.text('Anna Kowalska'), findsOneWidget);

    await tester.tap(find.text('Pojazdy'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Zestaw 40 t'), findsWidgets);

    await tester.tap(find.text('Powitanie'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Witaj w TruckMaps!'), findsOneWidget);

    await tester.tap(find.text('Moduły'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Aktywny'), findsOneWidget);
    expect(find.text('Wymaga nowszej wersji aplikacji.'), findsOneWidget);
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
