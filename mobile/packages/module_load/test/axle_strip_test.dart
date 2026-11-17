import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:module_load/src/axle_strip.dart';
import 'package:module_load/src/panels.dart';
import 'package:module_load/src/sim_view.dart';
import 'package:module_load/src/texts.dart';

Map<String, dynamic> axle(String id, double x, num load, num limit, String status, {num? min}) => {
      'id': id,
      'x_m': x,
      'load_kg': load,
      'limit_kg': limit,
      'ratio': load / limit,
      'status': status,
      'min_kg': min,
    };

/// Zestaw: oś napędowa przeciążona, osie naczepy ponad 90 %, 23 % masy na napędowej.
Map<String, dynamic> vehicle({bool steerLow = false}) => {
      'kind': 'combination',
      'axles': [
        axle('steer', -1.6, steerLow ? 2000 : 6700, 7500, 'ok', min: 3500),
        axle('drive', 2.2, 11900, 11500, 'over', min: 9000),
        axle('trailer', 9.52, 22000, 24000, 'warn'),
      ],
      'tractor_kg': 18600,
      'tractor_limit_kg': 18000,
      'gross_kg': 40600,
      'gross_limit_kg': 40000,
      'drive_share': 0.23,
      'drive_min_share': 0.25,
      'cog_m': 6.1,
      'problems': ['over_drive', 'tractor', 'gross', 'drive_share'],
    };

Map<String, dynamic> plan(Map<String, dynamic> v) => {
      'deck_length_m': 13.6,
      'deck_width_m': 2.48,
      'inner_height_m': 2.7,
      'cog_m': 6.1,
      'placed': [
        {'item': 0, 'x_m': 0.0, 'y_m': 0.0, 'length_m': 1.2, 'width_m': 0.8, 'weight_kg': 800, 'stop': 1},
      ],
      'rows': const [],
      'axles': [
        {'name': 'kingpin', 'x_m': 1.6, 'load_kg': 11000, 'limit_kg': 12000, 'over': false},
        {'name': 'trailer_axles', 'x_m': 9.52, 'load_kg': 22000, 'limit_kg': 24000, 'over': false},
      ],
      'vehicle': v,
    };

Future<void> show(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: TruckTheme.light(),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  ));
}

void main() {
  testWidgets('pasek nacisków: każda oś z wartością i procentem, kolory wg limitu, udział napędowej', (tester) async {
    await show(tester, AxleStrip(vehicle: vehicle()));
    expect(find.text('Tractor weight'), findsOneWidget);
    expect(find.text('18.6 t'), findsOneWidget);
    expect(find.text('40.6 t'), findsOneWidget);
    expect(find.text('Steer axle'), findsOneWidget);
    expect(find.text('6.7 t · 89%'), findsOneWidget);
    expect(find.text('11.9 t · 103%'), findsOneWidget);
    expect(find.text('22.0 t · 92%'), findsOneWidget);
    expect(find.text('Drive axle: 23% of gross weight (min. 25%)'), findsOneWidget);
    final context = tester.element(find.byType(AxleStrip));
    Color? color(String text) => tester.widget<Text>(find.text(text)).style?.color;
    expect(color('11.9 t · 103%'), Theme.of(context).colorScheme.error);
    expect(color('22.0 t · 92%'), TruckColors.of(context).warning);
    expect(color('6.7 t · 89%'), TruckColors.of(context).success);
    expect(find.byKey(const ValueKey('axle-strip-steer-low')), findsNothing);
  });

  testWidgets('pasek nacisków: za mało na osi kierowanej; solo bez masy ciągnika', (tester) async {
    await show(tester, AxleStrip(vehicle: vehicle(steerLow: true)));
    expect(find.text('Too little on the steer axle – min. 3.5 t'), findsOneWidget);
    await show(
      tester,
      AxleStrip(vehicle: {
        'kind': 'rigid',
        'axles': [axle('front', -1.2, 5000, 7500, 'ok', min: 3000), axle('rear', 4.0, 9000, 11500, 'ok')],
        'gross_kg': 14000,
        'gross_limit_kg': 18000,
        'drive_share': 0.64,
        'drive_min_share': 0.25,
        'problems': const [],
      }),
    );
    expect(find.text('Tractor weight'), findsNothing);
    expect(find.text('Front axle'), findsOneWidget);
    expect(find.text('Rear axles'), findsOneWidget);
  });

  testWidgets('panel nacisków: osie pojazdu, siodło, masa ciągnika i DMC; stan „do korekty”', (tester) async {
    final p = plan(vehicle());
    await show(tester, AxlePanel(plan: p));
    expect(find.text('Steer axle'), findsOneWidget);
    expect(find.text('Drive axle'), findsOneWidget);
    expect(find.text('Trailer axles'), findsOneWidget);
    expect(find.text('Fifth wheel'), findsOneWidget);
    expect(find.text('11.9 t / 11.5 t'), findsOneWidget);
    expect(find.text('Axle 1 (tractor steer)'), findsNothing);
    expect(find.text('40.6 t'), findsOneWidget);
    expect(cogBalanced(p), isFalse);
    expect(LoadTexts(const Locale('pl')).axleName('steer'), 'Oś kierowana');
  });

  testWidgets('przekrój: koła w miejscu osi z naciskami i środek ciężkości', (tester) async {
    for (final v in [vehicle(), null]) {
      final p = plan(v ?? {})..remove(v == null ? 'vehicle' : '');
      await show(
        tester,
        SizedBox(
          width: 900,
          height: 380,
          child: CustomPaint(
            painter: SimPainter(
              scene: SimScene(p, const []),
              view: SimView.section,
              straps: false,
              vectors: false,
              texts: LoadTexts(const Locale('en')),
              dark: false,
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    }
    expect(SimScene(plan(vehicle()), const []).vehicleAxles.length, 3);
  });
}
