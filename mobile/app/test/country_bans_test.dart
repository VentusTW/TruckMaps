import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/planner/clusters.dart';
import 'package:truckmaps_app/src/planner/country_bans_screen.dart';

import 'localized.dart';

void main() {
  testWidgets('zakazy kraju: dni, święta regionalne, wyjątki; zmiana kraju', (tester) async {
    final asked = <String>[];
    final client = MockClient((request) async {
      asked.add(request.url.path);
      final de = request.url.path.endsWith('/DE');
      return http.Response.bytes(
          utf8.encode(jsonEncode({
            'country': de ? 'DE' : 'PL',
            'name': de ? 'Niemcy' : 'Polska',
            'known': true,
            'vehicles': 'Pojazdy powyżej 12 t.',
            'exceptions': 'Przewóz kombinowany.',
            'days': [
              if (!de)
                {
                  'day': '2026-11-11',
                  'starts_at': '2026-11-11T08:00:00+01:00',
                  'ends_at': '2026-11-11T22:00:00+01:00',
                  'title': 'święto (Narodowe Święto Niepodległości)',
                  'roads': 'wszystkie drogi',
                  'verified': true,
                },
            ],
            'regional': [
              if (de)
                {
                  'day': '2026-11-01',
                  'name': 'Allerheiligen',
                  'regions': ['BW', 'BY']
                },
            ],
          })),
          200);
    });
    await tester
        .pumpWidget(localized(CountryBansScreen(api: CoreApi(baseUrl: 'http://s.test', token: 't', client: client))));
    await tester.pumpAndSettle();
    expect(find.text('Zakazy ruchu: Polska'), findsOneWidget);
    expect(find.textContaining('Narodowe Święto Niepodległości'), findsOneWidget);
    expect(find.text('Przewóz kombinowany.'), findsOneWidget);

    await tester.tap(find.text('DE'));
    await tester.pumpAndSettle();
    expect(asked.last, '/api/timebans/DE');
    expect(find.text('W tym okresie brak zakazów.'), findsOneWidget);
    expect(find.textContaining('Allerheiligen: BW, BY'), findsOneWidget);
  });

  test('skupianie punktów: blisko – razem, daleko – osobno, przy dużym przybliżeniu osobno', () {
    const points = [LatLng(50, 20), LatLng(50.001, 20.001), LatLng(51, 21)];
    expect(clusterIndices(points, 8).map((g) => g.length).toList()..sort(), [1, 2]);
    expect(clusterIndices(points, 18).length, 3);
  });
}
