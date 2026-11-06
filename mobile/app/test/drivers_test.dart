import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/drivers/driver_edit.dart';
import 'package:truckmaps_app/src/drivers/drivers_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

final vehicles = [
  {
    'id': 'v1',
    'plate': 'WI 4022P',
    'name': 'Volvo FH 500',
    'kind': 'tractor',
    'company_id': 'c1',
    'in_use': true,
    'driver_name': 'Janusz Bogucki',
    'trailer_id': 't1',
  },
  {'id': 't1', 'plate': 'WX 114M', 'name': 'Schmitz Curtainsider', 'kind': 'semitrailer', 'company_id': 'c1'},
];

final bogucki = {
  'id': 'd1',
  'company_id': 'c1',
  'name': 'Janusz Bogucki',
  'phone': '+48 601 928 344',
  'email': 'janusz@example.com',
  'hired_on': '2019-03-01',
  'notes': 'Pauza 45h w Niemczech',
  'member_id': 'm1',
  'member_name': 'Janusz Bogucki',
  'license_categories': ['B', 'C', 'C+E'],
  'license_until': '2027-11-24',
  'code95_until': '2027-11-24',
  'medical_until': '2027-11-15',
  'psych_until': '2027-11-15',
  'card_until': '2028-08-14',
  'card_downloaded_on': '2026-10-13',
  'card_download_until': '2026-11-10',
  'adr_until': '2028-06-30',
  'adr_tank': true,
  'attestation_until': null,
  'vehicles': [
    {'vehicle_id': 'v1', 'name': 'Volvo FH 500', 'plate': 'WI 4022P', 'since': '2026-11-01T08:00:00Z'}
  ],
  'dues': <Object>[],
  'can_edit': true,
};

final nowak = {
  ...bogucki,
  'id': 'd2',
  'name': 'Jan Nowak',
  'member_id': null,
  'member_name': null,
  'vehicles': <Object>[],
  'medical_until': '2026-11-01',
  'dues': [
    {'field': 'medical_until', 'day': '2026-11-01', 'state': 'overdue'}
  ],
};

