import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/dashboard/main_dashboard.dart';
import 'package:truckmaps_app/src/fleet/fleet_screen.dart';
import 'package:truckmaps_app/src/l10n.dart';

import 'localized.dart';

http.Response json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

Map<String, dynamic> vehicle(String id, String plate,
        {String kind = 'tractor', Map<String, dynamic> extra = const {}}) =>
    {'id': id, 'plate': plate, 'name': 'Pojazd $plate', 'kind': kind, 'company_id': 'c1', ...extra};

final vehicles = [
  vehicle('t1', 'WI 4022P', extra: {
    'in_use': true,
    'driver_name': 'Tomasz Nowak',
    'trailer_id': 'n1',
    'production_year': 2023,
    'emission_class': 'euro6',
    'inspection_until': '2026-11-12',
    'consumption_loaded': 28.0,
    'insurance_until': '2027-03-01',
    'gvw_t': 40.0,
    'axle_count': 5,
    'axle_load_t': 11.5,
  }),
  vehicle('t2', 'WI 1099R', extra: {'in_repair': true, 'production_year': 2021, 'tachograph_until': '2026-11-20'}),
  vehicle('t3', 'WI 7733T', extra: {'production_year': 2024}),
  vehicle('n1', 'WN 9024X', kind: 'semitrailer', extra: {'trailer_type': 'curtain', 'name': 'Schmitz MEGA'}),
  vehicle('n2', 'WN 3311A', kind: 'semitrailer', extra: {'trailer_type': 'reefer'}),
  {'id': 'x', 'plate': 'OBCY 1', 'name': 'Obcy', 'kind': 'tractor', 'company_id': 'inna'},
];

