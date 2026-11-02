import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_load/module_load.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  late List<(String, String, Object?)> requests;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          requests.add((request.method, request.url.path, body));
          if (request.url.path == '/api/vehicles') {
            return json([
              {'id': 'c1', 'name': 'Ciągnik', 'kind': 'tractor'},
              {'id': 'n1', 'name': 'Naczepa', 'plate': 'KTA 1', 'kind': 'semitrailer'},
            ]);
          }
          if (request.url.path == '/api/m/load/plan') {
            return json({
              'deck_length_m': 13.6,
              'deck_width_m': 2.48,
              'ldm': 13.64,
              'used_length_m': 13.2,
              'weight_kg': 16500,
              'payload_kg': 32000,
              'fits': true,
              'placed': [
                {'item': 0, 'x_m': 0, 'y_m': 0, 'length_m': 1.2, 'width_m': 0.8, 'weight_kg': 500, 'stop': 1},
              ],
              'unplaced': 0,
              'rows': <Object>[],
              'straps': 11,
              'cog_m': 6.6,
              'warnings': ['Uwaga testowa'],
              'estimated': true,
            });
          }
          return json(null, 404);
        }),
      );

  setUp(() => requests = []);

  testWidgets('moduł: nazwa w języku', (tester) async {
    expect(LoadModule().name(const Locale('pl')), 'Plan załadunku');
    expect(LoadModule().name(const Locale('en')), 'Load plan');
  });

  testWidgets('plan: pojazd z przestrzenią ładunkową, pozycja, wynik z ostrzeżeniem', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LoadPlanScreen(api: api()))));
    await tester.pumpAndSettle();

    expect(find.text('Naczepa · KTA 1'), findsOneWidget); // ciągnik bez przestrzeni – pominięty
    await tester.enterText(find.widgetWithText(TextFormField, 'Pieces'), '33');
    await tester.enterText(find.widgetWithText(TextFormField, 'Weight each'), '500');
    await tester.tap(find.text('Calculate plan'));
    await tester.pumpAndSettle();

    final sent = requests.singleWhere((r) => r.$2 == '/api/m/load/plan').$3 as Map;
    expect(sent['vehicle_id'], 'n1');
    expect(sent['items'], [
      {'kind': 'euro', 'count': 33, 'weight_kg': 500.0, 'stack': 1, 'stop': 1},
    ]);
    expect(find.text('Fits'), findsOneWidget);
    expect(find.text('13.64 LDM · 13.2 of 13.6 m used'), findsOneWidget);
    expect(find.text('⚠ Uwaga testowa'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });
}
