import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/planner/place_field.dart';

void main() {
  testWidgets('po wybraniu podpowiedzi pole nie szuka ponownie', (tester) async {
    final queries = <String>[];
    final client = MockClient((request) async {
      queries.add(request.url.queryParameters['q']!);
      return http.Response.bytes(
          utf8.encode(jsonEncode([{'label': 'Tarnów, Rynek', 'lat': 50.0, 'lon': 21.0}])), 200);
    });
    final controller = TextEditingController();
    Place? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PlaceField(
          api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
          label: 'Skąd',
          icon: Icons.trip_origin,
          controller: controller,
          onSelected: (place) => selected = place,
        ),
      ),
    ));

    await tester.enterText(find.byType(TextField), 'Tarn');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tarnów, Rynek'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(selected?.label, 'Tarnów, Rynek');
    expect(controller.text, 'Tarnów, Rynek');
    expect(queries, ['Tarn']);
  });
}
