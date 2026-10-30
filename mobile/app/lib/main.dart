import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:module_hello/module_hello.dart';

import 'src/auth.dart';
import 'src/home.dart';
import 'src/l10n.dart';
import 'src/login.dart';

/// Adres serwera TruckMaps: `flutter run --dart-define=TRUCKMAPS_SERVER=http://...`.
const serverUrl = String.fromEnvironment('TRUCKMAPS_SERVER', defaultValue: 'http://localhost:8000');

/// Pakiety modułów w tej wersji aplikacji.
final modules = ModuleRegistry([HelloModule()]);

void main() => runApp(const TruckMapsApp());

/// Pierwszy pasujący język systemu (po kodzie języka); bez dopasowania – polski.
Locale resolveLocale(Locale? device, Iterable<Locale> supported) {
  for (final locale in supported) {
    if (locale.languageCode == device?.languageCode) return locale;
  }
  return const Locale('pl');
}

class TruckMapsApp extends StatefulWidget {
  const TruckMapsApp({super.key, this.session, this.login, this.locale});

  /// Sesja podana z góry (testy); zwykle przywrócona z poprzedniego uruchomienia albo z logowania.
  final Session? session;
  final BrowserLogin? login;

  /// Język wybrany z góry (testy); zwykle język systemu.
  final Locale? locale;

  @override
  State<TruckMapsApp> createState() => _TruckMapsAppState();
}

class _TruckMapsAppState extends State<TruckMapsApp> {
  late final BrowserLogin _login = widget.login ?? BrowserLogin(serverUrl);
  late Session? _session = widget.session;

  /// Język wybrany w koncie; bez wyboru – [TruckMapsApp.locale] albo język systemu.
  Locale? _language;
  late bool _restoring = widget.session == null;

  @override
  void initState() {
    super.initState();
    if (_restoring) _restore();
  }

  Future<void> _restore() async {
    final session = await _login.restore();
    if (!mounted) return;
    setState(() => _restoring = false);
    if (session != null) _start(session);
  }

  void _start(Session session) {
    session.tokens?.onExpired = () {
      if (mounted) setState(() => _session = null);
    };
    setState(() => _session = session);
  }

  Future<void> _logout() async {
    await _login.logout();
    setState(() {
      _session = null;
      _language = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
      title: 'TruckMaps',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF1B6E3A), useMaterial3: true),
      // Język telefonu / systemu, jeśli aplikacja go ma; inaczej polski.
      locale: _language ?? widget.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      localeResolutionCallback: resolveLocale,
      // Serwer odpowiada w języku aplikacji (ostrzeżenia na trasie, błędy, zakazy).
      builder: (context, child) {
        session?.api.language = Localizations.localeOf(context).languageCode;
        return child!;
      },
      home: _restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session == null
              ? LoginScreen(serverUrl: serverUrl, login: _login, onLoggedIn: _start)
              : HomeScreen(
                  session: session,
                  registry: modules,
                  onLogout: _logout,
                  onLanguage: (code) => setState(() => _language = code == null ? null : Locale(code)),
                ),
    );
  }
}
