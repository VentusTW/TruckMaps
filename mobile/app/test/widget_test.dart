import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/main.dart';
import 'package:truckmaps_app/src/auth.dart';

http.Response json(Object body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Session session(Map<String, Object> responses) {
  final client = MockClient((request) async => json(responses[request.url.path] ?? {}));
  return Session(
    api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
    userName: 'Michał Krajewski',
  );
}

/// Fragment danych pokazowych (`dashboard_demo.py`).
const screen = {
  'greeting_name': 'Michale',
  'user_title': 'Główny Dyspozytor',
  'shift': 'Zmiana Dzienna (06:00 – 18:00)',
  'fleet_ok': '98.4%',
  'description': 'Centrum Koordynacji Flotowej',
  'base': 'PL-WAW-01 (Baza Wesoła)',
  'telemetry': {'label': 'Telemetria CAN', 'percent': '98.4%', 'active': 318, 'total': 323, 'gps': 'Satelity: Fix OK'},
  'kpis': [
    {
      'label': 'Aktywne zestawy w trasie',
      'icon': 'truck',
      'value': '284',
      'unit': '/ 323 ciągniki',
      'left': '88% utylizacji',
      'right': '+12 vs wczoraj',
      'bar': 0.88
    },
  ],
  'alerts_count': '3 zdarzenia priorytetowe',
  'alerts': [
    {
      'tag': 'Krytyczny tachograf',
      'severity': 'critical',
      'icon': 'timer',
      'title': 'Ciągnik WI 4022P',
      'location': 'A2 km 384',
      'text': 'Limit jazdy za !!45 min!!.',
      'meta': ['Kierowca: Janusz Bogucki'],
      'action': 'Przekieruj na MOP Świebodzin',
      'action_icon': 'alt_route'
    },
  ],
  'corridors_updated': '2 min temu',
  'corridors': [
    {
      'road': 'A2',
      'name': 'Korytarz Zachodni',
      'status': 'Płynny ruch',
      'status_tone': 'ok',
      'left': 'W trasie: **42 zestawy**',
      'right': 'Średnia: **82.4 km/h**',
      'bar': 0.95
    },
  ],
  'modules': [
    {
      'title': 'Symulator 3D Załadunku',
      'icon': 'view_in_ar',
      'chip': 'EN 12195-1',
      'chip_tone': 'tertiary',
      'text': 'Naciski na osie',
      'stats': ['9 planów aktywnych'],
      'link': 'Otwórz 3D'
    },
  ],
  'messages': [
    {
      'tag': 'Ostrzeżenie trasy',
      'tone': 'error',
      'time': '11:15',
      'title': 'Kontrole BALM / BAG na A12',
      'text': 'Wzmożone kontrole.',
      'sender': 'Dyspozytor Zmianowy Berlin'
    },
  ],
};

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1600, 2200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Kilka klatek: konto → firma → treść pulpitu (animacja chipa dyżuru nie pozwala na pumpAndSettle).
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  testWidgets('bez zapisanej sesji – ekran logowania', (tester) async {
    await tester.pumpWidget(
        TruckMapsApp(login: BrowserLogin('http://serwer.test', store: MemoryStore()), locale: const Locale('pl')));
    await tester.pumpAndSettle();

    expect(find.text('Zaloguj się e-mailem'), findsOneWidget);
  });

  testWidgets('po zalogowaniu – pulpit główny z danymi; każda pozycja i przycisk prowadzi do „W budowie”',
      (tester) async {
    big(tester);
    await tester.pumpWidget(TruckMapsApp(
      locale: const Locale('pl'),
      session: session({
        '/api/me/settings': {'display_name': 'Michał Krajewski', 'onboarded': true},
        '/api/companies': [
          {'id': 'c1', 'name': 'Trans-Miś', 'role': 'dispatcher'},
        ],
        '/api/dashboard/screen': {
          'company_id': 'c1',
          'company_name': 'Trans-Miś',
          'user_name': 'Michał Krajewski',
          'role': 'dispatcher',
          'bases': <String>[],
          'generated_at': '2026-11-06T08:00:00Z',
          'screen': screen,
        },
      }),
    ));
    await settle(tester);

    // Menu z wzoru, nazwa TruckMaps.
    expect(find.text('TruckMaps'), findsOneWidget);
    expect(find.text('MODUŁY OPERACYJNE'), findsOneWidget);
    for (final item in ['Pulpit Główny', 'Pojazdy i Tabor', 'Centrala & Live Map', 'Symulator 3D Załadunku']) {
      expect(find.text(item), findsWidgets);
    }
    expect(find.text('LIVE'), findsOneWidget);
    // Górny pasek i karta telemetrii.
    expect(find.text('PL-WAW-01 (Baza Wesoła)'), findsOneWidget);
    expect(find.text('Główny Dyspozytor'), findsOneWidget);
    expect(find.text('318 / 323'), findsOneWidget);
    // Pulpit.
    // Imię zalogowanego użytkownika, nie z danych pokazowych pulpitu.
    expect(find.text('Dzień dobry, Michał'), findsOneWidget);
    expect(find.text('Dzień dobry, Michale'), findsNothing);
    expect(find.text('Dyżur: Zmiana Dzienna (06:00 – 18:00)'), findsOneWidget);
    expect(find.text('98.4% Sprawności Floty'), findsOneWidget);
    expect(find.text('AKTYWNE ZESTAWY W TRASIE'), findsOneWidget);
    expect(find.text('284', findRichText: true), findsNothing); // liczba w jednym tekście z jednostką
    expect(find.textContaining('284', findRichText: true), findsOneWidget);
    expect(find.text('KRYTYCZNY TACHOGRAF'), findsOneWidget);
    expect(find.text('Ciągnik WI 4022P'), findsOneWidget);
    expect(find.text('Korytarz Zachodni'), findsOneWidget);
    expect(find.text('Aktualizacja: 2 min temu'), findsOneWidget);
    expect(find.text('EN 12195-1'), findsOneWidget);
    expect(find.text('Nadawca: Dyspozytor Zmianowy Berlin'), findsOneWidget);

    Future<void> expectWip(String title) async {
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('W BUDOWIE'), findsOneWidget);
      expect(find.text(title), findsWidgets);
      await tester.tap(find.byKey(const Key('wip-back')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('W BUDOWIE'), findsNothing);
    }

    // Zlecenia i Załadunek – plan załadunku z modułu (bez pojazdów z przestrzenią ładunkową).
    await tester.tap(find.text('Zlecenia i Załadunek'));
    await settle(tester);
    expect(find.text('W BUDOWIE'), findsNothing);
    expect(find.text('Brak pojazdów z przestrzenią ładunkową.'), findsOneWidget);
    // Pojazdy i Tabor – własny ekran (dane z /api/vehicles).
    await tester.tap(find.text('Pojazdy i Tabor'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Tabor Samochodowy i Sprzęt'), findsOneWidget);
    await tester.tap(find.text('Pulpit Główny').first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('+ Nowe Zlecenie'));
    await expectWip('+ Nowe Zlecenie');
    await tester.tap(find.text('Przekieruj na MOP Świebodzin'));
    await expectWip('Przekieruj na MOP Świebodzin');
    await tester.tap(find.text('Otwórz 3D →'));
    await expectWip('Symulator 3D Załadunku');
    await tester.tap(find.byKey(const Key('main-notifications')));
    await expectWip('Powiadomienia');
  });

  testWidgets('bez danych pulpitu – czytelne stany puste', (tester) async {
    big(tester);
    await tester.pumpWidget(TruckMapsApp(
      locale: const Locale('pl'),
      session: session({
        '/api/me/settings': {'display_name': 'Anna Kowalska', 'onboarded': true},
        '/api/companies': <Object>[],
      }),
    ));
    await settle(tester);
    expect(find.text('Dzień dobry, Anna'), findsOneWidget);
    expect(find.text('Brak aktywnych alertów.'), findsOneWidget);
    expect(find.text('Brak komunikatów.'), findsOneWidget);
    expect(find.textContaining('Brak danych o korytarzach'), findsOneWidget);
    expect(find.text('GPS / brak danych'), findsOneWidget);
  });

  testWidgets('po angielsku – teksty interfejsu z tłumaczeń', (tester) async {
    big(tester);
    await tester.pumpWidget(TruckMapsApp(
      locale: const Locale('en'),
      session: session({
        '/api/me/settings': {'display_name': 'Anna Kowalska'},
        '/api/companies': <Object>[]
      }),
    ));
    await settle(tester);
    expect(find.text('Main Dashboard'), findsWidgets);
    expect(find.text('Active Operational Alerts Centre'), findsOneWidget);
    expect(find.text('Good morning, Anna'), findsOneWidget);
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
