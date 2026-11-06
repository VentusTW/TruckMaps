import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/fleet/vehicle_edit.dart';
import 'package:truckmaps_app/src/fleet/vehicle_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

final volvo = {
  'id': 'v1',
  'company_id': 'c1',
  'kind': 'tractor',
  'name': 'Volvo FH 500 I-Save',
  'plate': 'WI 4022P',
  'vin': 'YV2RT40A8MB198421',
  'production_year': 2023,
  'emission_class': 'euro6',
  'fuel_type': 'diesel',
  'consumption_loaded': 28.0,
  'odometer_km': 142850,
  'service_due_km': 160000,
  'height_m': 4.0,
  'width_m': 2.55,
  'length_m': 16.5,
  'weight_t': 40.0,
  'gvw_t': 40.0,
  'tare_t': 7.8,
  'axle_load_t': 11.5,
  'axle_count': 2,
  'trailer_type': 'none',
  'hazmat': false,
  'cost_currency': 'EUR',
  'inspection_until': '2026-11-20',
  'last_inspection': '2025-11-20',
  'insurance_until': '2027-03-01',
  'tachograph_until': '2026-10-01',
  'trailer_id': 't1',
  'in_use': true,
  'driver_name': 'Janusz Bogucki',
  'assigned_member_id': 'm1',
};

final schmitz = {
  'id': 't1',
  'company_id': 'c1',
  'kind': 'semitrailer',
  'name': 'Schmitz Cargobull MEGA',
  'plate': 'WX 114M',
  'trailer_type': 'reefer',
  'axle_count': 3,
  'axle_load_t': 8.0,
  'gvw_t': 39.0,
  'tare_t': 7.5,
  'coupled_to_id': 'v1',
};

final other = {...schmitz, 'id': 't2', 'plate': 'WN 2109P', 'name': 'Schmitz MEGA Firanka', 'coupled_to_id': null};

CoreApi api({Map<String, List<Object?>>? puts, bool service = true}) => CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async {
        final path = r.url.path;
        if (r.method == 'PUT') {
          puts?.putIfAbsent(path, () => []).add(jsonDecode(r.body));
          return json(volvo);
        }
        if (path.startsWith('/api/m/service') && !service) return json({'detail': 'nieaktywny'}, 402);
        return switch (path) {
          '/api/vehicles' => json([volvo, schmitz, other]),
          '/api/vehicles/v1/stats' => json({'distance_km': 73000, 'trips': 40}),
          '/api/m/service/orders' => json([
              {
                'id': 'o1',
                'description': 'Wymiana filtra osuszacza',
                'status': 'done',
                'work_done': 'Wymiana wkładu Wabco',
                'mechanic_name': 'Serwis Volvo Trucks',
                'created_at': '2026-08-10T10:00:00Z',
              }
            ]),
          '/api/companies/c1' => json({
              'members': [
                {'id': 'm1', 'display_name': 'Janusz Bogucki', 'role': 'driver'},
                {'id': 'm2', 'display_name': 'Paweł Wiśniewski', 'role': 'driver'},
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
  testWidgets('profil pojazdu: dane karty, naczepa, kierowca, terminy, osie, serwis; reszta „W budowie”',
      (tester) async {
    big(tester);
    final opened = <String>[];
    await tester.pumpWidget(localized(Scaffold(
      body: VehicleScreen(
        api: api(),
        vehicleId: 'v1',
        today: DateTime(2026, 11, 6),
        onOpen: opened.add,
        onEdit: (id, name) => opened.add('edycja $id'),
        onOpenVehicle: (id, name) => opened.add('pojazd $id'),
        onOpenDriver: (name) => opened.add('kierowca $name'),
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('WI 4022P'), findsOneWidget);
    expect(find.text('W RUCHU'), findsOneWidget);
    expect(find.text('VIN: YV2RT40A8MB198421'), findsOneWidget);
    expect(find.textContaining('142'), findsWidgets); // przebieg
    expect(find.text('Średnia: 200 km / dzień'), findsOneWidget);
    expect(find.text('za 17150 km'), findsOneWidget);
    expect(find.text('Wymiana filtra osuszacza'), findsOneWidget);
    expect(find.text('14 dni'), findsOneWidget); // SKP
    expect(find.text('Po terminie'), findsOneWidget); // tachograf
    expect(find.text('Oś 3'), findsOneWidget); // naczepa trójosiowa
    expect(find.textContaining('15,3 t'), findsOneWidget); // masa własna zestawu

    await tester.tap(find.byKey(const Key('veh-driver')));
    await tester.tap(find.byKey(const Key('veh-trailer')));
    await tester.tap(find.text('Edytuj'));
    await tester.tap(find.text('Pobierz FMS'));
    expect(opened, ['kierowca Janusz Bogucki', 'pojazd t1', 'edycja v1', 'Pobierz FMS']);
  });

  testWidgets('edycja pojazdu: zapis karty, kierowcy i naczepy', (tester) async {
    big(tester);
    final puts = <String, List<Object?>>{};
    bool? done;
    await tester.pumpWidget(localized(Scaffold(
      body: VehicleEditScreen(api: api(puts: puts), vehicleId: 'v1', onOpen: (_) {}, onDone: (s) => done = s),
    )));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('veh-odometer_km')), '150000');
    await tester.enterText(find.byKey(const Key('veh-plate')), 'wi 4023p');
    await tester.enterText(find.byKey(const Key('veh-tare_t')), '7,9');
    await tester.tap(find.byKey(const Key('veh-driver')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Paweł Wiśniewski').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('veh-trailer')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('WN 2109P Schmitz MEGA Firanka').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('veh-save')));
    await tester.pumpAndSettle();
    final card = puts['/api/vehicles/v1']!.single as Map;
    expect(card['odometer_km'], 150000);
    expect(card['plate'], 'WI 4023P');
    expect(card['tare_t'], 7.9);
    expect(card['inspection_until'], '2026-11-20');
    expect(card['vin'], 'YV2RT40A8MB198421');
    expect(puts['/api/vehicles/v1/driver'], [
      {'member_id': 'm2'}
    ]);
    expect(puts['/api/vehicles/v1/trailer'], [
      {'trailer_id': 't2'}
    ]);
    expect(done, true);
  });

  testWidgets('bez modułu Serwis: książka serwisowa „w budowie”', (tester) async {
    big(tester);
    await tester.pumpWidget(localized(Scaffold(
      body: VehicleScreen(
        api: api(service: false),
        vehicleId: 'v1',
        onOpen: (_) {},
        onEdit: (a, b) {},
        onOpenVehicle: (a, b) {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('moduł Serwis nieaktywny'), findsOneWidget);
  });
}
