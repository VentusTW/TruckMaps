import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/planner/route.dart';
import 'package:truckmaps_app/src/reports/report_sheet.dart';

import 'localized.dart';

Map<String, dynamic> saved(Map body) => {
      'id': 'r1',
      'kind': body['kind'],
      'label': 'Rampa',
      'message': body['note'] == null ? 'Rampa' : 'Godziny przyjęć: ${body['note']}',
      'lat': body['lat'],
      'lon': body['lon'],
      'score': 1,
      'mine': true,
    };

void main() {
  late List<Map> sent;
  late CoreApi api;

  setUp(() {
    sent = [];
    api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        sent.add(body);
        return http.Response.bytes(utf8.encode(jsonEncode(saved(body))), 201);
      }),
    );
  });

  /// Otwiera okno zgłoszenia; zwraca funkcję, która podaje wynik po jego zamknięciu.
  Future<DriverReport? Function()> open(WidgetTester tester) async {
    DriverReport? result;
    var done = false;
    await tester.pumpWidget(localized(Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            result = await showReportSheet(context, api, const LatLng(50.01, 21.02), deliveryFirst: true);
            done = true;
          },
          child: const Text('otwórz'),
        ),
      ),
    )));
    await tester.tap(find.text('otwórz'));
    await tester.pumpAndSettle();
    return () {
      expect(done, isTrue);
      return result;
    };
  }

  testWidgets('rampa jednym dotknięciem', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('Rampa'));
    await tester.pumpAndSettle();

    expect(sent, [
      {'kind': 'ramp', 'lat': 50.01, 'lon': 21.02},
    ]);
    expect(result()?.kind, 'ramp');
  });

  testWidgets('godziny przyjęć – najpierw tekst', (tester) async {
    final result = await open(tester);

    await tester.tap(find.text('Godziny przyjęć'));
    await tester.pumpAndSettle();
    expect(sent, isEmpty);
    await tester.enterText(find.byType(TextField), 'pn–pt 6–14');
    await tester.tap(find.widgetWithText(FilledButton, 'Zgłoś'));
    await tester.pumpAndSettle();

    expect(sent.single['note'], 'pn–pt 6–14');
    expect(result()?.message, 'Godziny przyjęć: pn–pt 6–14');
  });

  test('punkty dostawy i zgłoszenia na trasie z odpowiedzi planera', () {
    final result = RouteResult.fromJson({
      'distance_km': 1.0,
      'duration_min': 2.0,
      'geometry': [[21.0, 50.0], [21.02, 50.01]],
      'analysis': null,
      'destination_points': [
        {'id': 'a', 'kind': 'ramp', 'label': 'Rampa', 'message': 'Rampa', 'lat': 50.01, 'lon': 21.02, 'distance_m': 39},
      ],
      'driver_reports': [
        {'id': 'b', 'kind': 'road_closed', 'label': 'Droga zamknięta', 'message': 'Droga zamknięta', 'lat': 50.0, 'lon': 21.01, 'km': 0.7},
      ],
    });

    expect(result.destinationPoints.single.distanceM, 39);
    expect(result.driverReports.single.km, 0.7);
  });
}
