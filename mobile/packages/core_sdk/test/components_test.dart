import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Domyślny rozmiar testu (800 × 600) – układ komputerowy.
Widget _app(Widget child) => MaterialApp(theme: TruckTheme.light(), home: child);

void main() {
  test('motyw: kolory i czcionki z projektu, karty bez obramowań, ciemny z tych samych kolorów', () {
    final light = TruckTheme.light();
    expect(light.colorScheme.primary, const Color(0xFF00288E));
    expect(light.colorScheme.surface, const Color(0xFFF8F9FF));
    expect(light.textTheme.bodyMedium?.fontFamily, TruckFonts.body);
    expect(light.textTheme.titleLarge?.fontFamily, TruckFonts.headline);
    expect(light.textTheme.labelSmall?.fontSize, 11);
    final card = light.cardTheme.shape! as RoundedRectangleBorder;
    expect(card.side, BorderSide.none);
    expect(card.borderRadius, BorderRadius.circular(TruckTheme.radius));
    final dark = TruckTheme.dark();
    expect(dark.colorScheme.surface, light.colorScheme.onSurface);
    expect(dark.extension<TruckColors>(), TruckColors.dark);
  });

  testWidgets('komponenty: KPI, chip, kafelek, baner, pozycja listy', (tester) async {
    var tapped = 0;
    await tester.pumpWidget(_app(Scaffold(
      body: ListView(children: [
        const KpiCard(label: 'Pojazdy', value: '12', icon: Icons.local_shipping, status: '3 w użyciu'),
        const StatusChip(label: 'w trasie'),
        const StatusChip(label: 'Bez problemów', uppercase: false, tone: StatusTone.ok),
        const ValueTile(label: 'DMC', value: '40', unit: 't', progress: 0.5),
        AlertBanner(title: 'Awaria', onTap: () => tapped++),
        const IconListTile(icon: Icons.build, title: 'Serwis', subtitle: 'za 14 dni'),
      ]),
    )));
    expect(find.text('POJAZDY'), findsOneWidget);
    expect(find.text('3 w użyciu'), findsOneWidget);
    expect(find.text('W TRASIE'), findsOneWidget);
    expect(find.text('Bez problemów'), findsOneWidget);
    expect(find.byType(TruckProgressBar), findsOneWidget);
    await tester.tap(find.text('Awaria'));
    expect(tapped, 1);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('układ: komputer – menu boczne 288 px; wyłączona pozycja nie reaguje', (tester) async {
    final chosen = <String>[];
    await tester.pumpWidget(_app(TruckShell(
      title: 'Pulpit',
      items: const [
        ShellItem('a', 'Pulpit', Icons.dashboard),
        ShellItem('b', 'Trasa', Icons.route),
        ShellItem('c', 'Tachograf', Icons.timer, enabled: false),
      ],
      selected: 'a',
      onSelect: chosen.add,
      body: const Text('treść'),
    )));
    expect(tester.getSize(find.ancestor(of: find.text('Trasa'), matching: find.byType(SizedBox)).last).width,
        TruckTheme.sideMenuWidth);
    await tester.tap(find.text('Trasa'));
    await tester.tap(find.text('Tachograf'));
    expect(chosen, ['b']);
  });

  testWidgets('układ: telefon – dolna nawigacja z wyłączonymi zakładkami', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final chosen = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: TruckTheme.light(),
      home: TruckShell(
        title: 'Trasa',
        items: const [ShellItem('route', 'Trasa', Icons.route)],
        bottomItems: const [
          ShellItem('route', 'Trasa', Icons.route),
          ShellItem('tacho', 'Tachograf', Icons.timer, enabled: false),
          ShellItem('vehicle', 'Pojazd', Icons.local_shipping),
        ],
        selected: 'route',
        onSelect: chosen.add,
        body: const SizedBox(),
      ),
    ));
    await tester.tap(find.byKey(const Key('bottom-tacho')));
    await tester.tap(find.byKey(const Key('bottom-vehicle')));
    expect(chosen, ['vehicle']);
  });
}
