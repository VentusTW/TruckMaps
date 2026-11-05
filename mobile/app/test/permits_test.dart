import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/vehicles/permits_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  testWidgets('zezwolenia: lista z opisem i nowe zezwolenie na cały kraj dla pojazdu', (tester) async {
    tester.view.physicalSize = const Size(1000, 2200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = <Object?>[];
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        sent.add(jsonDecode(request.body));
        return json({'id': 'p2'}, 201);
      }
      if (request.url.path == '/api/vehicles') {
        return json([
          {'id': 'v1', 'name': 'MAN TGX', 'plate': 'KTA 1', 'kind': 'tractor', 'company_id': 'c1', 'can_edit': true},
        ]);
      }
      return json([
        {
          'id': 'p1', 'number': 'UM/12/2026', 'issuer': 'Urząd Miasta', 'valid_from': '2026-01-01',
          'valid_to': '2030-12-31', 'max_weight_t': 40, 'hgv_ban': true, 'scope': 'circle',
          'place': 'Tarnów', 'radius_km': 5, 'can_edit': true,
        },
      ]);
    });
    final api = CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client);
    await tester.pumpWidget(localized(PermitsScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('UM/12/2026 · Urząd Miasta'), findsOneWidget);
    expect(find.textContaining('Tarnów (do 5 km) · masa do 40 t, Wjazd mimo zakazu'), findsOneWidget);

    await tester.tap(find.text('Dodaj zezwolenie'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Numer zezwolenia'), 'GDDKiA/7');
    await tester.enterText(find.widgetWithText(TextFormField, 'Masa / DMC do'), '60');
    await tester.tap(find.text('MAN TGX · KTA 1'));
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();
    final body = sent.single as Map;
    expect((body['number'], body['scope'], body['country'], body['max_weight_t']), ('GDDKiA/7', 'country', 'PL', 60.0));
    expect(body['vehicle_ids'], ['v1']);
    expect(body['company_id'], 'c1');
  });
}
