import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_load/module_load.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  late List<(String, String, Object?)> requests;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          requests.add((request.method, request.url.path, body));
          if (request.url.path == '/api/vehicles') {
            return json([
              {'id': 'c1', 'name': 'Ciągnik', 'kind': 'tractor'},
              {'id': 'n1', 'name': 'Naczepa', 'plate': 'KTA 1', 'kind': 'semitrailer'},
            ]);
          }
          if (request.url.path.startsWith('/api/m/load/plan')) {
            final checked = request.url.path.endsWith('/check');
            return json({
              'inner_height_m': 2.7,
              'axles': [
                {'name': 'kingpin', 'x_m': 1.6, 'load_kg': checked ? 21000 : 9000, 'limit_kg': 12000, 'over': checked},
                {'name': 'trailer_axles', 'x_m': 9.52, 'load_kg': 15000, 'limit_kg': 24000, 'over': false},
              ],
              'offset_m': 0,
              'adjusted': false,
              'deck_length_m': 13.6,
              'deck_width_m': 2.48,
              'ldm': 13.64,
              'used_length_m': 13.2,
              'weight_kg': 16500,
              'payload_kg': 32000,
              'fits': true,
              'placed': [
                {'item': 0, 'x_m': 0, 'y_m': 0, 'length_m': 1.2, 'width_m': 0.8, 'weight_kg': 500, 'stop': 1},
              ],
              'unplaced': 0,
              'rows': <Object>[],
              'straps': 11,
              'cog_m': 6.6,
              'warnings': ['Uwaga testowa'],
              'estimated': true,
            });
          }
          return json(null, 404);
        }),
      );

  setUp(() => requests = []);

  testWidgets('moduł: nazwa w języku', (tester) async {
    expect(LoadModule().name(const Locale('pl')), 'Plan załadunku');
    expect(LoadModule().name(const Locale('en')), 'Load plan');
  });

  testWidgets('plan: pojazd z przestrzenią ładunkową, pozycja, wynik z ostrzeżeniem', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LoadPlanScreen(api: api()))));
    await tester.pumpAndSettle();

    expect(find.text('Naczepa · KTA 1'), findsOneWidget); // ciągnik bez przestrzeni – pominięty
    await tester.enterText(find.widgetWithText(TextFormField, 'Pieces'), '33');
    await tester.enterText(find.widgetWithText(TextFormField, 'Weight each'), '500');
    await tester.tap(find.text('Calculate plan'));
    await tester.pumpAndSettle();

    final sent = requests.singleWhere((r) => r.$2 == '/api/m/load/plan').$3 as Map;
    expect(sent['vehicle_id'], 'n1');
    expect(sent['items'], [
      {'kind': 'euro', 'count': 33, 'weight_kg': 500.0, 'stack': 1, 'stop': 1},
    ]);
    expect(find.text('Fits'), findsOneWidget);
    expect(find.text('13.64 LDM · 13.2 of 13.6 m used'), findsOneWidget);
    expect(find.text('⚠ Uwaga testowa'), findsOneWidget);
    expect(find.byType(CustomPaint), findsWidgets);
  });

  testWidgets('naciski na osie, widok z boku i przeciąganie palety → sprawdzenie norm', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LoadPlanScreen(api: api()))));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Weight each'), '500');
    await tester.enterText(find.widgetWithText(TextFormField, 'Height each'), '1,1');
    await tester.tap(find.text('Calculate plan'));
    await tester.pumpAndSettle();
    final sent = requests.singleWhere((r) => r.$2 == '/api/m/load/plan').$3 as Map;
    expect((sent['items'] as List).single['height_m'], 1.1);
    expect(find.text('Fifth wheel: 9.0 t of 12.0 t allowed'), findsOneWidget);
    expect(find.byKey(const ValueKey('deck-3d')), findsOneWidget); // jeden rysunek 3D

    // Widok z góry, tryb przesuwania towaru: paleta 1,2 × 0,8 m przy ścianie czołowej o 3 m do tyłu.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Top'));
    await tester.tap(find.text('Move goods'));
    await tester.pumpAndSettle();
    final deck = find.byKey(const ValueKey('deck-3d'));
    await tester.ensureVisible(deck);
    await tester.pumpAndSettle();
    final camera = DeckCamera(size: tester.getSize(deck), length: 13.6, width: 2.48, height: 2.7);
    final origin = tester.getTopLeft(deck);
    final from = origin + camera.project((0.6, 0.4, 0)), to = origin + camera.project((3.6, 0.4, 0));
    final gesture = await tester.startGesture(from);
    await gesture.moveTo(from + (to - from) / 2);
    await gesture.moveTo(to);
    await gesture.up();
    await tester.pumpAndSettle();

    final check = requests.singleWhere((r) => r.$2 == '/api/m/load/plan/check').$3 as Map;
    final moved = (check['placed'] as List).single as Map;
    expect(moved['x_m'], closeTo(3.0, 0.1));
    expect(moved['y_m'], closeTo(0.0, 0.1));
    expect(find.text('Fifth wheel: 21.0 t of 12.0 t allowed'), findsOneWidget);
  });

  testWidgets('obracanie i pochylanie naczepy przeciągnięciem, ustawienia widoku, Shift + kółko', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: LoadPlanScreen(api: api()))));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Weight each'), '500');
    await tester.tap(find.text('Calculate plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('rotation 331° · tilt 34° · 100%'), findsOneWidget); // 3D z ukosa

    await tester.tap(find.widgetWithText(OutlinedButton, 'Side'));
    await tester.pump();
    expect(find.text('rotation 0° · tilt 0° · 100%'), findsOneWidget);

    final view = find.byKey(const ValueKey('deck-view'));
    await tester.ensureVisible(view);
    await tester.drag(view, const Offset(150, -250)); // obrót ok. 90°, pochylenie aż do widoku z góry
    await tester.pump();
    expect(find.textContaining('tilt 90°'), findsOneWidget);
    expect(find.textContaining('rotation 0°'), findsNothing);

    // Shift + kółko myszy w górę – przybliżenie; samo kółko – bez zmiany przybliżenia.
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    final at = tester.getCenter(view);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await tester.pump();
    expect(find.textContaining('· 100%'), findsOneWidget);
    await simulateKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -100)));
    await simulateKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.textContaining('· 110%'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Top'));
    await tester.pump();
    expect(find.text('rotation 0° · tilt 90° · 100%'), findsOneWidget);
  });

  test('rzut kamery: z góry i z boku, punkt podłogi pod palcem', () {
    final top = DeckCamera(size: const Size(800, 400), length: 13.6, width: 2.48, height: 2.7);
    final front = top.project((0, 0, 0)), back = top.project((13.6, 0, 0));
    expect(back.dx, greaterThan(front.dx)); // przód po lewej
    expect(top.project((0, 2.48, 0)).dy, lessThan(front.dy)); // lewa burta na dole
    final floor = top.floorAt(top.project((5, 1, 0)))!;
    expect(floor.$1, closeTo(5, 1e-6));
    expect(floor.$2, closeTo(1, 1e-6));
    final side = DeckCamera(size: const Size(800, 400), length: 13.6, width: 2.48, height: 2.7, pitch: 0);
    expect(side.project((0, 0, 2.7)).dy, lessThan(side.project((0, 0, 0)).dy)); // wysokość w górę
    expect(side.floorAt(const Offset(400, 200)), isNull); // z boku tylko wzdłuż
  });
}
