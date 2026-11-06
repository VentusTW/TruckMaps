import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Teksty modułu Kierowcy w języku użytkownika (brak tłumaczenia – polski).
class DriversTexts {
  DriversTexts(this.locale);

  factory DriversTexts.of(BuildContext context) => DriversTexts(Localizations.localeOf(context));

  final Locale locale;

  String _t(String pl, String en) => pick(locale, {'pl': pl, 'en': en});

  String get moduleName => _t('Kierowcy', 'Drivers');
  String get moduleDescription => _t(
      'Kartoteka kierowców, prawo jazdy, kod 95, badania, karta kierowcy i ADR z przypomnieniami, '
          'przydział do pojazdów z ostrzeżeniami o uprawnieniach, przejazdy i historia.',
      'Driver register, licence, code 95, medicals, driver card and ADR with reminders, '
          'vehicle assignment with permission warnings, trips and history.');
  String get menu => _t('Kierowcy', 'Drivers');
  String get empty => _t('Brak kierowców w kartotece.', 'No drivers in the register.');
  String get add => _t('Dodaj kierowcę', 'Add driver');
  String get editTitle => _t('Karta kierowcy', 'Driver card');
  String get name => _t('Imię i nazwisko', 'Full name');
  String get nameRequired => _t('Podaj imię i nazwisko.', 'Enter the full name.');
  String get phone => _t('Telefon', 'Phone');
  String get email => _t('E-mail', 'E-mail');
  String get hiredOn => _t('Data zatrudnienia', 'Hired on');
  String get notes => _t('Uwagi', 'Notes');
  String get company => _t('Firma', 'Company');
  String get account => _t('Konto w aplikacji', 'App account');
  String get noAccount => _t('Bez konta (tylko wpis)', 'No account (record only)');
  String get hasAccount => _t('Ma konto w aplikacji', 'Has an app account');
  String get categories => _t('Kategorie prawa jazdy', 'Driving licence categories');
  String get adrTank => _t('ADR obejmuje cysterny', 'ADR covers tanks');
  String get qualifications => _t('Kwalifikacje i terminy', 'Qualifications and dates');
  String get save => _t('Zapisz', 'Save');
  String get cancel => _t('Anuluj', 'Cancel');
  String get retry => _t('Spróbuj ponownie', 'Try again');
  String get delete => _t('Usuń', 'Delete');
  String get deleteTitle => _t('Usunąć kierowcę?', 'Delete the driver?');
  String get deleteHint => _t('Karta z historią przydziałów i zmian zostanie usunięta, pojazdy zwolnione.',
      'The card with its assignment and change history is deleted, vehicles are released.');
  String get clear => _t('Wyczyść', 'Clear');
  String get noManagedCompany => _t('Kartotekę prowadzą właściciel i dyspozytorzy firmy.',
      'The register is kept by the company owner and dispatchers.');

  String get tabCard => _t('Karta', 'Card');
  String get tabTrips => _t('Przejazdy', 'Trips');
  String get tabHistory => _t('Historia', 'History');

  String get vehicles => _t('Pojazdy', 'Vehicles');
  String get noVehicles => _t('Brak przydzielonych pojazdów.', 'No vehicles assigned.');
  String get assign => _t('Przydziel pojazd', 'Assign vehicle');
  String get assignDriver => _t('Przydziel kierowcę', 'Assign driver');
  String assignDriverTitle(String vehicle) => _t('Kierowca pojazdu $vehicle', 'Driver of $vehicle');
  String get noDriver => _t('Bez kierowcy', 'No driver');
  String get noDriversToAssign => _t('Brak kierowców w kartotece firmy – dodaj ich w module Kierowcy.',
      'No drivers in the company register – add them in the Drivers module.');
  String get release => _t('Zwolnij', 'Release');
  String get chooseVehicle => _t('Wybierz pojazd', 'Choose a vehicle');
  String get noCompanyVehicles => _t('Firma nie ma pojazdów do przydziału.', 'The company has no vehicles to assign.');
  String get warningsTitle => _t('Uwagi o uprawnieniach', 'Permission warnings');
  String get assignAnyway => _t('Przydziel mimo to', 'Assign anyway');
  String since(DateTime when) => _t('od ${_date(when)}', 'since ${_date(when)}');
  String needs(String category) => _t('Wymagana kategoria: $category', 'Required category: $category');

  String get cardDownload => _t('Pobrano dziś dane z karty', 'Card data downloaded today');
  String get cardDownloaded => _t('Zapisano pobranie danych z karty.', 'Card data download saved.');

