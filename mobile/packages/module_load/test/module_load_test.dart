import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_load/module_load.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

Map<String, dynamic> planJson({bool checked = false, bool wallOk = true}) => {
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
      'fits': !checked,
      'placed': [
        {'item': 0, 'x_m': 0, 'y_m': 0, 'length_m': 1.2, 'width_m': 0.8, 'weight_kg': 500, 'stop': 1},
      ],
      'unplaced': 0,
      'rows': [
        {'x_m': 0, 'length_m': 1.2, 'weight_kg': 500, 'straps': 2},
      ],
      'straps': 2,
      'cog_m': 6.6,
      'warnings': ['Uwaga testowa'],
      'body_code': 'XL',
      'reference': 'MT-1',
      'pallet_places': 33,
      'places_used': 28,
      'forces': {
        'mass_kg': 16500, 'mu': 0.3, 'forward_kN': 129.5, 'side_kN': 80.9, 'friction_kN': 48.6,
        'rest_forward_kN': 80.9, 'rest_side_kN': 32.4, 'wall_kN': 157.0, 'wall_holds': wallOk,
        'tension_daN': 7000, 'straps': 2, 'strap_daN': 400, 'ok': wallOk,
      },
      'tractor': {
        'front_kg': 6400, 'front_limit_kg': 7500, 'drive_kg': 10900, 'drive_limit_kg': 11500,
        'gvw_kg': 38400, 'gvw_limit_kg': 40000, 'drive_share': 0.284, 'estimated': true,
      },
      'equipment': [
        {'id': 'straps', 'required': 2},
        {'id': 'edges', 'required': 4},
        {'id': 'beams', 'required': 0},
        {'id': 'mats', 'required': 0},
        {'id': 'airbags', 'required': 0},
      ],
      'norms': [
        {'id': 'en12642', 'ok': true},
        {'id': 'en12195', 'ok': wallOk},
        {'id': 'vdi2700', 'ok': true},
        {'id': 'art61', 'ok': !checked},
      ],
      'estimated': true,
    };

