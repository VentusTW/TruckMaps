import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/l10n.dart';
import 'package:truckmaps_app/src/live/live_screen.dart' show LiveVehicle;
import 'package:truckmaps_app/src/live/route_plan_panel.dart';
import 'package:truckmaps_app/src/live/send_route.dart';
import 'package:truckmaps_app/src/planner/place_field.dart';
import 'package:truckmaps_app/src/planner/route.dart';
import 'package:truckmaps_app/src/service/analytics_screen.dart';
import 'package:truckmaps_app/src/service/fleet_export.dart';
import 'package:truckmaps_app/src/service/revenue.dart';
import 'package:truckmaps_app/src/service/service_data.dart';

import 'localized.dart';

http.Response json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

final vehicles = [
  {'id': 'v1', 'company_id': 'c1', 'kind': 'tractor', 'name': 'Volvo FH', 'plate': 'WI 4022P'},
  {'id': 'v2', 'company_id': 'c1', 'kind': 'tractor', 'name': 'MAN TGX', 'plate': 'KR 1234A'},
];

Map<String, dynamic> summary({double? lyon = 9000}) => {
      'currency': 'PLN',
      'count': lyon == null ? 1 : 2,
      'orders_total': 2,
      'amount': {'PLN': 3300 + (lyon ?? 0)},
      'total': 3300 + (lyon ?? 0),
      'unconverted': ['HUF'],
      'km': lyon == null ? 600 : 2050,
      'per_km': lyon == null ? 5.5 : 6.0,
      'months': const [],
      'vehicles': [
        if (lyon != null) {'vehicle_id': 'v1', 'plate': 'WI 4022P', 'count': 1, 'km': 1450, 'total': lyon},
        {'vehicle_id': 'v2', 'plate': 'KR 1234A', 'count': 1, 'km': 600, 'total': 3300},
      ],
      'orders': [
        {
          'assignment_id': 'a1',
          'vehicle_id': 'v1',
          'plate': 'WI 4022P',
          'label': 'Kraków → Lyon',
          'distance_km': 1450,
          'state': 'done',
          'created_at': '2026-11-02T10:00:00Z',
          'amount': lyon,
          'currency': lyon == null ? null : 'PLN',
          'rate_per_km': null,
        },
        {
          'assignment_id': 'a2',
          'vehicle_id': 'v2',
          'plate': 'KR 1234A',
          'label': 'Kraków → Berlin',
          'distance_km': 600,
          'state': 'sent',
          'created_at': '2026-11-03T10:00:00Z',
          'amount': 3300,
          'currency': 'PLN',
          'rate_per_km': 5.5,
        },
      ],
    };

/// Serwer testowy: pojazdy, statystyki przejazdów, przychody i karty paliwowe; zapisuje PUT/DELETE.
CoreApi api(List<http.Request> calls, {bool fuel = true, bool revenue = true}) {
  var lyon = 9000.0 as double?;
  return CoreApi(
    baseUrl: 'http://serwer.test',
    token: 't',
    client: MockClient((r) async {
      calls.add(r);
      if (r.url.path.endsWith('/revenue')) {
        if (r.method == 'DELETE') {
          lyon = null;
          return http.Response('', 204);
        }
        final body = jsonDecode(r.body) as Map;
        lyon = (body['amount'] as num).toDouble();
        return json({'assignment_id': 'a1', 'amount': lyon, 'currency': body['currency']});
      }
      return switch (r.url.path) {
        '/api/vehicles' => json(vehicles),
        '/api/vehicles/v1/stats' => json({
            'distance_km': 1500,
            'costs': {'PLN': 4000}
          }),
        '/api/vehicles/v2/stats' => json({
            'distance_km': 700,
            'costs': {'PLN': 2000}
          }),
        '/api/companies/c1/revenue/summary' =>
          revenue ? json(summary(lyon: lyon)) : http.Response('{"detail":"forbidden"}', 403),
        '/api/companies/c1/fuel-cards/summary' => fuel
            ? json({
                'count': 3,
                'amount': {'PLN': 1500},
                'vehicles': [
                  {
                    'vehicle_id': 'v1',
                    'amount': {'PLN': 1000}
                  },
                  {
                    'vehicle_id': null,
                    'amount': {'PLN': 500}
                  },
                ],
              })
            : http.Response('{"detail":"Not Found"}', 404),
        _ => json(<String, dynamic>{}),
      };
    }),
  );
}

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 2800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget screen(CoreApi api) => localized(Scaffold(
      body: AnalyticsScreen(api: api, companyId: 'c1', companyName: 'Trans', onOpen: (_) {}),
    ));