void main() {
  testWidgets('Pojazdy i Tabor: pojazdy firmy z API, wskaźniki, filtry, terminy, reszta „W budowie”', (tester) async {
    tester.view.physicalSize = const Size(1500, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async => json(switch (r.url.path) {
            '/api/vehicles' => vehicles,
            '/api/dashboard/screen' => {
                'bases': ['Tarnów']
              },
            _ => <String, dynamic>{},
          })),
    );
    final opened = <String>[];
    await tester.pumpWidget(localized(Scaffold(
      body: FleetScreen(api: api, companyId: 'c1', onOpen: opened.add, today: DateTime(2026, 11, 6)),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Tabor Samochodowy i Sprzęt'), findsOneWidget);
    expect(find.text('Baza: 5 Aktywne Jednostki'), findsOneWidget); // obcy pojazd pominięty
    expect(find.text('Tarnów'), findsOneWidget);
    // Wiersze: tylko pojazdy z napędem; naczepa przy ciągniku.
    expect(find.text('WI 4022P'), findsOneWidget);
    expect(find.text('OBCY 1'), findsNothing);
    expect(find.textContaining('WN 9024X'), findsOneWidget);
    expect(find.text('Tomasz Nowak'), findsOneWidget);
    expect(find.text('W trasie'), findsOneWidget);
    expect(find.text('Warsztat'), findsOneWidget);
    expect(find.text('SERWIS'), findsOneWidget);
    expect(find.text('GOTOWY'), findsOneWidget);
    expect(find.textContaining('Przegląd do'), findsOneWidget);
    // Wskaźniki i terminy liczone z danych.
    expect(find.text('W drodze (1)'), findsOneWidget);
    expect(find.text('Dostępne (1)'), findsOneWidget);
    expect(find.text('Alarm CAN / Warsztat (1)'), findsOneWidget);
    expect(find.text('Pojazdy do rezerwacji stacji: 1'), findsOneWidget);
    expect(find.text('W ciągu 30 dni: 1'), findsOneWidget);
    expect(find.text('Ważne OC: 1 z 5 pojazdów'), findsOneWidget);
    expect(find.text('DMC: 40 t'), findsOneWidget);
    expect(find.byType(WipTag), findsWidgets);

    // Filtr statusu i wyszukiwarka.
    await tester.tap(find.byKey(const Key('fleet-status-service')));
    await tester.pump();
    expect(find.text('WI 4022P'), findsNothing);
    expect(find.text('WI 1099R'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fleet-status-service')));
    await tester.enterText(find.byKey(const Key('fleet-search')), 'nowak');
    await tester.pump();
    expect(find.text('WI 4022P'), findsOneWidget);
    expect(find.text('WI 7733T'), findsNothing);
    await tester.enterText(find.byKey(const Key('fleet-search')), '');
    // Zakładka chłodni: żaden ciągnik nie ma naczepy-chłodni.
    await tester.tap(find.byKey(const Key('fleet-tab-reefers')));
    await tester.pump();
    expect(find.text('Brak pojazdów spełniających filtr.'), findsOneWidget);
    await tester.tap(find.byKey(const Key('fleet-tab-all')));
    await tester.pump();

    // Baza jako filtr: w Tarnowie nie ma pojazdów, „Wszystkie bazy” – z powrotem pełna lista.
    await tester.tap(find.text('Tarnów'));
    await tester.pump();
    expect(find.text('Brak pojazdów spełniających filtr.'), findsOneWidget);
    await tester.tap(find.text('Wszystkie bazy'));
    await tester.pump();
    expect(find.text('WI 4022P'), findsOneWidget);

    // Kalendarz terminów: wszystkie terminy pojazdów po kolei.
    await tester.tap(find.text('Kalendarz ›'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Przegląd · '), findsWidgets);
    await tester.tap(find.text('Zamknij'));
    await tester.pumpAndSettle();

    // Przyciski bez ekranu → „W budowie”.
    await tester.tap(find.byKey(const Key('fleet-add')));
    await tester.tap(find.byKey(const Key('fleet-row-t1')));
    expect(opened, ['+ Dodaj Pojazd do Bazy', 'WI 4022P']);
  });

  testWidgets('pulpit: prawdziwe dane zastępują pokazowe tylko tam, gdzie są', (tester) async {
    late AppLocalizations l;
    await tester.pumpWidget(localized(Builder(builder: (context) {
      l = context.l;
      return const SizedBox();
    })));
    final screen = {
      'fleet_ok': '98.4%',
      'kpis': [
        {'label': 'Aktywne zestawy w trasie', 'value': '284', 'unit': '/ 323 ciągniki', 'right': '+12 vs wczoraj'},
        {'label': 'Punktualność', 'value': '97.2%'},
      ],
      'alerts': [
        {'tag': 'demo'}
      ],
      'messages': [
        {'tag': 'demo'}
      ],
      'telemetry': {'percent': '98.4%', 'active': 318, 'total': 323},
    };
    final merged = mergeLive(l, screen, overview: {
      'kpis': [
        {'key': 'fleet.active', 'value': 2, 'total': 5},
        {'key': 'fleet.health', 'value': 80},
      ]
    }, alerts: [
      {
        'kind': 'vehicle_repair',
        'severity': 'warning',
        'vehicle_name': 'DAF',
        'plate': 'WI 1099R',
        'data': <String, dynamic>{},
      }
    ]);
    final kpis = merged['kpis'] as List;
    expect((kpis[0] as Map)['value'], '2');
    expect((kpis[0] as Map)['unit'], '/ 5 ciągniki');
    expect((kpis[0] as Map)['left'], '40% utylizacji');
    expect((kpis[1] as Map)['value'], '97.2%'); // bez danych – zostaje
    expect(merged['fleet_ok'], '80%');
    expect((merged['telemetry'] as Map)['active'], 2);
    expect((merged['telemetry'] as Map)['percent'], '98.4%');
    expect(((merged['alerts'] as List)[0] as Map)['title'], 'DAF · WI 1099R');
    expect(merged['alerts_count'], '1 zdarzenie priorytetowe');
    expect(merged['messages'], screen['messages']); // brak wiadomości – pokazowe zostają
  });
}
