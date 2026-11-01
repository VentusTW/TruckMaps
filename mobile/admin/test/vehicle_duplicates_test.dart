import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_admin/src/vehicle_duplicates.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  testWidgets('duble po VIN: scalenie pozostałych w wybrany pojazd, przypisanie członkowi', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final requests = <(String, String, Object?)>[];
    var merged = false;
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        final body = request.body.isEmpty ? null : jsonDecode(request.body);
        requests.add((request.method, request.url.path, body));
        if (request.method == 'GET') {
          return json(merged
              ? []
              : [
                  {
                    'vin': 'WMA06XZZ1KM123456',
                    'vehicles': [
                      {'id': 'a', 'name': 'MAN TGX', 'plate': null, 'company_id': 'c1', 'company_name': 'Trans'},
                      {'id': 'b', 'name': 'MAN', 'plate': 'WGM 1', 'company_id': 'c1', 'company_name': 'Trans'},
                    ],
                  }
                ]);
        }
        if (request.url.path.endsWith('/merge')) merged = true;
        return json({});
      }),
    );
    await tester.pumpWidget(localized(VehicleDuplicatesScreen(api: api)));
    await tester.pumpAndSettle();
    expect(find.text('VIN WMA06XZZ1KM123456'), findsOneWidget);

    await tester.tap(find.text('MAN · WGM 1')); // zostaje pojazd z tablicą
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Przypisz').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Do członka firmy'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'jan');
    await tester.tap(find.widgetWithText(FilledButton, 'Przypisz'));
    await tester.pumpAndSettle();
    final put = requests.firstWhere((r) => r.$1 == 'PUT');
    expect(put.$2, '/api/admin/vehicles/a/assign');
    expect(put.$3, {'company_id': null, 'owner_subject': 'jan'});

    await tester.tap(find.text('Scal w wybrany'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Scal'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.$1 == 'POST').single.$3, {'keep_id': 'b', 'merge_id': 'a'});
    expect(find.text('Brak pojazdów z tym samym VIN.'), findsOneWidget);
  });
}
