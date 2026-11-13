import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truckmaps_app/src/l10n.dart';
import 'package:truckmaps_app/src/service/fleet_export.dart';
import 'package:truckmaps_app/src/service/service_data.dart';

void main() {
  test('raport floty w CSV: nagłówki z tłumaczeń, koszty w każdej walucie, polski przecinek', () {
    final l = lookupAppLocalizations(const Locale('pl'));
    final data = FleetData(
      vehicles: [
        {'id': 'v1', 'name': 'MAN TGX', 'plate': 'KR 1234A', 'kind': 'tractor'},
        {'id': 't1', 'name': 'Naczepa', 'kind': 'semitrailer'},
      ],
      orders: const [],
      stats: {
        'v1': {
          'trips': 3,
          'distance_km': 1234.5,
          'hours': 20.25,
          'empty_km': 100,
          'idle_hours': 1.5,
          'costs': {'EUR': 500.0, 'PLN': 120.0},
          'cost_per_km': {'EUR': 0.405, 'PLN': 0.1},
        },
      },
    );

    final rows = fleetReportRows(l, data, (id) => id == 'v1' ? 300 : 0);
    expect(rows.first, containsAllInOrder(['Pojazd', 'Nr rejestracyjny', 'VIN', 'Przejazdy']));
    expect(rows.first, containsAll(['Koszt przejazdów [EUR]', 'Koszt / km [PLN]', 'Koszt serwisu']));
    expect(rows.length, 2); // naczepa nie jest pojazdem z napędem
    expect(rows[1], containsAllInOrder(['MAN TGX', 'KR 1234A', '', '3', '1234,5', '20,3']));
    expect(rows[1].last, '300,00');

    final csv = toCsv([
      ['a;b', 'zwykły "tekst"'],
    ]);
    expect(csv, '﻿"a;b";"zwykły ""tekst"""\r\n');
  });
}
