import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truckmaps_app/main.dart';

import 'widget_test.dart' show big, session, settle;

void main() {
  testWidgets('„Cofnij” i ścieżka w górnym pasku prowadzą do poprzednich ekranów', (tester) async {
    big(tester);
    await tester.pumpWidget(TruckMapsApp(
      locale: const Locale('pl'),
      session: session({
        '/api/me/settings': {'display_name': 'Anna Kowalska'},
        '/api/companies': [
          {'id': 'c1', 'name': 'Trans', 'role': 'owner'}
        ],
        '/api/vehicles': [
          {'id': 'v1', 'plate': 'KTA 43532', 'name': 'Ciągnik', 'kind': 'tractor', 'company_id': 'c1'}
        ],
      }),
    ));
    await settle(tester);
    IconButton back() => tester.widget<IconButton>(find.byKey(const Key('main-back')));
    expect(back().onPressed, isNull); // brak historii

    // Pojazdy i Tabor › Przeglądy UDT/TDT („W budowie”).
    await tester.tap(find.text('Pojazdy i Tabor'));
    await settle(tester);
    await tester.tap(find.text('Przeglądy UDT/TDT'));
    await settle(tester);
    expect(find.text('W BUDOWIE'), findsOneWidget);
    expect(find.byKey(const Key('crumb-0')), findsOneWidget);
    expect(find.byKey(const Key('crumb-1')), findsOneWidget);

    // Klik w „katalog” ścieżki – powrót do taboru.
    await tester.tap(find.byKey(const Key('crumb-0')));
    await settle(tester);
    expect(find.text('Tabor Samochodowy i Sprzęt'), findsOneWidget);
    expect(find.byKey(const Key('crumb-1')), findsNothing);

    // „Cofnij” – z powrotem do klikniętego pojazdu, potem do taboru i na pulpit.
    await tester.tap(find.byKey(const Key('main-back')));
    await settle(tester);
    expect(find.text('W BUDOWIE'), findsOneWidget);
    await tester.tap(find.byKey(const Key('main-back')));
    await settle(tester);
    expect(find.text('Tabor Samochodowy i Sprzęt'), findsOneWidget);

    // Boczny przycisk myszy „wstecz”.
    final gesture =
        await tester.startGesture(const Offset(800, 400), buttons: kBackMouseButton, kind: PointerDeviceKind.mouse);
    await gesture.up();
    await settle(tester);
    expect(find.text('Dzień dobry, Anna'), findsOneWidget);
    expect(back().onPressed, isNull);
  });
}