void main() {
  test('kwota z pola: przecinek, spacje, błędne i ujemne', () {
    expect(parseAmount('1 234,50'), 1234.5);
    expect(parseAmount('9000'), 9000);
    expect(parseAmount(''), isNull);
    expect(parseAmount('abc'), isNull);
    expect(parseAmount('-5'), isNull);
  });

  testWidgets('analityka: przychód, na km, koszty z kartami paliwowymi i marża', (tester) async {
    big(tester);
    await tester.pumpWidget(screen(api([])));
    await tester.pumpAndSettle();
    expect(find.text('Przychód ze zleceń'.toUpperCase()), findsOneWidget);
    expect(find.text('12300 PLN', findRichText: true), findsOneWidget);
    expect(find.text('• Na km: 6 PLN/km'), findsOneWidget);
    // Trasy 4000 + 2000, karty 1500 → koszty 7500, marża 12 300 − 7500.
    expect(find.text('Koszty (trasy, serwis, karty paliwowe): 7500 PLN'), findsOneWidget);
    expect(find.text('Marża: 4800 PLN'), findsOneWidget);
    expect(find.text('Zlecenia z przychodem: 2 z 2'), findsOneWidget);
    expect(find.text('Bez kursu (poza sumą): HUF'), findsOneWidget);
  });

  testWidgets('analityka bez kart paliwowych i bez dostępu do przychodów', (tester) async {
    big(tester);
    await tester.pumpWidget(screen(api([], fuel: false)));
    await tester.pumpAndSettle();
    expect(find.text('Koszty (trasy, serwis): 6000 PLN'), findsOneWidget);
    expect(find.text('Marża: 6300 PLN'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(screen(api([], revenue: false)));
    await tester.pumpAndSettle();
    expect(find.text('Przychody widzą właściciel i dyspozytor'), findsOneWidget);
    expect(find.byKey(const Key('an-margin')), findsNothing);
  });

  testWidgets('wpisanie przychodu zlecenia odświeża kartę, usunięcie też', (tester) async {
    big(tester);
    final calls = <http.Request>[];
    await tester.pumpWidget(screen(api(calls)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('an-revenue-enter')));
    await tester.pumpAndSettle();
    expect(find.text('Kraków → Lyon'), findsOneWidget);
    expect(find.text('3300 PLN'), findsOneWidget);

    await tester.tap(find.byKey(const Key('revenue-order-a1')));
    await tester.pumpAndSettle();
    // Bez kwoty i stawki – komunikat, nic nie zapisano.
    await tester.enterText(find.byKey(const Key('revenue-amount')), '');
    await tester.tap(find.byKey(const Key('revenue-save')));
    await tester.pumpAndSettle();
    expect(find.text('Podaj kwotę albo stawkę za km.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('revenue-amount')), '10 000,50');
    await tester.tap(find.byKey(const Key('revenue-save')));
    await tester.pumpAndSettle();
    final put = calls.lastWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/companies/c1/route-assignments/a1/revenue');
    expect(jsonDecode(put.body), {'amount': 10000.5, 'currency': 'PLN'});
    expect(find.text('10000,5 PLN'), findsOneWidget);

    await tester.tap(find.byKey(const Key('revenue-order-a1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('revenue-remove')));
    await tester.pumpAndSettle();
    expect(calls.where((r) => r.method == 'DELETE'), hasLength(1));
    expect(find.text('brak przychodu'), findsOneWidget);

    await tester.tap(find.text('Zamknij'));
    await tester.pumpAndSettle();
    expect(find.text('3300 PLN', findRichText: true), findsOneWidget);
  });

  test('raport CSV: kolumna przychodu według pojazdu', () {
    final l = lookupAppLocalizations(const Locale('pl'));
    final data = FleetData(vehicles: vehicles, orders: const []);
    final rows = fleetReportRows(l, data, (_) => 0, revenue: {'v1': 9000});
    expect(rows.first.last, 'Przychód (PLN)');
    expect(rows[1].last, '9000,00');
    expect(rows[2].last, '0,00');
    expect(fleetReportRows(l, data, (_) => 0).first.last, isNot('Przychód (PLN)'));
  });

  testWidgets('wysyłka trasy kierowcy ze stawką za km zapisuje przychód zlecenia', (tester) async {
    final calls = <http.Request>[];
    final client = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async {
        calls.add(r);
        return switch (r.url.path) {
          '/api/companies/c1' => json({
              'members': [
                {'id': 'm1', 'role': 'driver', 'display_name': 'Jan'}
              ]
            }),
          '/api/companies/c1/route-assignments' => json({'id': 'a9'}),
          _ => json({'assignment_id': 'a9', 'amount': 3300}),
        };
      }),
    );
    String? sent;
    await tester.pumpWidget(localized(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async => sent = await sendRouteToDriver(
            context,
            api: client,
            companyId: 'c1',
            vehicleId: 'v1',
            start: const Place('Kraków', LatLng(50.06, 19.94)),
            end: const Place('Berlin', LatLng(52.52, 13.4)),
            via: const [],
            route: PlannedRoute(
                distanceKm: 600,
                durationMin: 420,
                points: const [],
                level: null,
                segments: const [],
                warnings: const []),
            avoidDifficult: true,
          ),
          child: const Text('wyślij'),
        ),
      ),
    )));
    await tester.tap(find.text('wyślij'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('revenue-rate')), '5,5');
    await tester.tap(find.byKey(const Key('revenue-currency')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EUR').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('send-route-confirm')));
    await tester.pumpAndSettle();
    expect(sent, 'Jan');
    final put = calls.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/companies/c1/route-assignments/a9/revenue');
    expect(jsonDecode(put.body), {'rate_per_km': 5.5, 'currency': 'EUR'});
  });

  testWidgets('panel wysyłki trasy na mapie zapisuje kwotę zlecenia', (tester) async {
    big(tester);
    final calls = <http.Request>[];
    final client = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async {
        calls.add(r);
        return switch (r.url.path) {
          '/api/companies/c1' => json({
              'members': [
                {'id': 'm1', 'role': 'driver', 'display_name': 'Jan'}
              ]
            }),
          '/api/routes' => json({
              'distance_km': 600.0,
              'duration_min': 420.0,
              'geometry': [
                [19.94, 50.06],
                [13.4, 52.52]
              ],
              'analysis': {'level': 'green', 'segments': [], 'warnings': []},
              'cost': null,
              'alternatives': [],
            }),
          '/api/companies/c1/route-assignments' => json({'id': 'a7'}),
          _ => json({'assignment_id': 'a7', 'amount': 4200}),
        };
      }),
    );
    String? sent;
    await tester.pumpWidget(localized(Scaffold(
      body: RoutePlanPanel(
        api: client,
        companyId: 'c1',
        vehicle: const LiveVehicle(id: 'v1', name: 'Volvo', position: LatLng(50.06, 19.94)),
        onRoute: (_) {},
        onClose: () {},
        onSent: (name) => sent = name,
      ),
    )));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.descendant(of: find.byKey(const Key('plan-end')), matching: find.byType(TextField)), '52.52, 13.4');
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPS 52.52, 13.4').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('plan-calculate')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('revenue-amount')), '4 200');
    await tester.ensureVisible(find.byKey(const Key('plan-send')));
    await tester.tap(find.byKey(const Key('plan-send')));
    await tester.pumpAndSettle();
    expect(sent, 'Jan');
    final put = calls.singleWhere((r) => r.method == 'PUT');
    expect(put.url.path, '/api/companies/c1/route-assignments/a7/revenue');
    expect(jsonDecode(put.body), {'amount': 4200, 'currency': 'PLN'});
  });
}
