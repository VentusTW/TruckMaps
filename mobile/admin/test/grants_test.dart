import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_admin/src/company_dialog.dart';
import 'package:truckmaps_admin/src/grants.dart';
import 'package:truckmaps_admin/src/home.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> grant(String state, Duration left) => {
      'id': 'g1',
      'company_id': 'c1',
      'company_name': 'Trans-Miś',
      'scopes': ['company'],
      'note': 'Poprawa NIP',
      'state': state,
      'expires_at': state == 'pending' ? null : DateTime.now().toUtc().add(left).toIso8601String(),
      'active': state == 'active',
    };

void main() {
  late List<Map<String, dynamic>> grants;
  late List<(String, String, Object?)> requests;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          requests.add((request.method, request.url.path, request.body.isEmpty ? null : jsonDecode(request.body)));
          switch ((request.method, request.url.path)) {
            case ('GET', '/api/admin/me'):
              return json({'subject': 's', 'name': 'Anna', 'role': 'full'});
            case ('GET', '/api/admin/grants'):
              return json(grants);
            case ('GET', '/api/admin/accounts'):
              return json({'total': 0, 'items': []});
            case ('GET', '/api/admin/companies/c1'):
              return json({'id': 'c1', 'name': 'Trans-Miś', 'tax_id': null, 'cost_currency': 'PLN', 'grants': []});
            case ('POST', '/api/admin/companies/c1/access-requests'):
              grants = [grant('pending', Duration.zero)];
              return json(grants.first, 201);
            case ('POST', '/api/admin/grants/g1/extension-request'):
            case ('POST', '/api/admin/grants/g1/close'):
              if (request.url.path.endsWith('close')) grants = [];
              return http.Response('', 204);
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
    grants = [];
    requests = [];
  });

  test('ostrzeżenia 10 i 5 minut przed końcem, potem już odliczanie', () {
    expect(warningFor(const Duration(minutes: 30)), isNull);
    expect(warningFor(const Duration(minutes: 9)), const Duration(minutes: 10));
    expect(warningFor(const Duration(minutes: 4)), const Duration(minutes: 5));
    expect(warningFor(const Duration(seconds: 100)), isNull);
    expect(clock(const Duration(seconds: 95)), '1:35');
  });

  testWidgets('prośba o dostęp z okna firmy', (tester) async {
    await tester.pumpWidget(localized(Scaffold(
      body: CompanyDialog(api: api(), companyId: 'c1', canRequest: true),
    )));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Poproś o dostęp'));
    await tester.pumpAndSettle();
    final send = find.widgetWithText(FilledButton, 'Wyślij prośbę');
    expect(tester.widget<FilledButton>(send).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Poprawa NIP');
    await tester.pump();
    await tester.tap(send);
    await tester.pumpAndSettle();

    expect(requests.singleWhere((r) => r.$1 == 'POST').$3, {
      'scopes': ['company'],
      'note': 'Poprawa NIP',
    });
  });

  testWidgets('aktywny dostęp: pasek u góry i ostrzeżenie 5 minut przed końcem', (tester) async {
    bigScreen(tester);
    grants = [grant('active', const Duration(minutes: 4, seconds: 30))];
    await tester.pumpWidget(localized(AdminHome(api: api(), onLogout: () {})));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dostęp do zmian w firmie Trans-Miś do'), findsOneWidget);
    expect(find.text('Kończy się czas dostępu'), findsOneWidget);
    expect(find.textContaining('skończy się za 5 minut'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Poproś o przedłużenie').last);
    await tester.pumpAndSettle();
    expect(requests.singleWhere((r) => r.$2.endsWith('extension-request')).$3, {'minutes': 30});
    expect(find.text('Prośba o przedłużenie wysłana do właściciela.'), findsOneWidget);

    // To samo ostrzeżenie nie wraca co sekundę.
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Kończy się czas dostępu'), findsNothing);
  });

  testWidgets('od 2 minut do końca – odliczanie na pasku, zamknięcie dostępu', (tester) async {
    bigScreen(tester);
    grants = [grant('active', const Duration(seconds: 90))];
    await tester.pumpWidget(localized(AdminHome(api: api(), onLogout: () {})));
    await tester.pumpAndSettle();

    expect(find.textContaining(RegExp(r'Dostęp do firmy Trans-Miś kończy się za 1:[0-2]\d')), findsOneWidget);
    expect(find.text('Kończy się czas dostępu'), findsNothing);

    await tester.tap(find.text('Zakończ i zamknij dostęp'));
    await tester.pumpAndSettle();
    expect(requests.any((r) => r.$2 == '/api/admin/grants/g1/close'), isTrue);
    expect(find.textContaining('kończy się za'), findsNothing);
  });

  testWidgets('prośba czeka na zgodę – pasek bez przedłużania', (tester) async {
    bigScreen(tester);
    grants = [grant('pending', Duration.zero)];
    await tester.pumpWidget(localized(AdminHome(api: api(), onLogout: () {})));
    await tester.pumpAndSettle();

    expect(find.text('Prośba o dostęp do firmy Trans-Miś czeka na zgodę właściciela.'), findsOneWidget);
    expect(find.text('Poproś o przedłużenie'), findsNothing);
    expect(find.text('Wycofaj prośbę'), findsOneWidget);
  });
}