  String field(String name) => switch (name) {
        'license_until' => _t('Prawo jazdy ważne do', 'Driving licence valid until'),
        'code95_until' => _t('Kod 95 (kwalifikacja / szkolenie okresowe) do', 'Code 95 (qualification / periodic training) until'),
        'medical_until' => _t('Badania lekarskie do', 'Medical examination until'),
        'psych_until' => _t('Badania psychologiczne do', 'Psychological examination until'),
        'card_until' => _t('Karta kierowcy ważna do', 'Driver card valid until'),
        'card_downloaded_on' => _t('Ostatnie pobranie danych z karty', 'Last driver card download'),
        'card_download_until' => _t('Następne pobranie z karty do', 'Next card download by'),
        'adr_until' => _t('Zaświadczenie ADR do', 'ADR certificate until'),
        'attestation_until' => _t('Świadectwo kierowcy (spoza UE) do', 'Driver attestation (non-EU) until'),
        _ => name,
      };

  String fieldHint(String name) => switch (name) {
        'code95_until' => _t('co 5 lat', 'every 5 years'),
        'card_until' => _t('karta ważna 5 lat', 'card valid for 5 years'),
        'card_download_until' => _t('co 28 dni; puste – 28 dni od pobrania', 'every 28 days; empty – 28 days after download'),
        _ => '',
      };

  String dueState(String state) => switch (state) {
        'overdue' => _t('po terminie', 'overdue'),
        'soon' => _t('wkrótce', 'soon'),
        _ => _t('ważne', 'valid'),
      };

  String get vehicleSectionTitle => _t('Kierowcy z kartoteki', 'Drivers from the register');
  String get vehicleSectionEmpty =>
      _t('Brak kierowców z kartoteki przydzielonych do tego pojazdu.', 'No registered drivers assigned to this vehicle.');
  String get allValid => _t('Kwalifikacje ważne', 'Qualifications valid');
  String get dashboardTitle => _t('Terminy kierowców', 'Driver deadlines');
  String get dashboardOk => _t('Kwalifikacje kierowców ważne.', 'Driver qualifications are valid.');

  String dueSummary(int overdue, int soon) => [
        if (overdue > 0) _t('po terminie: $overdue', 'overdue: $overdue'),
        if (soon > 0) _t('wkrótce: $soon', 'soon: $soon'),
      ].join(' · ');

  String get noTrips => _t('Brak przejazdów w tym okresie.', 'No trips in this period.');
  String months(int n) => _t('$n mies.', '$n mo.');
  String get trips => _t('Przejazdy', 'Trips');
  String get distance => _t('Kilometry', 'Kilometres');
  String get hours => _t('Godziny jazdy', 'Driving hours');
  String get emptyKm => _t('Puste km', 'Empty km');
  String get idleHours => _t('Przestoje [h]', 'Idle [h]');
  String get vehiclesUsed => _t('Pojazdy', 'Vehicles');
  String get byMonth => _t('Według miesięcy', 'By month');
  String get byVehicle => _t('Według pojazdów', 'By vehicle');
  String get recent => _t('Ostatnie przejazdy', 'Recent trips');
  String km(num value) => '${NumberFormat.decimalPattern(locale.toLanguageTag()).format(value)} km';
  String tripLine(int trips, num km, num hours) => _t('$trips przejazdów · ${this.km(km)} · $hours h',
      '$trips trips · ${this.km(km)} · $hours h');
  String get emptyTrip => _t('pusty', 'empty');

  String get assignments => _t('Przydziały do pojazdów', 'Vehicle assignments');
  String get changes => _t('Zmiany w kartotece', 'Register changes');
  String get noHistory => _t('Brak wpisów.', 'No entries.');
  String period(DateTime from, DateTime? to) => to == null ? since(from) : '${_date(from)} – ${_date(to)}';
  String action(String value) => switch (value) {
        'created' => _t('Dodano kartę', 'Card created'),
        'updated' => _t('Zmieniono', 'Changed'),
        'assigned' => _t('Przydzielono pojazd', 'Vehicle assigned'),
        'released' => _t('Zwolniono pojazd', 'Vehicle released'),
        'card_download' => _t('Pobrano dane z karty', 'Card data downloaded'),
        _ => value,
      };
  String by(String name, DateTime when) => name.isEmpty ? _date(when) : '$name · ${_date(when)}';
  String changeField(String name) => switch (name) {
        'name' => this.name,
        'phone' => phone,
        'email' => email,
        'hired_on' => hiredOn,
        'notes' => notes,
        'license_categories' => categories,
        'adr_tank' => adrTank,
        'account' => account,
        'vehicle' => _t('Pojazd', 'Vehicle'),
        _ => field(name),
      };

  String date(DateTime when) => _date(when);
  String _date(DateTime when) => DateFormat.yMd(locale.toLanguageTag()).format(when.toLocal());
}
