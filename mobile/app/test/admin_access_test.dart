import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/company/admin_access_screen.dart';
import 'package:truckmaps_app/src/inbox_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

String inMinutes(int minutes) => DateTime.now().toUtc().add(Duration(minutes: minutes)).toIso8601String();

Map<String, dynamic> grant(String id, {String state = 'active', String? requestedBy}) => {
      'id': id,
      'company_id': 'c1',
      'scopes': ['company', 'bases'],
      'note': 'zgłoszenie 12',
      'state': state,
      'requested_by': requestedBy,
      'requested_at': null,
      'granted_at': '2026-10-30T10:00:00Z',
      'expires_at': state == 'pending' ? null : inMinutes(45),
      'revoked_at': state == 'closed' ? '2026-10-30T10:30:00Z' : null,
      'active': state == 'active',
    };

void main() {
  late List<Map<String, dynamic>> grants;
  late List<Map<String, dynamic>> messages;
  late List<(String, String, Object?)> requests;
  const path = '/api/companies/c1/admin-access';

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
              grants = [grant('g1', state: 'closed')];
              return http.Response('', 204);
            case ('POST', '$path/g3/accept'):
              grants = [grant('g3', requestedBy: 'Anna')];
              for (final m in messages) {
                m['grant'] = grants.first;
              }
              return json(grants.first);
            case ('GET', '/api/me/messages'):
              return json({'unread': messages.where((m) => m['read'] != true).length, 'items': messages});
            case ('POST', final p) when p.startsWith('/api/me/messages/'):
              return http.Response('', 204);
          }
          return json({'detail': 'nieznane'}, 404);
        }),
      );

  setUp(() {
    grants = [grant('g1')];
    messages = [];
    requests = [];
  });

  testWidgets('pokazuje dostęp z pozostałym czasem i dziennik zmian administratora', (tester) async {
    await tester.pumpWidget(localized(AdminAccessScreen(api: api(), companyId: 'c1')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Dane firmy i stawki, Bazy'), findsOneWidget);
    expect(find.textContaining('aktywny do'), findsOneWidget);
    expect(find.textContaining('zostało 45 min'), findsOneWidget);
    expect(find.text('Zmiana danych firmy · Anna'), findsOneWidget);
    expect(find.textContaining('Nazwa firmy: Trans-Miś → Trans-Miś Sp. z o.o.'), findsOneWidget);
    expect(find.textContaining('NIP / VAT: — → PL123'), findsOneWidget);
  });

  testWidgets('właściciel udziela dostępu z zakresem i czasem', (tester) async {
    await tester.pumpWidget(localized(AdminAccessScreen(api: api(), companyId: 'c1')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bazy'));
    await tester.tap(find.text('1 godz.'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 godz.').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'zgłoszenie 12');
    await tester.tap(find.widgetWithText(FilledButton, 'Udziel dostępu'));
    await tester.pumpAndSettle();

    expect(requests.where((r) => r.$1 == 'POST').single.$3, {
      'scopes': ['company', 'bases'],
      'minutes': 120,
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

  testWidgets('prośba administratora w skrzynce: wyróżniona, zgoda na godzinę', (tester) async {
    grants = [grant('g3', state: 'pending', requestedBy: 'Anna')];
    messages = [
      {
        'id': 'm1',
        'kind': 'admin_access_request',
        'sender_name': 'Anna',
        'company_id': 'c1',
        'grant_id': 'g3',
        'grant': grants.first,
        'data': {
          'scopes': ['company'],
          'note': 'Poprawa NIP',
        },
        'created_at': '2026-10-30T10:00:00Z',
        'read': false,
      },
      {
        'id': 'm0',
        'kind': 'admin_access_closed',
        'sender_name': 'Anna',
        'company_id': 'c1',
        'grant_id': 'g0',
        'grant': null,
        'data': <String, dynamic>{},
        'created_at': '2026-10-29T10:00:00Z',
        'read': false,
      },
    ];
    var changed = 0;
    await tester.pumpWidget(localized(InboxScreen(api: api(), onChanged: () => changed++)));
    await tester.pumpAndSettle();

    expect(find.text('Anna prosi o dostęp do zmian'), findsOneWidget);
    expect(find.textContaining('„Poprawa NIP”'), findsOneWidget);
    expect(find.text('Anna: zmiany zakończone, dostęp zamknięty'), findsOneWidget);
    // Informacja bez decyzji – przeczytana od razu; prośba czeka na decyzję.
    expect(requests.where((r) => r.$2 == '/api/me/messages/m0/read'), hasLength(1));
    expect(requests.where((r) => r.$2 == '/api/me/messages/m1/read'), isEmpty);
    final card = tester.widget<Card>(
        find.ancestor(of: find.text('Anna prosi o dostęp do zmian'), matching: find.byType(Card)));
    expect(card.color, isNotNull);

    await tester.tap(find.text('Zgoda (1 godz.)'));
    await tester.pumpAndSettle();
    expect(requests.singleWhere((r) => r.$2 == '$path/g3/accept').$3, {'minutes': 60});
    expect(find.text('Zgoda (1 godz.)'), findsNothing);
    expect(find.textContaining('aktywny do'), findsOneWidget);
    expect(changed, greaterThan(0));
  });

  testWidgets('prośba czekająca na ekranie dostępu: zgoda albo odmowa', (tester) async {
    grants = [grant('g3', state: 'pending', requestedBy: 'Anna')];
    await tester.pumpWidget(localized(AdminAccessScreen(api: api(), companyId: 'c1')));
    await tester.pumpAndSettle();

    expect(find.textContaining('prosi: Anna · czeka na Twoją zgodę'), findsOneWidget);
    await tester.tap(find.byTooltip('Zgoda (1 godz.)'));
    await tester.pumpAndSettle();
    expect(find.textContaining('aktywny do'), findsOneWidget);
  });
}
