import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

/// Teksty modułu Serwis w języku użytkownika (brak tłumaczenia – polski).
class ServiceTexts {
  ServiceTexts(this.locale);

  factory ServiceTexts.of(BuildContext context) => ServiceTexts(Localizations.localeOf(context));

  final Locale locale;

  String _t(String pl, String en) => pick(locale, {'pl': pl, 'en': en});

  String get moduleName => _t('Serwis', 'Service');
  String get moduleDescription => _t(
      'Zgłoszenia usterek od kierowców, zlecenia i protokoły napraw dla mechaników, historia napraw pojazdu.',
      'Fault reports from drivers, repair orders and protocols for mechanics, vehicle repair history.');
  String get menu => _t('Serwis', 'Service');
  String get openOrders => _t('Otwarte', 'Open');
  String get allOrders => _t('Wszystkie', 'All');
  String get empty => _t('Brak zleceń.', 'No orders.');
  String get report => _t('Zgłoś usterkę', 'Report a fault');
  String get reportTitle => _t('Zgłoszenie usterki', 'Fault report');
  String get vehicle => _t('Pojazd', 'Vehicle');
  String get vehicleRequired => _t('Wybierz pojazd.', 'Choose a vehicle.');
  String get noVehicles => _t('Brak pojazdów – dodaj pojazd w „Pojazdy”.', 'No vehicles – add one in “Vehicles”.');
  String get description => _t('Co się dzieje?', 'What is wrong?');
  String get descriptionHint => _t('np. wycieka olej spod silnika', 'e.g. oil leaking under the engine');
  String get descriptionRequired => _t('Opisz usterkę (co najmniej 3 znaki).', 'Describe the fault (at least 3 characters).');
  String get canDrive => _t('Może jechać do naprawy', 'Can drive to the workshop');
  String get stopped => _t('Pojazd stoi', 'Vehicle is off the road');
  String get stoppedHint =>
      _t('Pojazd od razu będzie „w naprawie” – niedostępny do jazdy.', 'The vehicle is marked “in repair” at once – not available to drive.');
  String get send => _t('Wyślij', 'Send');
  String get save => _t('Zapisz', 'Save');
  String get cancel => _t('Anuluj', 'Cancel');
  String get retry => _t('Spróbuj ponownie', 'Try again');

  String status(String? value) => switch (value) {
        'new' => _t('Nowe', 'New'),
        'accepted' => _t('Przyjęte', 'Accepted'),
        'in_progress' => _t('W naprawie', 'In repair'),
        'done' => _t('Zakończone', 'Done'),
        _ => _t('Odrzucone', 'Rejected'),
      };

  String reportedBy(String name, DateTime when) =>
      _t('Zgłosił(a): $name, ${_date(when)}', 'Reported by $name, ${_date(when)}');
  String mechanic(String name) => _t('Mechanik: $name', 'Mechanic: $name');
  String completed(DateTime when) => _t('Zakończono: ${_date(when)}', 'Completed: ${_date(when)}');
  String get accept => _t('Przyjmij', 'Accept');
  String get start => _t('Rozpocznij naprawę', 'Start repair');
  String get complete => _t('Zamknij protokołem', 'Close with protocol');
  String get reject => _t('Odrzuć', 'Reject');
  String get rejectTitle => _t('Odrzucić zgłoszenie?', 'Reject the report?');
  String get rejectReason => _t('Powód', 'Reason');
  String rejected(String reason) => _t('Odrzucone: $reason', 'Rejected: $reason');
  String get protocolTitle => _t('Protokół naprawy', 'Repair protocol');
  String get workDone => _t('Wykonane czynności', 'Work done');
  String get workDoneRequired => _t('Opisz wykonane czynności.', 'Describe the work done.');
  String get parts => _t('Części', 'Parts');
  String get addPart => _t('Dodaj część', 'Add part');
  String get partName => _t('Nazwa', 'Name');
  String get partQuantity => _t('Ilość', 'Qty');
  String get partPrice => _t('Cena', 'Price');
  String get labourHours => _t('Czas pracy', 'Labour');
  String get odometer => _t('Przebieg', 'Odometer');
  String get notes => _t('Uwagi', 'Notes');
  String get numberInvalid => _t('Wpisz liczbę.', 'Enter a number.');
  String hours(String value) => _t('$value h', '$value h');

  /// Data jednakowa dla wszystkich języków (bez nazw miesięcy).
  String _date(DateTime when) => DateFormat('yyyy-MM-dd HH:mm').format(when.toLocal());
}
