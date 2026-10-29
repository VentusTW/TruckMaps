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
  const TruckMapsApp({super.key, this.session, this.login});

  /// Sesja podana z góry (testy); zwykle przywrócona z poprzedniego uruchomienia albo z logowania.
  final Session? session;
  final BrowserLogin? login;

  @override
  State<TruckMapsApp> createState() => _TruckMapsAppState();
}

class _TruckMapsAppState extends State<TruckMapsApp> {
  late final BrowserLogin _login = widget.login ?? BrowserLogin(serverUrl);
  late Session? _session = widget.session;
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
    setState(() => _session = null);
  }

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
      home: _restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session == null
              ? LoginScreen(serverUrl: serverUrl, login: _login, onLoggedIn: _start)
              : HomeScreen(session: session, registry: modules, onLogout: _logout),
    );
  }
}
