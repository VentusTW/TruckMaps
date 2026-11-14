import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/drivers/drivers_screen.dart';
import 'package:truckmaps_app/src/drivers/tacho.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

String utc(DateTime local) => local.toUtc().toIso8601String();

/// Dwa dni lokalnie: 5 h jazdy bez przerwy w poniedziałek, odpoczynek przez północ, praca we wtorek.
Map<String, dynamic> tachoJson() {
  final mon = DateTime(2026, 11, 2);
  return {
    'driver_id': 'd1',
    'card_number': 'PL000012345678',
    'days': 28,
    'segments': [
      {
        'start': utc(mon.add(const Duration(hours: 6))),
        'end': utc(mon.add(const Duration(hours: 11))),
        'activity': 'driving',
        'source': 'card'
      },
      {
        'start': utc(mon.add(const Duration(hours: 11))),
        'end': utc(mon.add(const Duration(hours: 30))),
        'activity': 'rest',
        'source': 'card'
      },
      {
        'start': utc(mon.add(const Duration(hours: 30))),
        'end': utc(mon.add(const Duration(hours: 31, minutes: 30))),
        'activity': 'work',
        'source': 'card'
      },
    ],
    'violations': [
      {
        'kind': 'break',
        'severity': 'serious',
        'start': utc(mon.add(const Duration(hours: 6))),
        'end': utc(mon.add(const Duration(hours: 11))),
        'value': 300,
        'limit': 270,
      }
    ],
    'counters': {
      'at': utc(mon.add(const Duration(hours: 31, minutes: 30))),
      'continuous_driving': 0,
      'continuous_limit': 270,
      'daily_driving': 0,
      'daily_limit': 600,
      'extensions_left': 2,
      'daily_rest_due': utc(mon.add(const Duration(hours: 45))),
      'reduced_rests_left': 3,
      'weekly_driving': 300,
      'weekly_limit': 3360,
      'fortnight_driving': 300,
      'fortnight_limit': 5400,
      'weekly_rest_due': null,
    },
    'places': [
      {
        'at': utc(mon.add(const Duration(hours: 6))),
        'entry': 'begin',
        'country': 'PL',
        'odometer': 120000,
        'lat': null,
        'lon': null
      }
    ],
    'downloads': <Object>[],
  };
}

final driver = {
  'id': 'd1',
  'company_id': 'c1',
  'name': 'Janusz Bogucki',
  'member_id': 'm1',
  'license_categories': ['C', 'CE'],
  'card_download_until': '2026-12-12',
  'vehicles': <Object>[],
  'dues': <Object>[],
  'can_edit': true,
};

CoreApi api(List<http.Request> sent, {bool lastVu = true}) => CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((r) async {
        sent.add(r);
        return switch (r.url.path) {
          '/api/vehicles' => json(<Object>[]),
          '/api/m/drivers/drivers' => json([driver]),
          '/api/m/drivers/drivers/d1/tacho' => json(tachoJson()),
          '/api/m/drivers/tacho/upload' => json({'activities': 12, 'unmatched_cards': <String>[]}, 201),
          '/api/m/drivers/tacho/vehicles/v1' => json(
              {'vehicle_id': 'v1', 'last_download': lastVu ? '2026-11-10T09:00:00Z' : null, 'downloads': <Object>[]}),
          _ => json(<String, dynamic>{}),
        };
      }),
    );

