import 'package:flutter/widgets.dart';

import 'api.dart';

/// To, co powłoka daje modułowi: klient API (z tokenem) i dane zalogowanego użytkownika.
class ModuleContext {
  const ModuleContext({required this.api, required this.userName});

  final CoreApi api;
  final String userName;
}

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

  String get name;

  /// Krótki opis do ekranu „Kup moduł”.
  String get description;

  /// Ekrany modułu – wywoływane tylko, gdy konto ma dostęp.
  List<ModuleEntry> entries(ModuleContext context);
}