CoreApi api({bool module = true, Map<String, Object?>? puts}) => CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async {
        final path = r.url.path;
        if (r.method == 'PUT') {
          puts?[path] = jsonDecode(r.body);
          return json(bogucki);
        }
        if (path.startsWith('/api/m/drivers') && !module) return json({'detail': 'nieaktywny'}, 402);
        return switch (path) {
          '/api/vehicles' => json(vehicles),
          '/api/m/drivers/drivers' => json([bogucki, nowak]),
          '/api/m/drivers/drivers/d1/stats' => json({
              'trips': 12,
              'distance_km': 4820.4,
              'hours': 61.5,
              'empty_km': 120,
              'idle_hours': 2.5,
              'vehicles': 1,
              'recent': [
                {'ended_at': '2026-11-03T10:00:00Z'}
              ],
            }),
          '/api/m/drivers/drivers/d1/history' => json([
              {
                'id': 'h1',
                'at': '2026-11-02T10:00:00Z',
                'by_name': 'Ewa',
                'action': 'updated',
                'changes': {'phone': []}
              }
            ]),
          '/api/companies/c1' => json({
              'members': [
                {'id': 'm1', 'display_name': 'Janusz Bogucki', 'role': 'driver'},
                {'id': 'm2', 'display_name': 'Ewa', 'role': 'dispatcher'},
              ]
            }),
          _ => json(<String, dynamic>{}),
        };
      }),
    );

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('lista kierowców z modułu: stan, pojazd, najbliższy termin; klik – profil', (tester) async {
    big(tester);
    final opened = <String>[];
    await tester.pumpWidget(localized(Scaffold(
      body: DriversScreen(
        api: api(),
        companyId: 'c1',
        onOpen: opened.add,
        onOpenDriver: (id, name) => opened.add('profil $id $name'),
        onEdit: (id, name) {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('2 kierowców'), findsOneWidget);
    expect(find.text('W TRASIE'), findsOneWidget);
    expect(find.text('Pojazd: Volvo FH 500 (WI 4022P)'), findsOneWidget);
    expect(find.textContaining('Badania lekarskie'), findsOneWidget); // termin po czasie u Nowaka
    await tester.enterText(find.byKey(const Key('drv-search')), 'nowak');
    await tester.pump();
    expect(find.text('Janusz Bogucki'), findsNothing);
    await tester.enterText(find.byKey(const Key('drv-search')), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('drv-card-d1')));
    expect(opened, ['profil d1 Janusz Bogucki']);
  });

  testWidgets('profil: pojazd, naczepa, uprawnienia, kontakt, statystyki, historia; reszta „W budowie”',
      (tester) async {
    big(tester);
    final opened = <String>[];
    String? edited;
    await tester.pumpWidget(localized(Scaffold(
      body: DriversScreen(
        api: api(),
        companyId: 'c1',
        driverName: 'Janusz Bogucki', // z taboru – po nazwisku
        today: DateTime(2026, 11, 6),
        onOpen: opened.add,
        onOpenDriver: (id, name) {},
        onEdit: (id, name) => edited = id,
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Volvo FH 500 (WI 4022P)'), findsOneWidget);
    expect(find.text('Schmitz Curtainsider (WX 114M)'), findsOneWidget);
    expect(find.text('Badania lekarskie ważne'), findsOneWidget);
    expect(find.text('Kod 95 do: 24.11.2027'), findsOneWidget);
    expect(find.text('Karta – odczyt 24 dni temu'), findsOneWidget);
    expect(find.text('ADR podst. + cysterny'), findsOneWidget);
    expect(find.text('+48 601 928 344'), findsOneWidget);
    expect(find.text('„Pauza 45h w Niemczech”'), findsOneWidget);
    expect(find.text('12'), findsOneWidget); // przejazdy
    expect(find.text('Dni z przejazdami: 1'), findsOneWidget);

    await tester.tap(find.byKey(const Key('drv-tab-1')));
    await tester.pump();
    expect(find.text('B, C, C+E'), findsOneWidget);
    await tester.tap(find.byKey(const Key('drv-tab-2')));
    await tester.pump();
    expect(find.textContaining('Ewa'), findsOneWidget);

    await tester.tap(find.text('Wiadomość do kabiny'));
    await tester.tap(find.text('Edytuj dane'));
    expect(opened, ['Wiadomość do kabiny']);
    expect(edited, 'd1');
  });

  testWidgets('edycja profilu zapisuje kartotekę modułu (PUT)', (tester) async {
    big(tester);
    final puts = <String, Object?>{};
    bool? done;
    await tester.pumpWidget(localized(Scaffold(
      body: DriverEditScreen(
        api: api(puts: puts),
        companyId: 'c1',
        driverId: 'd1',
        onOpen: (_) {},
        onDone: (saved) => done = saved,
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Janusz Bogucki'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('drv-phone')), '+48 600 000 000');
    await tester.tap(find.byKey(const Key('drv-cat-D')));
    await tester.enterText(find.byKey(const Key('drv-notes')), 'Nowa notatka');
    await tester.tap(find.byKey(const Key('drv-save')));
    await tester.pumpAndSettle();
    final body = puts['/api/m/drivers/drivers/d1'] as Map;
    expect(body['name'], 'Janusz Bogucki');
    expect(body['phone'], '+48 600 000 000');
    expect(body['license_categories'], ['B', 'C', 'C+E', 'D']);
    expect(body['code95_until'], '2027-11-24');
    expect(body['adr_tank'], true);
    expect(body['notes'], 'Nowa notatka');
    expect(body['member_id'], 'm1');
    expect(done, true);
  });

  testWidgets('bez modułu Kierowcy: lista z członków firmy i informacja „w budowie”', (tester) async {
    big(tester);
    await tester.pumpWidget(localized(Scaffold(
      body: DriversScreen(
        api: api(module: false),
        companyId: 'c1',
        onOpen: (_) {},
        onOpenDriver: (id, name) {},
        onEdit: (id, name) {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('1 kierowców'), findsOneWidget);
    expect(find.text('Janusz Bogucki'), findsOneWidget);
    expect(find.textContaining('Moduł Kierowcy nie jest aktywny'), findsOneWidget);
  });
}