void main() {
  late List<(String, String, Object?)> requests;
  late List<Uri> opened;

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          requests.add((request.method, request.url.path, body));
          if (request.url.path == '/api/vehicles') {
            return json([
              {'id': 'c1', 'name': 'Ciągnik', 'plate': 'WI 4022P', 'kind': 'tractor', 'trailer_id': 'n1'},
              {'id': 'n1', 'name': 'Naczepa', 'plate': 'KTA 1', 'kind': 'semitrailer'},
            ]);
          }
          if (request.url.path == '/api/m/load/plan/pdf') {
            return json({'path': '/api/shared/abc', 'filename': 'plan-MT-1'});
          }
          if (request.url.path.startsWith('/api/m/load/plan')) {
            return json(planJson(checked: request.url.path.endsWith('/check')));
          }
          return json(null, 404);
        }),
      );

  Future<void> open(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LoadPlanScreen(
          api: api(),
          linkOpener: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> calculate(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Weight each'), '500');
    await tester.ensureVisible(find.text('Calculate plan'));
    await tester.tap(find.text('Calculate plan'));
    await tester.pumpAndSettle();
  }

  setUp(() {
    requests = [];
    opened = [];
  });

  testWidgets('moduł: nazwa w języku', (tester) async {
    expect(LoadModule().name(const Locale('pl')), 'Plan załadunku');
    expect(LoadModule().name(const Locale('en')), 'Load plan');
    expect(LoadTexts(const Locale('pl')).menu, 'Zlecenia i załadunek');
  });

  testWidgets('zlecenie: zestaw w nagłówku, KPI, symulator, naciski, siły, sprzęt i normy', (tester) async {
    await open(tester, const Size(1400, 3200));
    expect(find.text('Naczepa · KTA 1'), findsOneWidget); // ciągnik bez przestrzeni – pominięty w wyborze
    expect(find.text('WI 4022P'), findsOneWidget); // … ale w nagłówku jako ciągnik naczepy
    await tester.enterText(find.widgetWithText(TextFormField, 'Order no.'), 'MT-1');
    await tester.tap(find.widgetWithText(DropdownButtonFormField<String>, 'None / unknown'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('EN 12642 code XL').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'Pieces'), '33');
    await calculate(tester);

    final sent = requests.singleWhere((r) => r.$2 == '/api/m/load/plan').$3 as Map;
    expect(sent['vehicle_id'], 'n1');
    expect((sent['body_code'], sent['reference']), ('XL', 'MT-1'));
    expect(sent['items'], [
      {'kind': 'euro', 'count': 33, 'weight_kg': 500.0, 'stack': 1, 'stop': 1},
    ]);
    expect(find.text('28 / 33'), findsOneWidget);
    expect(find.text('⚠ Uwaga testowa'), findsOneWidget);
    expect(find.byKey(const ValueKey('sim-view-iso')), findsOneWidget);
    expect(find.text('Axle load distribution'), findsOneWidget);
    expect(find.text('Axle 1 (tractor steer)'), findsOneWidget);
    expect(find.text('6.4 t / 7.5 t'), findsOneWidget);
    expect(find.text('28.4% of the combination weight on the drive axle (min. 25%)'), findsOneWidget);
    expect(find.text('Force balance EN 12195-1:2010'), findsOneWidget);
    expect(find.text('7,000 daN (2 straps)'), findsOneWidget);
    expect(find.text('Equipment and securing (VDI 2700 checklist)'), findsOneWidget);
    expect(find.text('LC 2500 daN / STF 400 daN, long-lever ratchet'), findsOneWidget);
    expect(find.text('Legal standards and vehicle certificates'), findsOneWidget);
    // VDI 2700 czeka na potwierdzenie sprzętu: 3 z 4.
    expect(find.text('3/4 met'), findsOneWidget);
    expect(find.text('Heavy (500 kg) • 1 pcs'), findsNothing);
    expect(find.text('Light (500 kg) • 1 pcs'), findsNothing);
    expect(find.text('Medium (500 kg) • 1 pcs'), findsOneWidget);
    expect(tester.getTopLeft(find.text('Axle load distribution')).dx, greaterThan(800));

    // Widoki: rzut z góry i przekrój.
    await tester.tap(find.byKey(const ValueKey('sim-top')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sim-view-top')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('sim-section')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sim-view-section')), findsOneWidget);
  });

  testWidgets('tryb sztaplowany: piętrowanie pozycji i plan od nowa', (tester) async {
    await open(tester, const Size(1400, 3200));
    await calculate(tester);
    await tester.tap(find.byKey(const ValueKey('sim-stacked')));
    await tester.pumpAndSettle();
    final plans = requests.where((r) => r.$2 == '/api/m/load/plan').toList();
    expect(plans, hasLength(2));
    expect(((plans.last.$3 as Map)['items'] as List).single['stack'], 2);
  });

  testWidgets('zatwierdzenie dopiero po potwierdzeniu sprzętu, eksport PDF ze stanem listy', (tester) async {
    await open(tester, const Size(1400, 3200));
    await calculate(tester);
    await tester.tap(find.text('Approve load plan'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Approval needs'), findsOneWidget);
    expect(find.text('Plan approved'), findsNothing);

    for (final id in ['straps', 'edges']) {
      await tester.ensureVisible(find.byKey(ValueKey('gear-$id')));
      await tester.tap(find.byKey(ValueKey('gear-$id')));
      await tester.pumpAndSettle();
    }
    expect(find.text('Equipment set verified'), findsOneWidget);
    expect(find.text('4/4 met'), findsOneWidget);
    await tester.ensureVisible(find.text('Approve load plan'));
    await tester.tap(find.text('Approve load plan'));
    await tester.pumpAndSettle();
    expect(find.text('Plan approved'), findsWidgets);

    await tester.tap(find.text('Export plan PDF/VDI'));
    await tester.pumpAndSettle();
    final pdf = requests.singleWhere((r) => r.$2 == '/api/m/load/plan/pdf').$3 as Map;
    expect(pdf['approved'], isTrue);
    expect(pdf['checked'], ['straps', 'edges']);
    expect(pdf.containsKey('placed'), isFalse);
    expect(opened.single.toString(), 'http://serwer.test/api/shared/abc');
  });

  testWidgets('telefon: wynik pod formularzem', (tester) async {
    await open(tester, const Size(700, 5000));
    await calculate(tester);
    expect(tester.getTopLeft(find.text('Axle load distribution')).dy,
        greaterThan(tester.getTopLeft(find.text('Calculate plan')).dy));
  });

  testWidgets('edycja ułożenia: przeciąganie palety → sprawdzenie norm', (tester) async {
    await open(tester, const Size(1400, 3200));
    await tester.enterText(find.widgetWithText(TextFormField, 'Height each'), '1,1');
    await calculate(tester);
    final sent = requests.singleWhere((r) => r.$2 == '/api/m/load/plan').$3 as Map;
    expect((sent['items'] as List).single['height_m'], 1.1);
    expect(find.text('9.0 t / 12.0 t'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('sim-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('deck-top')), findsOneWidget);
    expect(find.text('Side view'), findsOneWidget);
    await tester.tap(find.text('Move goods'));
    await tester.pumpAndSettle();
    // Paleta 1,2 × 0,8 m przy ścianie czołowej: przeciągnięcie w widoku z góry.
    final top = find.byKey(const ValueKey('deck-top'));
    await tester.ensureVisible(top);
    await tester.pumpAndSettle();
    final origin = tester.getTopLeft(top);
    final scale = tester.getSize(top).width / (13.6 + 3.2);
    final gesture = await tester.startGesture(origin + Offset((1.6 + 0.6) * scale, (1.6 + 0.4) * scale));
    await gesture.moveBy(Offset(2 * scale, 0));
    await gesture.moveBy(Offset(1 * scale, 0));
    await gesture.up();
    await tester.pumpAndSettle();

    final check = requests.singleWhere((r) => r.$2 == '/api/m/load/plan/check').$3 as Map;
    final moved = (check['placed'] as List).single as Map;
    expect(moved['x_m'], closeTo(3.0, 0.3));
    expect(find.text('21.0 t / 12.0 t'), findsOneWidget);

    // „Przelicz siły” zostawia ręczne ułożenie (sprawdzenie, nie nowy plan).
    await tester.ensureVisible(find.text('Recalculate inertia forces (EN 12195)'));
    await tester.tap(find.text('Recalculate inertia forces (EN 12195)'));
    await tester.pumpAndSettle();
    expect(requests.where((r) => r.$2 == '/api/m/load/plan/check'), hasLength(2));
  });
}
