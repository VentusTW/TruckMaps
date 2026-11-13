import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/live/assigned_route.dart';
import 'package:truckmaps_app/src/live/live_screen.dart';
import 'package:truckmaps_app/src/navigation/live_sharing.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';

import 'localized.dart';

http.Response json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: {'content-type': 'application/json'});

void main() {
  setUp(() => mapTiles = () => const SizedBox());

  test('pozycja wysyłana tylko dla pojazdu firmy i tylko za zgodą kierowcy', () async {
    final sent = <Map<String, dynamic>>[];
    CoreApi api(String? companyId) => CoreApi(
          baseUrl: 'http://serwer.test',
          token: 't',
          client: MockClient((request) async {
            if (request.method == 'GET') return json({'id': 'v1', 'company_id': companyId});
            sent.add(jsonDecode(request.body) as Map<String, dynamic>);
            return http.Response('', 204);
          }),
        );
    const fix = LiveFix(lat: 50.06, lon: 19.94, speedKmh: 72.46, heading: 370, remainingKm: 12.34);
    var asked = 0;
    Future<bool> ask(bool answer) async {
      asked++;
      return answer;
    }

    // Pojazd prywatny – bez pytania i bez wysyłania.
    final private = LiveSharing(
        api: api(null), vehicleId: 'v1', consent: MemoryLiveConsentStore(), ask: () => ask(true), current: () => fix);
    expect(await private.start(), isFalse);
    expect(asked, 0);

    // Kierowca odmawia – zapamiętane, przy kolejnej jeździe już nie pytamy.
    final store = MemoryLiveConsentStore();
    expect(
        await LiveSharing(api: api('c1'), vehicleId: 'v1', consent: store, ask: () => ask(false), current: () => fix)
            .start(),
        isFalse);
    expect(await LiveSharing(api: api('c1'), vehicleId: 'v1', consent: store, ask: () => ask(true), current: () => fix)
        .start(), isFalse);
    expect((asked, store.value), (1, false));
    expect(sent, isEmpty);

    // Zgoda: pozycja od razu, a na koniec jazdy – „zakończył jazdę”.
    final sharing = LiveSharing(
        api: api('c1'), vehicleId: 'v1', consent: MemoryLiveConsentStore(true), ask: () => ask(true), current: () => fix);
    expect(await sharing.start(), isTrue);
    await sharing.stop();
    expect(sent.first, {
      'lat': 50.06,
      'lon': 19.94,
      'speed_kmh': 72.5,
      'heading': 10,
      'remaining_km': 12.3,
      'driving': true,
    });
    expect(sent.last['driving'], isFalse);
  });

  testWidgets('centrala: pojazdy firmy z kierowcą, stanem i czasem przyjazdu', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = MockClient((request) async {
      if (request.url.path == '/api/companies/c1/route-assignments') return json([]);
      if (request.url.path == '/api/companies/c1') {
        return json({
          'id': 'c1',
          'members': [
            {'id': 'm1', 'display_name': 'Jan Kowalski', 'role': 'driver'},
          ],
        });
      }
      expect(request.url.path, '/api/companies/c1/live');
      return json([
        {
          'vehicle_id': 'v1',
          'name': 'MAN 01',
          'plate': 'KR1234A',
          'driver': 'Jan Kowalski',
          'lat': 50.06,
          'lon': 19.94,
          'speed_kmh': 72.0,
          'heading': 90.0,
          'destination': 'Lyon',
          'remaining_km': 120.4,
          'at': DateTime.now().toUtc().toIso8601String(),
          'state': 'driving',
        },
        {'vehicle_id': 'v2', 'name': 'Volvo 02', 'plate': null, 'state': 'no_signal'},
      ]);
    });
    await tester.pumpWidget(localized(Scaffold(
      body: LiveScreen(
        api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client),
        companyId: 'c1',
        refresh: const Duration(hours: 1),
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('W trasie: 1 z 2'), findsOneWidget);
    expect(find.text('MAN 01 · KR1234A'), findsOneWidget);
    expect(find.textContaining('Jan Kowalski · 72 km/h · → Lyon · 120 km do celu'), findsOneWidget);
    expect(find.textContaining('Brak sygnału · brak pozycji'), findsOneWidget);
    expect(find.text('KR1234A'), findsOneWidget); // znacznik na mapie

    // Planowanie trasy: start domyślnie w bieżącej pozycji pojazdu, do zmiany na dowolny.
    await tester.tap(find.byKey(const Key('plan-v1')));
    await tester.pumpAndSettle();
    expect(find.text('Trasa dla KR1234A'), findsOneWidget);
    expect(find.text('KR1234A (GPS)'), findsOneWidget);
    expect(find.byKey(const Key('plan-calculate')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  test('trasa od dyspozytora: od startu albo od mojej pozycji z dojazdem do startu', () {
    final assignment = {
      'origin': {'lat': 50.06, 'lon': 19.94, 'label': 'Baza Kraków'},
      'via': [
        {'lat': 50.3, 'lon': 19.0, 'label': 'Załadunek Katowice'},
      ],
      'destination': {'lat': 45.76, 'lon': 4.83, 'label': 'Lyon'},
    };

    final (from, via, names) = assignedStops(assignment, AssignedStart.planned);
    expect(from, {'lat': 50.06, 'lon': 19.94});
    expect(names, ['Załadunek Katowice']);
    expect(via.length, 1);

    final (fromHere, viaHere, namesHere) =
        assignedStops(assignment, AssignedStart.myPosition, position: const LatLng(52.4, 16.9));
    expect(fromHere, {'lat': 52.4, 'lon': 16.9});
    expect(namesHere, ['Baza Kraków', 'Załadunek Katowice']);
    expect(viaHere.first, {'lat': 50.06, 'lon': 19.94});
  });
}
