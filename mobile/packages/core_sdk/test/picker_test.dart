import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _texts = PickerTexts(title: 'Rodzaj', search: 'Szukaj', empty: 'Nic nie znaleziono', all: 'Wszystkie');

const _groups = [
  PickerGroup('Ogólne', [PickerOption('curtain', 'Plandeka'), PickerOption('mega', 'Mega', subtitle: '3 m')]),
  PickerGroup('Płyny', [PickerOption('tanker', 'Cysterna'), PickerOption('tanker_food', 'Cysterna spożywcza')]),
];

void main() {
  testWidgets('wybór z grupami: wyszukiwanie, filtr grupy, zwrot wartości', (tester) async {
    String? picked;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async =>
              picked = await showGroupedPicker<String>(context, texts: _texts, groups: _groups, selected: 'curtain'),
          child: const Text('otwórz'),
        ),
      ),
    ));
    await tester.tap(find.text('otwórz'));
    await tester.pumpAndSettle();
    expect(find.text('OGÓLNE'), findsOneWidget);
    expect(find.text('PŁYNY'), findsOneWidget);
    // Filtry grup: wszystkie widoczne w całości, z liczbą pozycji.
    for (final key in ['picker-group-null', 'picker-group-0', 'picker-group-1']) {
      final chip = tester.getRect(find.byKey(ValueKey(key)));
      final dialog = tester.getRect(find.byType(Dialog));
      expect(dialog.contains(chip.topLeft) && dialog.contains(chip.bottomRight), isTrue, reason: key);
    }
    expect(find.text('Płyny (2)'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('picker-search')), 'cyster');
    await tester.pumpAndSettle();
    expect(find.text('Plandeka'), findsNothing);
    expect(find.text('Cysterna spożywcza'), findsOneWidget);
    // Szukanie także po nazwie grupy.
    await tester.enterText(find.byKey(const Key('picker-search')), 'ogólne');
    await tester.pumpAndSettle();
    expect(find.text('Mega'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('picker-search')), 'xyz');
    await tester.pumpAndSettle();
    expect(find.text('Nic nie znaleziono'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('picker-search')), '');
    await tester.tap(find.byKey(const ValueKey('picker-group-1')));
    await tester.pumpAndSettle();
    expect(find.text('Plandeka'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('picker-tanker')));
    await tester.pumpAndSettle();
    expect(picked, 'tanker');
  });
}
