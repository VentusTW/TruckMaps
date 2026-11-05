import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/dashboard_screen.dart';
import 'package:truckmaps_app/src/planner/place_field.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';
import 'package:truckmaps_app/src/planner/recent.dart';
import 'package:truckmaps_app/src/vehicles/vehicle_card.dart';

import 'localized.dart';
import 'planner_test.dart' show route;

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

CoreApi api(Map<String, Object?> responses, [List<String>? requests]) => CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        requests?.add('${request.method} ${request.url.path}');
        final body = responses[request.url.path];
        return body == null ? json({'detail': 'brak'}, 404) : json(body);
      }),
    );

void size(WidgetTester tester, [Size value = const Size(1400, 1400)]) {
  tester.view.physicalSize = value;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

const tarnow = RecentRoute(
  from: Place('Tarnów, Rynek', LatLng(50.01, 20.98)),
  to: Place('Kraków, Nowa Huta', LatLng(50.07, 20.04)),
  vehicleId: 'v1',
  vehicleName: 'MAN TGX',
);

void main() {
  setUp(() => mapTiles = () => const SizedBox());

  testWidgets('pulpit: terminy i stan pojazdów, nowe wiadomości, ostatnie trasy i sekcja modułu', (tester) async {
    size(tester);
    final today = DateTime.now();
    String day(int days) => today.add(Duration(days: days)).toIso8601String().substring(0, 10);
    final memory = PlannerMemory();
    await memory.addRoute(tarnow);
    RecentRoute? planned;
    Map<String, dynamic>? opened;
    await tester.pumpWidget(localized(Scaffold(
      body: DashboardScreen(
        api: api({
          '/api/vehicles': [
            {'id': 'v1', 'name': 'MAN TGX', 'kind': 'tractor', 'insurance_until': day(-2)},
            {'id': 'v2', 'name': 'Solówka', 'kind': 'rigid', 'in_repair': true},
            {'id': 'v3', 'name': 'Bus', 'kind': 'van', 'inspection_until': day(200)},
          ],
          '/api/me/messages': {
            'unread': 1,
            'items': [
              {
                'id': 'm1',
                'kind': 'service.order_new',
                'read': false,
                'created_at': '2026-11-05T08:00:00Z',
                'data': {'vehicle_name': 'Solówka'}
              },
              {'id': 'm2', 'kind': 'vehicle_due', 'read': true, 'created_at': '2026-11-01T08:00:00Z', 'data': {}},
            ],
          },
        }),
        userName: 'Anna',
        memory: memory,
        onPlanRoute: (route) => planned = route,
        onOpenVehicle: (vehicle) => opened = vehicle,
        onAddVehicle: () {},
        onOpenPage: (_) {},
        sections: [
          DashboardSection(
            id: 'test',
            builder: (_) => const SectionCard(title: 'Sekcja modułu', icon: Icons.extension, child: Text('treść')),
          ),
        ],
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('MAN TGX'), findsWidgets);
    expect(find.textContaining('Ubezpieczenie'), findsOneWidget); // po terminie
    expect(find.textContaining('w naprawie'), findsOneWidget);
    expect(find.text('Bus'), findsNothing); // termin daleko – nie wymaga uwagi
    expect(find.text('Nowe zgłoszenie usterki: Solówka'), findsOneWidget);
    expect(find.text('Tarnów → Kraków'), findsOneWidget);
    expect(find.text('Sekcja modułu'), findsOneWidget);

    await tester.tap(find.text('Znowu do: Kraków'));
    expect(planned?.to.label, 'Kraków, Nowa Huta');
    await tester.tap(find.text('Solówka'));
    expect(opened?['id'], 'v2');
  });

  testWidgets('planer: domyślnie pojazd przydzielony mnie; ostatnia trasa jednym kliknięciem', (tester) async {
    size(tester, const Size(1600, 1300));
    final memory = PlannerMemory();
    await memory.addRoute(tarnow);
    await memory.setVehicle('v1');
    final requests = <String>[];
    Map<String, dynamic>? sent;
    final client = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        requests.add(request.url.path);
        switch (request.url.path) {
          case '/api/vehicles':
            return json([
              {'id': 'v1', 'name': 'MAN TGX', 'gvw_t': 40, 'height_m': 4.0},
              {'id': 'v2', 'name': 'Volvo FH', 'gvw_t': 40, 'height_m': 4.0, 'assigned_to_me': true},
            ]);
          case '/api/bases':
            return json([
              {'id': 'b1', 'name': 'Baza Tarnów', 'lat': 50.0, 'lon': 21.0, 'company_id': 'c1'},
            ]);
          case '/api/routes':
            sent = jsonDecode(request.body) as Map<String, dynamic>;
            return json(route);
        }
        return json(null, 404);
      }),
    );
    await tester.pumpWidget(localized(Scaffold(body: PlannerScreen(api: client, memory: memory))));
    await tester.pump(const Duration(milliseconds: 200));

    // Przydzielony pojazd wygrywa z ostatnio używanym.
    expect(find.textContaining('Volvo FH · przydzielony do Ciebie'), findsWidgets);
    expect(find.text('Baza Tarnów'), findsOneWidget);

    await tester.tap(find.text('Tarnów → Kraków'));
    await tester.pump(const Duration(milliseconds: 200));
    // Ostatnia trasa wraca z pojazdem, którym była planowana – od razu policzona.
    expect(sent?['vehicle_id'], 'v1');
    expect(sent?['destination'], {'lat': 50.07, 'lon': 20.04});
    expect(find.text('Rozpocznij jazdę'), findsOneWidget);
    expect(find.text('Przegląd trasy'), findsOneWidget);
  });

  testWidgets('karta pojazdu: terminy, kierowca, szybkie podpięcie, sekcja i akcja modułu', (tester) async {
    size(tester, const Size(900, 2000));
    final today = DateTime.now().add(const Duration(days: 10)).toIso8601String().substring(0, 10);
    const tractor = {
      'id': 't1',
      'name': 'MAN TGX',
      'kind': 'tractor',
      'company_id': 'c1',
      'can_edit': true,
      'can_service': true,
      'assigned_driver_name': 'Jan',
    };
    final requests = <String>[];
    var ran = 0;
    await tester.pumpWidget(localized(
      theme: TruckTheme.light(),
      VehicleCardScreen(
        api: api({
          '/api/vehicles': [
            {...tractor, 'inspection_until': today},
            {'id': 'n1', 'name': 'Firanka', 'kind': 'semitrailer', 'can_edit': true},
          ],
          '/api/vehicles/t1/trailer': {'id': 't1'},
          '/api/permits': [],
          '/api/vehicles/t1/stats': {'trips': 0},
        }, requests),
        vehicle: tractor,
        sections: [
          VehicleSection(
            id: 'test',
            builder: (_, v) => SectionCard(title: 'Usterki: ${v['name']}', icon: Icons.build, child: const Text('—')),
          ),
        ],
        actions: [
          VehicleAction(
            id: 'report',
            label: 'Zgłoś usterkę',
            icon: Icons.report_problem_outlined,
            run: (_, __) async {
              ran++;
              return false;
            },
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Terminy i przeglądy'), findsOneWidget);
    expect(find.text('Przegląd techniczny ważny do'), findsOneWidget);
    expect(find.text('Kierowca: Jan'), findsOneWidget);
    expect(find.text('Usterki: MAN TGX'), findsOneWidget);
    expect(find.text('Brak zezwoleń ważnych dziś.'), findsOneWidget);

    await tester.tap(find.byKey(const Key('card-action-report')));
    await tester.pumpAndSettle();
    expect(ran, 1);

    await tester.tap(find.text('Podepnij Firanka'));
    await tester.pumpAndSettle();
    expect(requests, contains('PUT /api/vehicles/t1/trailer'));
  });
}
