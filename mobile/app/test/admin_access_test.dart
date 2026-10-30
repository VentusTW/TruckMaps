import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/company/admin_access_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  late List<Map<String, dynamic>> grants;
  late List<(String, String, Object?)> requests;
  const path = '/api/companies/c1/admin-access';

  Map<String, dynamic> grant(String id, {bool active = true}) => {
        'id': id,
        'scopes': ['company', 'bases'],
        'note': 'zgłoszenie 12',
        'granted_by': 'owner',
        'granted_at': '2026-10-30T10:00:00Z',
        'expires_at': '2026-11-02T10:00:00Z',
        'revoked_at': active ? null : '2026-10-31T10:00:00Z',
        'active': active,
      };

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          requests.add((request.method, request.url.path, body));
          switch ((request.method, request.url.path)) {
            case ('GET', path):
              return json({
                'grants': grants,
                'changes': [
                  {
                    'at': '2026-10-30T11:00:00Z',
                    'admin': 'Anna',
                    'action': 'company.update',
                    'changes': {
                      'name': ['Trans-Miś', 'Trans-Miś Sp. z o.o.'],
                      'tax_id': [null, 'PL123'],
                    },
                  },
                ],
              });
            case ('POST', path):
              grants = [grant('g2'), ...grants];
              return json(grants.first, 201);
            case ('DELETE', '$path/g1'):
              grants = [grant('g1', active: false)];
              return http.Response('', 204);
          }
          return json({'detail': 'nieznane'}, 404);
        }),
      );

  setUp(() {
    grants = [grant('g1')];
    requests = [];
  });

  testWidgets('pokazuje dostęp i dziennik zmian administratora', (tester) async {
    await tester.pumpWidget(localized(AdminAccessScreen(api: api(), companyId: 'c1')));
    await tester.pumpAndSettle();

    expect(find.text('Dane firmy i stawki, Bazy'), findsOneWidget);
    expect(find.textContaining('aktywny do'), findsOneWidget);
    expect(find.text('Zmiana danych firmy · Anna'), findsOneWidget);
    expect(find.textContaining('Nazwa firmy: Trans-Miś → Trans-Miś Sp. z o.o.'), findsOneWidget);
    expect(find.textContaining('NIP / VAT: — → PL123'), findsOneWidget);
  });

  testWidgets('właściciel udziela dostępu z zakresem i terminem', (tester) async {
    await tester.pumpWidget(localized(AdminAccessScreen(api: api(), companyId: 'c1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bazy'));
    await tester.tap(find.text('1 dzień'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('7 dni').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zgłoszenie 12');
    await tester.tap(find.widgetWithText(FilledButton, 'Udziel dostępu'));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r.$1 == 'POST').single.$3, {
      'scopes': ['company', 'bases'],
      'days': 7,
      'note': 'zgłoszenie 12',
    });
    expect(find.textContaining('aktywny do'), findsNWidgets(2));
  });

  testWidgets('cofnięcie dostępu po potwierdzeniu', (tester) async {
    await tester.pumpWidget(localized(AdminAccessScreen(api: api(), companyId: 'c1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Cofnij dostęp'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Cofnij dostęp'));
    await tester.pumpAndSettle();

    expect(requests.any((r) => r.$1 == 'DELETE' && r.$2 == '$path/g1'), isTrue);
    expect(find.textContaining('cofnięty'), findsOneWidget);
    expect(find.byTooltip('Cofnij dostęp'), findsNothing);
  });
}
