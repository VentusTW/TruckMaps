import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truckmaps_app/src/drivers/eco_score.dart';
import 'package:truckmaps_app/src/service/analytics_cards.dart';

import 'localized.dart';

Widget page(Widget child) => localized(Scaffold(body: SingleChildScrollView(child: child)));

void main() {
  final orders = [
    {'label': 'Kraków → Lyon', 'vehicle_id': 'v1', 'distance_km': 1450, 'value': 9000},
    {'label': 'Kraków → Lyon', 'vehicle_id': 'v2', 'distance_km': 1450, 'value': 9500},
    {'label': 'Kraków → Berlin', 'vehicle_id': 'v1', 'distance_km': 600, 'value': null},
    {'label': '', 'vehicle_id': 'v1', 'distance_km': 10, 'value': 50},
  ];

  test('korytarze: grupowanie relacji, filtr pojazdów, kolejność po liczbie kursów', () {
    final all = corridorsFrom(orders);
    expect([for (final c in all) c.label], ['Kraków → Lyon', 'Kraków → Berlin']);
    expect((all.first.trips, all.first.km, all.first.revenue), (2, 2900.0, 18500.0));
    expect(all.last.revenue, 0);
    final v2 = corridorsFrom(orders, vehicleIds: {'v2'});
    expect((v2.single.trips, v2.single.revenue), (1, 9500.0));
  });

  testWidgets('karta korytarzy: relacje z kursami i przychodem; brak tras i brak dostępu', (tester) async {
    await tester.pumpWidget(page(CorridorsCard(corridors: corridorsFrom(orders))));
    expect(find.text('Korytarze tras'), findsOneWidget);
    expect(find.text('Kraków → Lyon'), findsOneWidget);
    expect(find.textContaining('2 kursów •'), findsOneWidget);
    expect(find.textContaining('Przychód 18'), findsOneWidget);
    expect(find.text('Bez wpisanego przychodu'), findsOneWidget);
    expect(find.textContaining('W budowie'), findsNothing);

    await tester.pumpWidget(page(const CorridorsCard(corridors: [])));
    expect(find.text('Brak tras od dyspozytora w tym okresie.'), findsOneWidget);
  });

  testWidgets('karta zgodności: moduł nieaktywny, naruszenia 561/2006 i terminy dokumentów', (tester) async {
    final today = DateTime(2026, 11, 16);
    final vehicles = [
      {'id': 'v1', 'plate': 'WI 4022P', 'inspection_until': '2026-11-10', 'insurance_until': '2027-06-01'},
      {'id': 'v2', 'plate': 'KR 1234A', 'insurance_until': '2026-12-01'},
    ];
    await tester.pumpWidget(page(ComplianceCard(compliance: null, vehicles: vehicles, today: today)));
    expect(find.textContaining('Moduł Kierowcy jest nieaktywny'), findsOneWidget);
    expect(find.text('Terminy dokumentów: 1 po terminie, 1 wkrótce'), findsOneWidget);
    expect(find.textContaining('WI 4022P: '), findsOneWidget);

    final compliance = {
      'days': 28,
      'drivers': [
        {'has_data': true, 'violations': 3, 'serious': 2, 'very_serious': 1, 'dues_soon': 1, 'dues_overdue': 0},
        {'has_data': true, 'violations': 0, 'serious': 0, 'very_serious': 0, 'dues_soon': 0, 'dues_overdue': 1},
        {'has_data': false, 'violations': 0, 'serious': 0, 'very_serious': 0},
      ],
    };
    await tester.pumpWidget(page(ComplianceCard(compliance: compliance, vehicles: const [], today: today)));
    expect(find.text('Naruszenia 561/2006: 3 (ostatnie 28 dni danych)'), findsOneWidget);
    expect(find.text('Poważne: 2 • bardzo poważne: 1'), findsOneWidget);
    expect(find.text('Kierowcy z naruszeniami: 1 z 2'), findsOneWidget);
    expect(find.text('Terminy dokumentów: 1 po terminie, 1 wkrótce'), findsOneWidget);

    await tester.pumpWidget(page(const ComplianceCard(compliance: {'days': 28, 'drivers': []}, vehicles: [])));
    expect(find.textContaining('Brak danych z tachografu'), findsOneWidget);
    expect(find.text('Wszystkie terminy dokumentów aktualne.'), findsOneWidget);
  });

  test('eco-score: składniki i przeskalowanie bez spalania', () {
    final stats = {
      'distance_km': 1000,
      'empty_km': 100,
      'hours': 20,
      'idle_hours': 2,
      'by_vehicle': [
        {'vehicle_id': 'v1', 'distance_km': 1000}
      ],
    };
    // Kursy puste 10% → 30/40, bezczynność 10% → 23,3/35, spalanie 31 l → 15/25.
    final full = ecoScore(stats, [
      {'id': 'v1', 'consumption_loaded': 31}
    ])!;
    expect([for (final p in full.parts) p.key], ['empty', 'idle', 'fuel']);
    expect(full.score, 68);
    // Bez spalania pojazdu: (30 + 23,3) / 75.
    expect(ecoScore(stats, const [])!.score, 71);
    expect(ecoScore({'distance_km': 0}, const []), isNull);
  });

  testWidgets('eco-score: ocena, składniki i zastrzeżenie o przybliżeniu', (tester) async {
    await tester.pumpWidget(page(
        const EcoScoreView(stats: {'distance_km': 1000, 'empty_km': 0, 'hours': 10, 'idle_hours': 0}, vehicles: [])));
    expect(find.text('100/100'), findsOneWidget);
    expect(find.text('Kursy puste 0%: 40/40 pkt'), findsOneWidget);
    expect(find.textContaining('bez danych CAN'), findsOneWidget);

    await tester.pumpWidget(page(const EcoScoreView(stats: {'distance_km': 0}, vehicles: [])));
    expect(find.text('Za mało przejazdów do oceny.'), findsOneWidget);
  });
}
