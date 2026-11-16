import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/service/fuel_cards.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> summary(int count) => {
      'since': '2026-08-16T00:00:00Z',
      'count': count,
      'liters': count == 0 ? 0 : 912.75,
      'amount': count == 0 ? <String, dynamic>{} : {'PLN': 2524.56, 'EUR': 1050.4},
      'vehicles': count == 0
          ? <Object>[]
          : [
              {
                'vehicle_id': 'v1',
                'plate': 'WX 12345',
                'count': 3,
                'liters': 912.75,
                'adblue_liters': 50,
                'amount': {'PLN': 2524.56, 'EUR': 1050.4},
                'last': '2026-10-11T14:05:00Z',
              },
              {
                'vehicle_id': null,
                'plate': null,
                'count': 1,
                'liters': 100,
                'adblue_liters': 0,
                'amount': {'PLN': 650},
                'last': '2026-10-06T07:00:00Z',
              },
            ],
    };

void main() {
  testWidgets('TCO: skrót tankowań, tabela pojazdów ze spalaniem, import wyciągu CSV', (tester) async {
    tester.view.physicalSize = const Size(1400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = <http.Request>[];
    var imported = false;
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async {
        sent.add(r);
        return switch (r.url.path) {
          '/api/companies/c1/fuel-cards/summary' => json(summary(imported ? 4 : 0)),
          '/api/companies/c1/fuel-cards/import' => () {
              imported = true;
              return json({
                'imported': 4,
                'duplicates': 1,
                'skipped': 2,
                'unmatched': ['KR 99999'],
                'liters': 1012.75,
                'amount': {'PLN': 3174.56},
                'columns': <String, String>{},
              });
            }(),
          _ => json(<String, dynamic>{}),
        };
      }),
    );
    await tester.pumpWidget(localized(Scaffold(
      body: FuelCardsSummary(
        api: api,
        companyId: 'c1',
        months: 3,
        stats: const {
          'v1': {'distance_km': 3000}
        },
        picker: (label) async => ('orlen.csv', utf8.encode('Data;Ilość;Kwota\n')),
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Wczytaj wyciąg CSV'), findsOneWidget);
    expect(sent.single.url.queryParameters['months'], '3');

    await tester.tap(find.byKey(const Key('fuel-cards')));
    await tester.pumpAndSettle();
    expect(find.text('Karty paliwowe – tankowania'), findsOneWidget);
    expect(find.textContaining('Brak tankowań'), findsOneWidget);

    await tester.tap(find.byKey(const Key('fuel-import')));
    await tester.pumpAndSettle();
    final post = sent.firstWhere((r) => r.method == 'POST');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['name'], 'orlen.csv');
    expect(utf8.decode(base64Decode('${body['data']}')), 'Data;Ilość;Kwota\n');
    expect(
        find.text('Wczytano tankowania: 4 (już były: 1, pominięte wiersze: 2)\n'
            'Bez pojazdu w firmie (zapisane przy firmie): KR 99999'),
        findsOneWidget);
    expect(find.text('WX 12345'), findsOneWidget);
    expect(find.text('Bez pojazdu'), findsOneWidget);
    expect(find.text('30,4'), findsOneWidget); // 912,75 l / 3000 km
    expect(find.textContaining('050,40 EUR'), findsOneWidget);

    await tester.tap(find.text('Zamknij'));
    await tester.pumpAndSettle();
    expect(find.textContaining('4 tankowań • 913 l • 2'), findsOneWidget);
  });
}
