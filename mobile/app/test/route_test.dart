import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:truckmaps_app/src/l10n.dart';
import 'package:truckmaps_app/src/planner/place_field.dart';
import 'package:truckmaps_app/src/planner/route.dart';

void main() {
  test('odpowiedź planera: kolory odcinków, ostrzeżenia, zakazy, koszt', () {
    final result = RouteResult.fromJson({
      'distance_km': 125.4,
      'duration_min': 95.0,
      'geometry': [[20.0, 50.0], [20.1, 50.0], [20.2, 50.1], [20.3, 50.1]],
      'analysis': {
        'level': 'orange',
        'segments': [
          {'start_index': 0, 'end_index': 1, 'level': 'green'},
          {'start_index': 1, 'end_index': 3, 'level': 'orange'},
        ],
        'warnings': [
          {'level': 'orange', 'message': 'Ulica osiedlowa', 'km': 12.3, 'lat': 50.0, 'lon': 20.1, 'limit': null},
        ],
      },
      'cost': {'amount': 432.5, 'currency': 'PLN'},
      'alternatives': [
        {'distance_km': 130.0, 'duration_min': 99.0, 'geometry': [[20.0, 50.0], [20.3, 50.1]], 'analysis': null},
      ],
      'stop_issues': [{'message': 'Trudny dojazd do celu'}],
      'time_bans': {
        'bans': [{'message': 'Zakaz ruchu w Polsce', 'km': 50.0, 'lat': 50.05, 'lon': 20.15}],
        'arrival': '2026-11-01T22:00:00+01:00',
        'wait_min': 240,
        'free_departure': '2026-11-01T22:00:00+01:00',
      },
    });

    final route = result.route;
    expect(route.coloredParts.map((p) => (p.$1.length, p.$2)), [(2, 'green'), (3, 'orange')]);
    expect(route.summary(lookupAppLocalizations(const Locale('pl'))), '125 km · 1 h 35 min · ≈ 433 zł');
    expect(route.summary(lookupAppLocalizations(const Locale('en'))), '125 km · 1 h 35 min · ≈ 433 PLN');
    expect(route.warnings.single.km, 12.3);
    expect(result.alternatives.single.coloredParts.single.$2, 'unknown');
    expect(result.timeBans.single.level, 'ban');
    expect(result.waitMin, 240);
    expect(result.issues, ['Trudny dojazd do celu']);
    expect(result.freeDeparture, isNotNull);
  });

  test('koszt: paliwo i AdBlue ze spalania pojazdu, rozbicie na kraje', () async {
    await initializeDateFormatting('pl');
    final pl = lookupAppLocalizations(const Locale('pl'));
    final cost = Cost.fromJson({'amount': 235.29, 'currency': 'EUR', 'fuel': 139.5, 'adblue': 2.79, 'consumption': 30});
    expect(cost!.summaryParts(pl), 'w tym paliwo ≈ 140 EUR (30/100 km), AdBlue ≈ 3 EUR');
    expect(Cost.fromJson({'amount': 93.0, 'currency': 'EUR'})!.summaryParts(pl), isNull);
    final m4 = Cost.fromJson({
      'amount': 300.0,
      'currency': 'EUR',
      'fuel': 190.0,
      'consumption': 30,
      'fuel_prices_day': '2026-10-26',
      'parts': [
        {'kind': 'fuel', 'amount': 53.4, 'country': 'PL', 'km': 100},
        {'kind': 'toll', 'amount': 13.2, 'country': 'PL', 'km': 100},
        {'kind': 'fuel', 'amount': 137.9, 'country': 'DE', 'km': 200},
        {'kind': 'toll', 'amount': 0, 'country': 'CZ', 'km': 50, 'unknown': true},
      ],
    })!;
    expect(m4.countryLines(pl), [
      'PL: paliwo ≈ 53 EUR, myto ≈ 13 EUR (100 km)',
      'DE: paliwo ≈ 138 EUR',
      'CZ: myto – 50 km płatnych dróg, kwota w kalkulatorze operatora',
      'ceny ON z biuletynu KE z 26.10.2026',
    ]);
  });

  test('współrzędne GPS w polu adresu', () {
    expect(parseCoords('50.0131, 21.0214')?.point.latitude, 50.0131);
    expect(parseCoords('50, 21'), isNull);
    expect(parseCoords('Tarnów'), isNull);
  });
}
