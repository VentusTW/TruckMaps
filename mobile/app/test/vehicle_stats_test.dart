import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/vehicles/vehicle_stats.dart';

import 'localized.dart';

void main() {
  testWidgets('statystyki pojazdu: sumy, koszt na km i miesiące', (tester) async {
    final paths = <String>[];
    final client = MockClient((request) async {
      paths.add('${request.url.path}?${request.url.query}');
      return http.Response.bytes(
          utf8.encode(jsonEncode({
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
          })),
          200);
    });
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(localized(VehicleStatsScreen(
      api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
      vehicle: const {'id': 'v1', 'name': 'Zestaw'},
    )));
    await tester.pumpAndSettle();

    expect(find.text('Statystyki: Zestaw'), findsOneWidget);
    expect(find.text('700 km'), findsOneWidget);
    expect(find.text('1,33 EUR'), findsOneWidget);
    expect(find.textContaining('240 km · przejazdy: 1'), findsOneWidget);
    await tester.tap(find.text('36 mies.'));
    await tester.pumpAndSettle();
    expect(paths.last, '/api/vehicles/v1/stats?months=36');
  });
}
