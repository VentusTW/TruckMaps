import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Teksty modułu Plan załadunku w języku użytkownika (brak tłumaczenia – polski).
class LoadTexts {
  LoadTexts(this.locale);

  factory LoadTexts.of(BuildContext context) => LoadTexts(Localizations.localeOf(context));

  final Locale locale;

  String _t(String pl, String en) => pick(locale, {'pl': pl, 'en': en});

  String get moduleName => _t('Plan załadunku', 'Load plan');
  String get moduleDescription => _t(
      'LDM i masa ładunku, czy się zmieści, rozmieszczenie palet z kolejnością rozładunków, środek ciężkości i liczba pasów.',
      'Loading metres and weight, whether it fits, pallet layout by unloading order, centre of gravity and number of straps.');
  String get menu => _t('Załadunek', 'Loading');
  String get vehicle => _t('Pojazd (przestrzeń ładunkowa)', 'Vehicle (cargo space)');
  String get noVehicles => _t('Brak pojazdów z przestrzenią ładunkową.', 'No vehicles with a cargo space.');
  String get items => _t('Ładunek', 'Load');
  String get addItem => _t('Dodaj pozycję', 'Add item');
  String kind(String value) => switch (value) {
        'euro' => _t('Paleta EUR 1,2 × 0,8', 'EUR pallet 1.2 × 0.8'),
        'industrial' => _t('Paleta przemysłowa 1,2 × 1,0', 'Industrial pallet 1.2 × 1.0'),
        'half' => _t('Półpaleta 0,8 × 0,6', 'Half pallet 0.8 × 0.6'),
        _ => _t('Inny wymiar', 'Other size'),
      };
  String get count => _t('Sztuk', 'Pieces');
  String get weight => _t('Masa sztuki', 'Weight each');
  String get stack => _t('W stosie', 'Stacked');
  String get stop => _t('Rozładunek nr', 'Unloading no.');
  String get length => _t('Długość', 'Length');
  String get width => _t('Szerokość', 'Width');
  String get deckLength => _t('Długość przestrzeni (puste – z profilu)', 'Cargo space length (empty – from profile)');
  String get frontWall => _t('Oparty o ścianę czołową', 'Against the front wall');
  String get mats => _t('Maty antypoślizgowe', 'Anti-slip mats');
  String get calculate => _t('Policz plan', 'Calculate plan');
  String get retry => _t('Spróbuj ponownie', 'Try again');
  String get numberInvalid => _t('Wpisz liczbę.', 'Enter a number.');
  String get fits => _t('Mieści się', 'Fits');
  String get notFits => _t('Nie mieści się', 'Does not fit');
  String summary(String ldm, String used, String deck) =>
      _t('$ldm LDM · zajęte $used z $deck m', '$ldm LDM · $used of $deck m used');
  String weightLine(String weight, String? payload) => payload == null
      ? _t('Masa ładunku: $weight kg', 'Load weight: $weight kg')
      : _t('Masa ładunku: $weight z $payload kg ładowności', 'Load weight: $weight of $payload kg payload');
  String strapsLine(int straps) =>
      _t('Pasy (docisk, EN 12195-1): $straps – liczone na rząd', 'Straps (top-over, EN 12195-1): $straps – per row');
  String cog(String metres) => _t('Środek ciężkości: $metres m od ściany czołowej', 'Centre of gravity: $metres m from the front wall');
  String get front => _t('Przód (ściana czołowa)', 'Front (front wall)');
  String get disclaimer => _t(
      'Szacunek pomocniczy, nie certyfikat. Za rozmieszczenie i zabezpieczenie ładunku odpowiadają ładujący i kierowca.',
      'A helping estimate, not a certificate. The loader and the driver are responsible for placing and securing the load.');

  String number(num value) => NumberFormat.decimalPattern(locale.toLanguageTag()).format(value);
}
