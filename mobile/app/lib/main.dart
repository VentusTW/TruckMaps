import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:module_hello/module_hello.dart';

import 'src/auth.dart';
import 'src/home.dart';
import 'src/login.dart';

/// Adres serwera TruckMaps: `flutter run --dart-define=TRUCKMAPS_SERVER=http://...`.
const serverUrl = String.fromEnvironment('TRUCKMAPS_SERVER', defaultValue: 'http://localhost:8000');

/// Pakiety modułów w tej wersji aplikacji.
final modules = ModuleRegistry([HelloModule()]);

void main() => runApp(const TruckMapsApp());

class TruckMapsApp extends StatefulWidget {
  const TruckMapsApp({super.key, this.session});

  /// Sesja podana z góry (testy); zwykle powstaje po zalogowaniu.
  final Session? session;

  @override
  State<TruckMapsApp> createState() => _TruckMapsAppState();
}

class _TruckMapsAppState extends State<TruckMapsApp> {
  late Session? _session = widget.session;

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
      title: 'TruckMaps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1B6E3A), useMaterial3: true),
      // Polski kalendarz i zegar (wybór godziny wyjazdu).
      locale: const Locale('pl'),
      supportedLocales: const [Locale('pl'), Locale('en')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: session == null
          ? LoginScreen(serverUrl: serverUrl, onLoggedIn: (s) => setState(() => _session = s))
          : HomeScreen(
              session: session,
              registry: modules,
              onLogout: () => setState(() => _session = null),
            ),
    );
  }
}
