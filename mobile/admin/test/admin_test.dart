import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_admin/src/home.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> company(int i) => {
      'id': 'c$i',
      'name': 'Firma $i',
      'tax_id': i == 0 ? 'PL123' : null,
      'cost_per_km': null,
      'cost_per_hour': null,
      'cost_currency': 'PLN',
      'created_at': '2026-10-30T10:00:00Z',
      'members': 2,
      'access_granted': i == 0,
    };

void main() {
  late List<Uri> requests;
  late http.Response me;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          requests.add(request.url);
          final query = request.url.queryParameters;
          switch (request.url.path) {
            case '/api/admin/me':
              return me;
            case '/api/admin/accounts':
              return json({
                'total': 1,
                'items': [
                  {
                    'subject': 's1',
                    'display_name': 'Anna',
                    'language': 'pl',
                    'currency': null,
                    'onboarded': true,
                    'companies': 1
                  },
                ],
              });
            case '/api/admin/companies':
              final offset = int.parse(query['offset']!);
              final all = [for (var i = 0; i < 60; i++) company(i)];
              final found = query['q'] == null ? all : all.where((c) => '${c['name']}'.contains(query['q']!)).toList();
              return json({'total': found.length, 'items': found.skip(offset).take(50).toList()});
            case '/api/admin/companies/c0':
              return json({
                ...company(0),
                'grants': [
                  {
                    'id': 'g1',
                    'scopes': ['company'],
                    'note': 'zgłoszenie 12',
                    'expires_at': '2026-11-02T10:00:00Z',
                    'active': true,
                  },
                ],
              });
            case '/api/admin/members':
              return json({'total': 0, 'items': []});
          }
          return json({'detail': 'nieznane'}, 404);
        }),
      );

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  setUp(() {
    requests = [];
    me = json({'subject': 's-admin', 'name': 'Anna', 'role': 'support'});
  });

  testWidgets('konto bez roli administratora widzi komunikat serwera', (tester) async {
    me = json({'detail': 'To konto nie ma dostępu do programu administracyjnego.'}, 403);
    var loggedOut = false;
    await tester.pumpWidget(localized(AdminHome(api: api(), onLogout: () => loggedOut = true)));
    await tester.pumpAndSettle();

    expect(find.text('To konto nie ma dostępu do programu administracyjnego.'), findsOneWidget);
    await tester.tap(find.text('Wyloguj'));
    expect(loggedOut, isTrue);
  });

  testWidgets('listy z rolą, wyszukiwaniem, filtrem i stronami', (tester) async {
    bigScreen(tester);
    await tester.pumpWidget(localized(AdminHome(api: api(), onLogout: () {})));
    await tester.pumpAndSettle();

    expect(find.text('Anna · wsparcie – tylko odczyt'), findsOneWidget);
    expect(find.text('Anna'), findsOneWidget);
    expect(find.text('tak'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.business_outlined));
    await tester.pumpAndSettle();
    expect(find.text('1–50 z 60'), findsOneWidget);
    await tester.tap(find.byTooltip('Następna strona'));
    await tester.pumpAndSettle();
    expect(find.text('51–60 z 60'), findsOneWidget);
    expect(requests.last.queryParameters['offset'], '50');

    await tester.enterText(find.byType(TextField), 'Firma 5');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters, containsPair('q', 'Firma 5'));
    expect(requests.last.queryParameters['offset'], '0');
    expect(find.text('1–11 z 11'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.group_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('wszystkie'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('właściciel').last);
    await tester.pumpAndSettle();
    expect(requests.last.path, '/api/admin/members');
    expect(requests.last.queryParameters['role'], 'owner');
    expect(find.text('Brak wyników.'), findsOneWidget);
  });

  testWidgets('firma pokazuje dostęp udzielony przez właściciela', (tester) async {
    bigScreen(tester);
    await tester.pumpWidget(localized(AdminHome(api: api(), onLogout: () {})));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.business_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('PL123'));
    await tester.pumpAndSettle();
    expect(find.textContaining('dane firmy i stawki · aktywny do'), findsOneWidget);
    expect(find.text('zgłoszenie 12'), findsOneWidget);
  });
}
