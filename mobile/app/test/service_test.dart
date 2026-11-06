import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/service/analytics_screen.dart';
import 'package:truckmaps_app/src/service/repairs_screen.dart';
import 'package:truckmaps_app/src/service/tco_screen.dart';
import 'package:truckmaps_app/src/service/workshop_screen.dart';

import 'localized.dart';

http.Response json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

final now = DateTime(2026, 11, 6, 12);
String ago(int days) => now.subtract(Duration(days: days)).toUtc().toIso8601String();

final vehicles = [
  {
    'id': 'v1',
    'company_id': 'c1',
    'kind': 'tractor',
    'name': 'Volvo FH 500',
    'plate': 'WI 4022P',
    'consumption_loaded': 28.0,
    'consumption_empty': 22.0,
    'emission_class': 'euro6',
    'trailer_id': 't1'
  },
  {
    'id': 'v2',
    'company_id': 'c1',
    'kind': 'tractor',
    'name': 'DAF XG+',
    'plate': 'WI 1099R',
    'in_repair': true,
    'consumption_loaded': 30.0,
    'consumption_empty': 24.0
  },
  {'id': 't1', 'company_id': 'c1', 'kind': 'semitrailer', 'name': 'Schmitz MEGA', 'plate': 'WX 114M'},
];

Map<String, dynamic> order(String id, String vehicle, String status,
        {String urgency = 'can_drive', int days = 0, List<Map<String, dynamic>> parts = const [], double? hours}) =>
    {
      'id': '$id-0000-0000',
      'vehicle_id': vehicle,
      'vehicle_name': vehicle == 'v1' ? 'Volvo FH 500' : (vehicle == 't1' ? 'Schmitz MEGA' : 'DAF XG+'),
      'vehicle_plate': vehicle == 'v1' ? 'WI 4022P' : (vehicle == 't1' ? 'WX 114M' : 'WI 1099R'),
      'reporter_name': 'Janusz Bogucki',
      'description': 'Opis $id',
      'urgency': urgency,
      'status': status,
      'mechanic_name': status == 'new' ? null : 'Dariusz Wójcik',
      'work_done': status == 'done' ? 'Wykonano $id' : null,
      'parts': parts,
      'labour_hours': hours,
      'labour_rate': hours == null ? null : 150.0,
      'currency': 'PLN',
      'created_at': ago(days),
      'completed_at': status == 'done'
          ? now.subtract(Duration(days: days)).add(const Duration(hours: 5)).toUtc().toIso8601String()
          : null,
    };

final orders = [
  order('aaaaaa', 't1', 'in_progress',
      urgency: 'stopped',
      parts: [
        {'name': 'Tarcza hamulcowa 430 mm', 'quantity': 2, 'price': 560.0},
        {'name': 'Klocki Jurid 539', 'quantity': 1, 'price': 480.0},
      ],
      hours: 4.5),
  order('bbbbbb', 'v1', 'new'),
  order('cccccc', 'v2', 'accepted'),
  order('dddddd', 't1', 'done',
      days: 2,
      parts: [
        {'name': 'Miech', 'quantity': 1, 'price': 640.0}
      ],
      hours: 1.0),
  order('eeeeee', 'v1', 'done',
      days: 40,
      urgency: 'stopped',
      parts: [
        {'name': 'Alternator', 'quantity': 1, 'price': 1350.0}
      ],
      hours: 3.0),
];

