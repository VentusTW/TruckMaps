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
  const ModuleEntry({required this.title, required this.icon, required this.builder});

  final String title;
  final IconData icon;
  final WidgetBuilder builder;
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
}