void big(WidgetTester tester) {
  tester.view.physicalSize = const Size(1500, 2800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<(String, List<int>)?> picker(String label) async => ('C_JAN.DDD', [0, 2, 0, 1, 2, 3]);

void main() {
  test('dni lokalne: odcinek przez północ dzielony, sumy minut', () {
    final days = TachoData.fromJson(tachoJson()).byDay();
    expect(days.map((d) => d.day), [DateTime(2026, 11, 3), DateTime(2026, 11, 2)]);
    expect(days[1].minutes, {'driving': 300, 'rest': 780});
    expect(days[0].minutes, {'rest': 360, 'work': 90});
    expect(hoursMinutes(605), '10:05');
  });

  testWidgets('profil kierowcy: liczniki, oś dni, naruszenia, wczytanie pliku .DDD', (tester) async {
    big(tester);
    final sent = <http.Request>[];
    await tester.pumpWidget(localized(Scaffold(
      body: DriversScreen(
        api: api(sent),
        companyId: 'c1',
        driverId: 'd1',
        today: DateTime(2026, 11, 6),
        onOpen: (_) {},
        onOpenDriver: (id, name) {},
        onEdit: (id, name) {},
      ),
    )));
    await tester.pumpAndSettle();
    expect(find.text('CZAS PRACY Z TACHOGRAFU'), findsNothing);
    expect(find.text('Czas Pracy z Tachografu'), findsOneWidget);
    expect(find.text('5:00 / 56:00'), findsOneWidget);
    expect(find.text('0:00 / 10:00'), findsOneWidget);
    expect(find.text('wydłużenia do 10 h: 2'), findsOneWidget);
    expect(find.byKey(const Key('tacho-day-2026-11-02')), findsOneWidget);
    expect(find.text('jazda 5:00 • praca 0:00'), findsOneWidget);
    expect(find.textContaining('początek pracy • PL • 120000 km'), findsOneWidget);
    expect(find.textContaining('W budowie'), findsNothing);

    await tester.tap(find.byKey(const Key('drv-tab-2')));
    await tester.pumpAndSettle();
    expect(find.text('Jazda bez przerwy 5:00 h (limit 4:30 h)'), findsOneWidget);
    expect(find.text('Poważne'), findsOneWidget);

    await tester.tap(find.byKey(const Key('tacho-all-days')));
    await tester.pumpAndSettle();
    expect(find.text('Dni pracy z tachografu'), findsOneWidget);
    await tester.tap(find.text('Zamknij'));
    await tester.pumpAndSettle();

    final upload = tester.widget<TachoUploadButton>(find.byType(TachoUploadButton));
    expect(upload.driverId, 'd1');
    await tester.pumpWidget(localized(Scaffold(
      body: TachoUploadButton(api: api(sent), companyId: 'c1', driverId: 'd1', picker: picker),
    )));
    await tester.tap(find.byKey(const Key('tacho-upload')));
    await tester.pumpAndSettle();
    final post = sent.lastWhere((r) => r.method == 'POST');
    expect(post.url.path, '/api/m/drivers/tacho/upload');
    final body = jsonDecode(post.body) as Map<String, dynamic>;
    expect(body['driver_id'], 'd1');
    expect(body['name'], 'C_JAN.DDD');
    expect(base64Decode('${body['data']}'), [0, 2, 0, 1, 2, 3]);
    expect(find.text('Wczytano C_JAN.DDD: 12 odcinków aktywności'), findsOneWidget);
  });

  testWidgets('pojazd: data pobrania z tachografu i wczytanie pliku VU', (tester) async {
    final sent = <http.Request>[];
    await tester.pumpWidget(localized(Scaffold(
      body: VehicleTachoTag(api: api(sent), companyId: 'c1', vehicleId: 'v1', picker: picker),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Pobrano 10.11.2026'), findsOneWidget);
    await tester.tap(find.byKey(const Key('tacho-upload')));
    await tester.pumpAndSettle();
    final body = jsonDecode(sent.lastWhere((r) => r.method == 'POST').body) as Map<String, dynamic>;
    expect((body['vehicle_id'], body.containsKey('driver_id')), ('v1', false));

    await tester.pumpWidget(localized(Scaffold(
      body: VehicleTachoTag(key: const Key('nowy'), api: api(sent, lastVu: false), companyId: 'c1', vehicleId: 'v1'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Brak odczytu'), findsOneWidget);
  });

  testWidgets('karta kierowcy (edycja): skrót czasu pracy', (tester) async {
    await tester.pumpWidget(localized(Scaffold(
      body: TachoSummary(api: api([]), companyId: 'c1', driverId: 'd1'),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Jazda dzienna: 0:00 / 10:00 • Czas tygodniowy: 5:00 / 56:00 • naruszenia: 1'), findsOneWidget);
  });
}
