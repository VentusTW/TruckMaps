import 'package:flutter/widgets.dart';

import 'api.dart';

/// To, co powłoka daje modułowi: klient API (z tokenem), dane zalogowanego użytkownika
/// i jego język.
class ModuleContext {
  const ModuleContext({required this.api, required this.userName, this.locale = const Locale('pl')});

  final CoreApi api;
  final String userName;
  final Locale locale;
}

/// Tekst modułu w języku użytkownika: `pick(locale, {'pl': 'Powitanie', 'en': 'Greeting'})`.
/// Brak tłumaczenia – polski. Większy moduł może mieć własne pliki .arb (gen-l10n).
String pick(Locale locale, Map<String, String> texts) =>
    texts[locale.languageCode] ?? texts['pl'] ?? texts.values.first;

/// Ekran modułu w menu powłoki.
class ModuleEntry {
  const ModuleEntry({required this.title, required this.icon, required this.builder, this.start = false});

  final String title;
  final IconData icon;
  final WidgetBuilder builder;

  /// Dawniej ekran startowy. Teraz startem jest pulpit powłoki – moduł dokłada do niego sekcje
  /// ([TruckMapsModule.dashboardSections]), a ten ekran jest zwykłą pozycją menu.
  final bool start;
}

/// Pakiet modułu w aplikacji. [id] musi być taki sam jak identyfikator modułu na
/// serwerze (np. "hello") – po nim powłoka sprawdza, czy konto ma dostęp.
abstract class TruckMapsModule {
  String get id;

  /// Nazwa w języku użytkownika (zob. [pick]).
  String name(Locale locale);

  /// Krótki opis do ekranu „Kup moduł”, w języku użytkownika.
  String description(Locale locale);

  /// Ekrany modułu – wywoływane tylko, gdy konto ma dostęp.
  List<ModuleEntry> entries(ModuleContext context);

  /// Sekcje dokładane do karty pojazdu (np. usterki i koszty napraw, kierowcy, plan załadunku).
  List<VehicleSection> vehicleSections(ModuleContext context) => const [];

  /// Szybkie akcje na karcie i w menu pojazdu (np. „Zgłoś usterkę”).
  List<VehicleAction> vehicleActions(ModuleContext context) => const [];

  /// Sekcje pulpitu startowego – to, co wymaga uwagi (np. otwarte usterki, terminy kierowców).
  List<DashboardSection> dashboardSections(ModuleContext context) => const [];
}

/// Pojazd w postaci z `GET /api/vehicles` (id, name, plate, kind, company_id, can_edit…).
typedef Vehicle = Map<String, dynamic>;

/// Sekcja karty pojazdu. [builder] zwraca zwykle [SectionCard]; `SizedBox.shrink()` – nic do pokazania.
/// Po zmianie na karcie (np. po akcji) sekcja jest budowana od nowa – pobiera dane sama.
class VehicleSection {
  const VehicleSection({required this.id, required this.builder, this.applies, this.order = 100});

  final String id;
  final Widget Function(BuildContext context, Vehicle vehicle) builder;

  /// Czy sekcja dotyczy pojazdu (np. tylko pojazdy z napędem); `null` – każdego.
  final bool Function(Vehicle vehicle)? applies;

  /// Kolejność na karcie: sekcje rdzenia mają 10–90, moduły domyślnie 100.
  final int order;
}

/// Szybka akcja pojazdu. [run] zwraca `true`, gdy coś zmieniła – karta odświeża dane.
class VehicleAction {
  const VehicleAction({required this.id, required this.label, required this.icon, required this.run, this.applies});

  final String id;
  final String label;
  final IconData icon;
  final Future<bool> Function(BuildContext context, Vehicle vehicle) run;
  final bool Function(Vehicle vehicle)? applies;
}

/// Sekcja pulpitu startowego. Przy odświeżeniu pulpitu budowana od nowa.
class DashboardSection {
  const DashboardSection({required this.id, required this.builder, this.order = 100});

  final String id;
  final WidgetBuilder builder;
  final int order;
}
