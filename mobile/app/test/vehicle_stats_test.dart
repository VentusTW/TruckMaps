import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/vehicles/vehicle_stats.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  testWidgets('statystyki pojazdu: sumy, puste km, kierowcy, naczepy, porównanie i koszty napraw', (tester) async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add('${request.url.path}?${request.url.query}');
      if (request.url.path == '/api/m/service/costs') {
        return json([
          {'currency': 'PLN', 'orders': 2, 'parts_total': 1900.0, 'labour_total': 450.0, 'total': 2350.0},
        ]);
      }
      return json({
        'vehicle_id': 'v1',
        'trips': 3,
        'distance_km': 700.4,
        'hours': 9.5,
        'drivers': 2,
        'costs': {'EUR': 732.5},
        'cost_per_km': {'EUR': 1.331},
        'months': [
          {'month': '2026-11', 'trips': 1, 'distance_km': 240.0, 'hours': 3.0, 'drivers': 1, 'costs': {'EUR': 300.0}},
        ],
        'first_trip': '2026-10-03T06:00:00Z',
        'last_trip': '2026-11-01T06:00:00Z',
        'empty_km': 140.0,
        'empty_share': 0.2,
        'idle_hours': 1.5,
        'by_driver': [
          {'id': 'jan', 'name': 'Jan', 'trips': 2, 'distance_km': 500.0},
        ],
        'linked': [
          {'id': 'n1', 'name': 'Firanka 1', 'trips': 3, 'distance_km': 700.4},
        ],
        'previous': {'trips': 2, 'distance_km': 560.0, 'hours': 8.0, 'costs': {}},
      });
    });
    tester.view.physicalSize = const Size(1200, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(localized(VehicleStatsScreen(
      api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
      vehicle: const {'id': 'v1', 'name': 'Zestaw', 'kind': 'tractor'},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Statystyki: Zestaw'), findsOneWidget);
    expect(find.text('700 km'), findsOneWidget);
    expect(find.text('+25% do poprzedniego okresu'), findsOneWidget);
    expect(find.text('1,33 EUR'), findsOneWidget);
    expect(find.text('140 km'), findsOneWidget);
    expect(find.text('20%'), findsOneWidget);
    expect(find.text('Jan'), findsOneWidget);
    expect(find.text('Firanka 1'), findsOneWidget);
    expect(find.text('napraw: 2'), findsOneWidget); // koszty napraw z modułu Serwis
    expect(find.textContaining('240 km · przejazdy: 1'), findsOneWidget);
    await tester.tap(find.text('36 mies.'));
    await tester.pumpAndSettle();
    expect(paths, contains('/api/vehicles/v1/stats?months=36'));
    expect(paths.last, startsWith('/api/m/service/costs?vehicle_id=v1&date_from='));
  });
}
