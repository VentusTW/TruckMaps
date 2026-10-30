import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/account/account_screen.dart';
import 'package:truckmaps_app/src/auth.dart';
import 'package:truckmaps_app/src/company/members_screen.dart';
import 'package:truckmaps_app/src/home.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const company = {
  'id': 'c1',
  'name': 'Trans-Miś',
  'tax_id': '1234567890',
  'cost_per_km': 4.5,
  'cost_per_hour': null,
  'cost_currency': 'PLN',
  'role': 'owner',
};

void main() {
  late Map<String, dynamic> settings;
  late List<Map<String, dynamic>> companies;
  late List<Map<String, dynamic>> members;
  late List<Map<String, dynamic>> invites;
  late List<(String, String, Map?)> requests;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : (jsonDecode(request.body) as Map).cast<String, dynamic>();
          final path = request.url.path;
          requests.add((request.method, path, body));
          switch ((request.method, path)) {
            case ('GET', '/api/me/settings'):
              return json(settings);
            case ('PUT', '/api/me/settings'):
              settings = {...settings, ...body!};
              return json(settings);
            case ('GET', '/api/companies'):
              return json(companies);
            case ('POST', '/api/companies'):
              companies = [
                {...company, ...body!}
              ];
              return json(companies.first, 201);
            case ('GET', '/api/companies/c1'):
              return json({...company, 'members': members});
            case ('GET', '/api/companies/c1/invites'):
              return json(invites);
            case ('POST', '/api/companies/c1/invites'):
              final invite = {...body!, 'code': 'ABCD2345', 'expires_at': '2026-11-06T10:00:00Z'};
              invites = [...invites, invite];
              return json(invite, 201);
            case ('DELETE', '/api/companies/c1/invites/ABCD2345'):
              invites = [];
              return http.Response('', 204);
            case ('PUT', '/api/companies/c1/members/m2'):
              members = [members[0], {...members[1], ...body!}];
              return json({...company, 'members': members});
            case ('GET', '/api/currencies'):
              return json({
                'currencies': [{'code': 'PLN', 'name': 'złoty'}, {'code': 'EUR', 'name': 'euro'}],
                'rates_day': '2026-10-29',
                'per_eur': {'PLN': 4.25},
              });
            case ('GET', '/api/vehicles') || ('GET', '/api/bases') || ('GET', '/api/me/modules'):
              return json([]);
          }
          return json(null, 404);
        }),
      );

  void bigScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(1800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  Future<void> home(WidgetTester tester) async {
    bigScreen(tester);
    await tester.pumpWidget(localized(HomeScreen(
      session: Session(api: api(), userName: 'Anna'),
      registry: ModuleRegistry(const []),
      onLogout: () {},
    )));
    await tester.pump(const Duration(seconds: 1));
  }

  setUp(() {
    mapTiles = () => const SizedBox();
    settings = {'currency': null, 'display_name': 'Anna', 'language': null, 'onboarded': true};
    companies = [];
    members = [
      {'id': 'm1', 'display_name': 'Anna', 'role': 'owner', 'joined_at': '2026-10-01T10:00:00Z', 'is_me': true},
      {'id': 'm2', 'display_name': 'Jan', 'role': 'driver', 'joined_at': '2026-10-02T10:00:00Z', 'is_me': false},
    ];
    invites = [];
    requests = [];
  });

  testWidgets('pierwsze logowanie: „sam, bez firmy” zapisuje wybór i otwiera aplikację', (tester) async {
    settings = {...settings, 'onboarded': false};
    await home(tester);

    expect(find.text('Jak będziesz korzystać z aplikacji?'), findsOneWidget);
    await tester.tap(find.text('Sam, bez firmy'));
    await tester.pump(const Duration(seconds: 1));

    expect(requests.where((r) => r.$1 == 'PUT').single.$3, {'onboarded': true});
    expect(find.text('Konto'), findsWidgets);
    expect(find.text('Firma'), findsNothing);
  });

  testWidgets('pierwsze logowanie: „mam firmę” zakłada firmę z NIP i walutą', (tester) async {
    settings = {...settings, 'onboarded': false};
    await home(tester);

    await tester.tap(find.text('Mam firmę'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Załóż firmę'));
    await tester.pumpAndSettle();
    expect(find.text('Wpisz nazwę (co najmniej 2 znaki).'), findsOneWidget);

    await tester.enterText(find.widgetWithText(TextFormField, 'Nazwa firmy'), 'Trans-Miś');
    await tester.enterText(find.widgetWithText(TextFormField, 'NIP / VAT'), 'PL1234567890');
    await tester.tap(find.text('Transport osób'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'Waluta firmy'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PLN').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Załóż firmę'));
    await tester.pump(const Duration(seconds: 1));

    final sent = requests.singleWhere((r) => r.$1 == 'POST' && r.$2 == '/api/companies').$3!;
    expect(sent, {'name': 'Trans-Miś', 'tax_id': 'PL1234567890', 'cost_currency': 'PLN', 'kind': 'passenger'});
    expect(find.text('Członkowie'), findsOneWidget);
  });

  testWidgets('menu zależy od roli: kierowca widzi firmę bez członków', (tester) async {
    companies = [
      {...company, 'role': 'driver'}
    ];
    await home(tester);

    expect(find.text('Firma'), findsOneWidget);
    expect(find.text('Członkowie'), findsNothing);
    await tester.tap(find.text('Firma'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Twoja rola: Kierowca. Dane firmy zmienia właściciel.'), findsOneWidget);
    expect(find.text('Opuść firmę'), findsOneWidget);
    expect(find.text('Dodaj bazę'), findsNothing);
  });

  testWidgets('właściciel: zmiana roli, ostatni właściciel zostaje, zaproszenie z kodem', (tester) async {
    bigScreen(tester);
    await tester.pumpWidget(localized(MembersScreen(api: api(), companyId: 'c1', role: 'owner')));
    await tester.pumpAndSettle();

    expect(find.text('Anna (ty)'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zmień rolę na: Kierowca'));
    await tester.pumpAndSettle();
    expect(find.text('Firma musi mieć właściciela: najpierw przekaż tę rolę komuś innemu.'), findsOneWidget);
    expect(requests.where((r) => r.$1 == 'PUT'), isEmpty);

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Zmień rolę na: Dyspozytor'));
    await tester.pumpAndSettle();
    expect(requests.singleWhere((r) => r.$1 == 'PUT').$3, {'role': 'dispatcher'});
    expect(find.text('Dyspozytor'), findsOneWidget);

    await tester.tap(find.text('Zaproś'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Notatka'), 'Marek');
    await tester.tap(find.text('Utwórz kod'));
    await tester.pumpAndSettle();
    expect(requests.singleWhere((r) => r.$1 == 'POST').$3, {'role': 'driver', 'note': 'Marek'});
    expect(find.text('ABCD2345'), findsWidgets);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Anuluj zaproszenie'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Anuluj zaproszenie'));
    await tester.pumpAndSettle();
    expect(requests.any((r) => r.$1 == 'DELETE'), isTrue);
    expect(find.text('Brak aktywnych zaproszeń.'), findsOneWidget);
  });

  testWidgets('dyspozytor zaprasza tylko kierowców i nie zmienia ról', (tester) async {
    bigScreen(tester);
    await tester.pumpWidget(localized(MembersScreen(api: api(), companyId: 'c1', role: 'dispatcher')));
    await tester.pumpAndSettle();

    expect(find.byType(PopupMenuButton<String>), findsNothing);
    await tester.tap(find.text('Zaproś'));
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    await tester.tap(find.text('Utwórz kod'));
    await tester.pumpAndSettle();
    expect(requests.singleWhere((r) => r.$1 == 'POST').$3, {'role': 'driver', 'note': ''});
  });

  testWidgets('konto: imię, język i waluta zapisywane na serwerze', (tester) async {
    bigScreen(tester);
    final languages = <String?>[];
    var changes = 0;
    await tester.pumpWidget(localized(Scaffold(
      body: AccountScreen(
        api: api(),
        settings: settings,
        onChanged: () => changes++,
        onLanguage: languages.add,
        onLogout: () {},
      ),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextFormField, 'Imię wyświetlane'), 'Anna K.');
    await tester.tap(find.text('Zapisz'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'Język'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(DropdownButtonFormField<String?>, 'Waluta kosztów'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EUR').last);
    await tester.pumpAndSettle();

    expect([for (final r in requests.where((r) => r.$1 == 'PUT')) r.$3], [
      {'display_name': 'Anna K.'},
      {'language': 'en'},
      {'currency': 'EUR'},
    ]);
    expect(languages, ['en']);
    expect(changes, 3);
  });

  testWidgets('spedycja: zaproszenia i role bez kierowców', (tester) async {
    bigScreen(tester);
    await tester.pumpWidget(
        localized(MembersScreen(api: api(), companyId: 'c1', role: 'owner', companyKind: 'forwarder')));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>).last);
    await tester.pumpAndSettle();
    expect(find.text('Zmień rolę na: Kierowca'), findsNothing);
    expect(find.text('Zmień rolę na: Dyspozytor'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Zaproś'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Utwórz kod'));
    await tester.pumpAndSettle();
    expect(requests.singleWhere((r) => r.$1 == 'POST').$3, {'role': 'dispatcher', 'note': ''});
  });
}