CoreApi api() => CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async => json(switch (r.url.path) {
            '/api/vehicles' => vehicles,
            '/api/m/service/orders' => orders,
            '/api/vehicles/v1/stats' => {
                'trips': 40,
                'distance_km': 40000,
                'empty_km': 2000,
                'costs': {'PLN': 160000},
                'months': [
                  {
                    'month': '2026-11',
                    'distance_km': 8000,
                    'costs': {'PLN': 32000}
                  }
                ],
              },
            '/api/vehicles/v2/stats' => {
                'trips': 10,
                'distance_km': 10000,
                'empty_km': 1000,
                'costs': {'PLN': 44000}
              },
            '/api/m/drivers/drivers' => [
                {
                  'id': 'd1',
                  'name': 'Janusz Bogucki',
                  'vehicles': [
                    {'vehicle_id': 'v1', 'plate': 'WI 4022P'}
                  ]
                }
              ],
            '/api/m/drivers/drivers/d1/stats' => {
                'trips': 30,
                'distance_km': 32410,
                'hours': 480,
                'empty_km': 1620,
                'idle_hours': 12.5
              },
            _ => <String, dynamic>{},
          })),
    );

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 2800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('warsztat: dostępność, przestoje, otwarte zlecenia, stanowiska, kolejka', (tester) async {
    big(tester);
    final opened = <String>[];
    await tester.pumpWidget(localized(Scaffold(
      body: WorkshopScreen(
        api: api(),
        companyId: 'c1',
        companyName: 'HeniuTrans',
        today: now,
        onOpen: opened.add,
        onOpenOrder: (id, no) => opened.add('zlecenie $no'),
        onOpenRepairs: () => opened.add('lista'),
        onOpenTco: () => opened.add('tco'),
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('HeniuTrans'), findsOneWidget);
    expect(find.text('50%'), findsOneWidget); // 1 z 2 ciągników w naprawie
    expect(find.text('5 godz', findRichText: true), findsOneWidget); // MTTR
    expect(find.text('1 krytyczne (VOR)'.toUpperCase()), findsOneWidget);
    expect(find.text('WX 114M'), findsWidgets); // stanowisko w realizacji
    expect(find.text('WO-AAAAAA'), findsOneWidget);
    expect(find.text('Nieprzypisany'), findsOneWidget); // nowe zlecenie bez mechanika
    await tester.tap(find.byKey(const Key('ws-row-aaaaaa-0000-0000')));
    await tester.tap(find.text('Raport TCO'));
    expect(opened, ['zlecenie WO-AAAAAA', 'tco']);
  });

  testWidgets('karta zlecenia: części, robocizna, sumy, historia pojazdu', (tester) async {
    big(tester);
    await tester.pumpWidget(localized(Scaffold(
      body: RepairsScreen(
        api: api(),
        companyId: 'c1',
        orderId: 'aaaaaa-0000-0000',
        today: now,
        onOpen: (_) {},
        onOpenOrder: (a, b) {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Opis aaaaaa'), findsWidgets);
    expect(find.text('Tarcza hamulcowa 430 mm'), findsOneWidget);
    expect(find.text('1120 PLN'), findsOneWidget); // 2 × 560
    expect(find.text('675 PLN'), findsWidgets); // 4,5 h × 150
    expect(find.text('2275 PLN'), findsOneWidget); // netto
    expect(find.textContaining('Wymiana'), findsNothing);
    expect(find.text('Opis dddddd'), findsOneWidget); // poprzednia naprawa naczepy
    expect(find.text('Łączne nakłady: 790 PLN'), findsOneWidget);
  });

  testWidgets('lista zleceń: filtry statusu', (tester) async {
    big(tester);
    await tester.pumpWidget(localized(Scaffold(
      body: RepairsScreen(api: api(), companyId: 'c1', today: now, onOpen: (_) {}, onOpenOrder: (a, b) {}),
    )));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rp-row-bbbbbb-0000-0000')), findsOneWidget);
    await tester.tap(find.byKey(const Key('rp-filter-done')));
    await tester.pump();
    expect(find.byKey(const Key('rp-row-bbbbbb-0000-0000')), findsNothing);
    expect(find.byKey(const Key('rp-row-dddddd-0000-0000')), findsOneWidget);
  });

  testWidgets('analityka: przebieg, puste km, koszt na km, ranking', (tester) async {
    big(tester);
    await tester.pumpWidget(localized(Scaffold(
      body: AnalyticsScreen(api: api(), companyId: 'c1', companyName: 'HeniuTrans', onOpen: (_) {}),
    )));
    await tester.pumpAndSettle();
    expect(find.text('50000 km', findRichText: true), findsOneWidget); // 40 000 + 10 000 km
    expect(find.text('Pusty bieg: 6%'), findsOneWidget);
    // (160 000 + 44 000 + koszty napraw 2 590) / 50 000 km
    expect(find.text('4,13 PLN / km', findRichText: true), findsOneWidget);
    expect(find.text('WI 4022P'), findsOneWidget);
  });

  testWidgets('TCO: struktura kosztów, benchmark marek, ranking kierowców', (tester) async {
    big(tester);
    await tester.pumpWidget(localized(Scaffold(body: TcoScreen(api: api(), companyId: 'c1', onOpen: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.text('4,08 PLN/km'), findsOneWidget); // trasy 204 000 / 50 000
    expect(find.text('Volvo'), findsOneWidget);
    expect(find.text('DAF'), findsOneWidget);
    expect(find.text('Janusz Bogucki'), findsOneWidget);
    expect(find.text('32410 km'), findsOneWidget);
    expect(find.text('Przyrost przy pełnym ładunku: +6 l / 100 km'), findsOneWidget);
  });
}
