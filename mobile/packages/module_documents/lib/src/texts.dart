import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';

/// Teksty modułu Dokumenty w języku użytkownika (brak tłumaczenia – polski). Etykiety pól
/// dokumentów przychodzą z serwera w języku użytkownika.
class DocumentsTexts {
  DocumentsTexts(this.locale);

  factory DocumentsTexts.of(BuildContext context) => DocumentsTexts(Localizations.localeOf(context));

  final Locale locale;

  String _t(String pl, String en) => pick(locale, {'pl': pl, 'en': en});

  String get moduleName => _t('Dokumenty', 'Documents');
  String get moduleDescription => _t(
      'List przewozowy CMR, zlecenie transportowe i karta drogowa wypełniane z danych firmy, pojazdu, '
          'kierowcy, trasy i przejazdów; własne pola, logo firmy, wydruk PDF.',
      'CMR consignment note, transport order and vehicle log sheet filled in from company, vehicle, '
          'driver, route and trip data; custom fields, company logo, PDF print.');
  String get menu => _t('Dokumenty', 'Documents');
  String get noCompany =>
      _t('Dokumenty są dostępne dla członków firmy.', 'Documents are available to company members.');
  String get company => _t('Firma', 'Company');
  String get empty => _t('Brak dokumentów.', 'No documents.');
  String get add => _t('Nowy dokument', 'New document');
  String get chooseKind => _t('Rodzaj dokumentu', 'Document type');
  String get profile => _t('Dane firmy i logo', 'Company details and logo');
  String get templates => _t('Wzory dokumentów', 'Document templates');
  String get vehicle => _t('Pojazd', 'Vehicle');
  String get noVehicle => _t('Bez pojazdu', 'No vehicle');
  String get periodFrom => _t('Przejazdy od', 'Trips from');
  String get periodTo => _t('Przejazdy do', 'Trips to');
  String get fill => _t('Wypełnij z danych', 'Fill in from data');
  String get filled =>
      _t('Uzupełniono pola – sprawdź je przed zapisaniem.', 'Fields filled in – check them before saving.');
  String get save => _t('Zapisz', 'Save');
  String get saved => _t('Zapisano.', 'Saved.');
  String get cancel => _t('Anuluj', 'Cancel');
  String get delete => _t('Usuń', 'Delete');
  String get deleteTitle => _t('Usunąć dokument?', 'Delete the document?');
  String get pdf => _t('PDF', 'PDF');
  String get pdfFailed => _t('Nie udało się otworzyć PDF.', 'Could not open the PDF.');
  String get retry => _t('Spróbuj ponownie', 'Try again');
  String get addRow => _t('Dodaj wiersz', 'Add row');
  String get removeRow => _t('Usuń wiersz', 'Remove row');
  String get pickDate => _t('Wybierz datę', 'Pick a date');
  String get logo => _t('Logo firmy', 'Company logo');
  String get logoHint =>
      _t('Drukowane w prawym górnym rogu dokumentów.', 'Printed in the top right corner of documents.');
  String get logoChange => _t('Wybierz logo', 'Choose logo');
  String get logoRemove => _t('Usuń logo', 'Remove logo');
  String get templateFields => _t('Pola wzoru', 'Template fields');
  String get templateHint => _t(
      'Zmień nazwę pola, ustaw wartość domyślną albo ukryj pole. Dodane pola trafiają na koniec dokumentu.',
      'Rename a field, set its default value or hide it. Added fields go at the end of the document.');
  String get customFields => _t('Pola firmy', 'Company fields');
  String get addField => _t('Dodaj pole', 'Add field');
  String get editField => _t('Pole', 'Field');
  String get fieldLabel => _t('Nazwa pola', 'Field name');
  String get fieldLabelRequired => _t('Podaj nazwę pola.', 'Enter the field name.');
  String get fieldDefault => _t('Wartość domyślna', 'Default value');
  String get fieldType => _t('Rodzaj', 'Type');
  String get fieldWidth => _t('Szerokość na wydruku', 'Width in print');
  String get visible => _t('Widoczne', 'Visible');
  String get terms => _t('Warunki na końcu dokumentu', 'Terms at the end of the document');
  String get onlyManagers => _t('Wzory i dane firmy zmieniają właściciel i dyspozytorzy.',
      'Templates and company details are changed by the owner and dispatchers.');

  String type(String type) => switch (type) {
        'multiline' => _t('Tekst wielowierszowy', 'Multi-line text'),
        'number' => _t('Liczba', 'Number'),
        'date' => _t('Data', 'Date'),
        _ => _t('Tekst', 'Text'),
      };

  String width(double width) => switch (width) {
        0.25 => _t('Ćwierć strony', 'Quarter page'),
        0.5 => _t('Pół strony', 'Half page'),
        _ => _t('Cała szerokość', 'Full width'),
      };

  /// Skąd pochodzi podpowiedź pola (`sources` z `/prefill`).
  String source(String source) => switch (source) {
        'company' => _t('z danych firmy', 'from company data'),
        'profile' => _t('z danych firmy', 'from company data'),
        'template' => _t('z wzoru', 'from the template'),
        'vehicle' => _t('z pojazdu', 'from the vehicle'),
        'driver' => _t('kierowca przydzielony do pojazdu', 'driver assigned to the vehicle'),
        'route' => _t('z trasy', 'from the route'),
        'cargo' => _t('z planu załadunku', 'from the load plan'),
        'trips' => _t('z przejazdów', 'from trips'),
        _ => _t('wypełnione automatycznie', 'filled in automatically'),
      };

  static const profileFields = [
    'legal_name', 'address', 'postal_code', 'city', 'country', 'vat_id', 'regon', 'krs', 'eori', //
    'licence_number', 'ocp_policy', 'ocp_insurer', 'ocp_sum', 'bank_account', 'contact_person', 'phone', 'email',
    'issue_place',
  ];

  String profileField(String key) => switch (key) {
        'legal_name' => _t('Pełna nazwa', 'Legal name'),
        'address' => _t('Ulica i numer', 'Street and number'),
        'postal_code' => _t('Kod pocztowy', 'Postal code'),
        'city' => _t('Miejscowość', 'City'),
        'country' => _t('Kraj (kod, np. PL)', 'Country (code, e.g. PL)'),
        'vat_id' => _t('NIP / VAT UE', 'VAT ID'),
        'regon' => _t('REGON', 'Business ID (REGON)'),
        'krs' => _t('KRS', 'Court register no. (KRS)'),
        'eori' => _t('EORI', 'EORI'),
        'licence_number' => _t('Nr licencji / zezwolenia przewoźnika', 'Carrier licence no.'),
        'ocp_policy' => _t('Polisa OCP – numer', 'Liability insurance – policy no.'),
        'ocp_insurer' => _t('Polisa OCP – ubezpieczyciel', 'Liability insurance – insurer'),
        'ocp_sum' => _t('Polisa OCP – suma gwarancyjna', 'Liability insurance – sum insured'),
        'bank_account' => _t('Numer konta', 'Bank account'),
        'contact_person' => _t('Osoba kontaktowa', 'Contact person'),
        'phone' => _t('Telefon', 'Phone'),
        'email' => _t('E-mail', 'E-mail'),
        'issue_place' => _t('Miejsce wystawiania dokumentów', 'Place of issue'),
        _ => key,
      };
}
