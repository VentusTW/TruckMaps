import 'package:flutter/widgets.dart';

import 'module.dart';

/// Moduł z serwera (`GET /api/me/modules`).
class ServerModule {
  const ServerModule({required this.id, required this.name, this.version, required this.granted});

  factory ServerModule.fromJson(Map<String, dynamic> json) => ServerModule(
        id: json['id'] as String,
        name: (json['name'] as String?) ?? json['id'] as String,
        version: json['version'] as String?,
        granted: json['granted'] == true,
      );

  final String id;
  final String name;
  final String? version;
  final bool granted;
}

/// Moduł widoczny w aplikacji: pakiet w aplikacji + stan na serwerze.
class ModuleAccess {
  const ModuleAccess({required this.module, required this.server});

  final TruckMapsModule? module;
  final ServerModule server;

  String get id => server.id;
  String name(Locale locale) => module?.name(locale) ?? server.name;

  /// Moduł z dostępem i z pakietem w tej wersji aplikacji – można go otworzyć.
  bool get usable => server.granted && module != null;

  /// Moduł działa na serwerze, ale ta wersja aplikacji go jeszcze nie ma.
  bool get needsAppUpdate => module == null;
}

/// Pakiety modułów wbudowane w aplikację.
class ModuleRegistry {
  ModuleRegistry(List<TruckMapsModule> installed)
      : _installed = {for (final module in installed) module.id: module};

  final Map<String, TruckMapsModule> _installed;

  Iterable<TruckMapsModule> get installed => _installed.values;

  /// Moduły do pokazania: te, które działają na serwerze. Pakiet bez modułu na serwerze
  /// (np. wyłączonego) nie jest pokazywany – jego API i tak by nie działało.
  List<ModuleAccess> resolve(List<ServerModule> server) => [
        for (final module in server) ModuleAccess(module: _installed[module.id], server: module),
      ];
}
