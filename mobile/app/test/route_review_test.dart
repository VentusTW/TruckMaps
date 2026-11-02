import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart' show mapTiles;
import 'package:truckmaps_app/src/planner/route.dart';
import 'package:truckmaps_app/src/planner/route_review.dart';
import 'localized.dart';

final result = RouteResult.fromJson({
  'distance_km': 812.4,
  'duration_min': 560.0,
  'geometry': [
    [19.9, 50.0],
    [17.0, 51.1],
    [14.9, 51.2],
    [13.4, 52.5]
  ],
  'analysis': null,
  'alternatives': [
    {
      'distance_km': 840.0,
      'duration_min': 590.0,
      'geometry': [
        [19.9, 50.0],
        [13.4, 52.5]
      ],
      'analysis': null
    },
  ],
  'stop_issues': [],
  'departure': '2026-10-31T08:00:00+01:00',
  'time_bans': {'bans': [], 'arrival': '2026-10-31T22:20:00+01:00', 'wait_min': 300, 'free_departure': null},
  'countries': [
    {
      'country': 'PL',
      'name': 'Polska',
      'km': 0.0,
      'lat': 50.0,
      'lon': 19.9,
      'border': false,
      'enter_at': '2026-10-31T08:00:00+01:00',
      'bans': 'free',
      'summary': 'bez zakazu w czasie przejazdu',
    },
    {
      'country': 'DE',
      'name': 'Niemcy',
      'km': 520.3,
      'lat': 51.2,
      'lon': 14.9,
      'border': true,
      'enter_at': '2026-10-31T14:00:00+01:00',
      'bans': 'ban',
      'summary': 'zakaz do 22:00',
    },
    {
      'country': 'NL',
      'name': 'Holandia',
      'km': 800.0,
      'lat': 52.5,
      'lon': 13.4,
      'border': true,
      'enter_at': '2026-10-31T22:10:00+01:00',
      'bans': 'no_data',
      'summary': 'brak danych',
    },
  ],
});

Future<void> pumpReview(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api =
      CoreApi(baseUrl: 'http://serwer.test', token: 't', client: MockClient((_) async => http.Response('', 404)));
  await tester.pumpWidget(localized(RouteReviewScreen(
    api: api,
    result: result,
    vehicleId: 'v1',
    destination: const LatLng(52.5, 13.4),
    vehicleHeadline: 'MAN TGX + Firanka · 40 t · 4 m',
  )));
  await tester.pump();
}

void main() {
  setUp(() => mapTiles = () => const SizedBox());

  test('kraje na trasie z odpowiedzi planera', () {
    expect([
      for (final c in result.countries) (c.country, c.border, c.bans)
    ], [
      ('PL', false, 'free'),
      ('DE', true, 'ban'),
      ('NL', true, 'no_data'),
    ]);
    expect(result.countries[1].km, 520.3);
    expect(result.departure, DateTime.parse('2026-10-31T08:00:00+01:00').toLocal());
  });

  testWidgets('przegląd: pojazd, podsumowanie, kraje, zakazy i „Rozpocznij jazdę”', (tester) async {
    await pumpReview(tester);

    expect(find.text('Przegląd trasy'), findsOneWidget);
    expect(find.text('MAN TGX + Firanka · 40 t · 4 m'), findsOneWidget);
    expect(find.text('812 km'), findsOneWidget);
    expect(find.text('9 h 20 min'), findsOneWidget); // czas jazdy
    expect(find.text('5 h 0 min'), findsOneWidget); // opóźnienie – postój w czasie zakazów
    expect(find.text('Niemcy: zakaz do 22:00'), findsOneWidget);
    expect(find.text('Holandia: brak danych'), findsOneWidget);
    expect(find.textContaining('granica: km 520,3'), findsOneWidget);
    expect(find.text('812 km · 9 h 20 min'), findsOneWidget); // wariant na mapie
    expect(find.text('840 km · 9 h 50 min'), findsOneWidget);
    expect(find.text('Rozpocznij jazdę'), findsOneWidget);
  });

  testWidgets('wybór alternatywy zmienia podsumowanie', (tester) async {
    await pumpReview(tester);

    await tester.tap(find.text('840 km · 9 h 50 min'));
    await tester.pump();

    expect(find.text('840 km'), findsOneWidget);
    expect(find.text('liczone tylko dla trasy proponowanej'), findsOneWidget);
    expect(find.text('Dla trasy proponowanej.'), findsOneWidget);
  });
}
