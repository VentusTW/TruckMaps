import 'package:app_auth/app_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'src/home.dart';
import 'src/l10n.dart';

/// Adres serwera TruckMaps: `flutter run --dart-define=TRUCKMAPS_SERVER=http://...`.
const serverUrl = String.fromEnvironment('TRUCKMAPS_SERVER', defaultValue: 'http://localhost:8000');

void main() => runApp(const AdminApp());

/// Pierwszy pasujący język systemu; bez dopasowania – polski.
Locale resolveLocale(Locale? device, Iterable<Locale> supported) {
  for (final locale in supported) {
    if (locale.languageCode == device?.languageCode) return locale;
  }
  return const Locale('pl');
}

class AdminApp extends StatefulWidget {
  const AdminApp({super.key, this.session, this.login, this.locale});

  /// Sesja podana z góry (testy); zwykle przywrócona albo z logowania.
  final Session? session;
  final BrowserLogin? login;
  final Locale? locale;

  @override
  State<AdminApp> createState() => _AdminAppState();
}

class _AdminAppState extends State<AdminApp> {
  // Sesja administratora osobno od sesji aplikacji TruckMaps na tym samym komputerze.
  late final BrowserLogin _login = widget.login ??
      BrowserLogin(serverUrl, store: SecureSessionStore(const FlutterSecureStorage(), 'truckmaps.admin.session'));
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
      onGenerateTitle: (context) => context.l.appTitle,
      debugShowCheckedModeBanner: false,
      // Inny kolor niż aplikacja kierowcy – od razu widać, że to program administracyjny.
      theme: ThemeData(colorSchemeSeed: const Color(0xFF8A1C1C), useMaterial3: true),
      locale: widget.locale,
      supportedLocales: AdminLocalizations.supportedLocales,
      localizationsDelegates: AdminLocalizations.localizationsDelegates,
      localeResolutionCallback: resolveLocale,
      builder: (context, child) {
        session?.api.language = Localizations.localeOf(context).languageCode;
        return child!;
      },
      home: _restoring
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session == null
              ? _LoginScreen(login: _login, onLoggedIn: _start)
              : AdminHome(key: ObjectKey(session), api: session.api, onLogout: _logout),
    );
  }
}

class _LoginScreen extends StatefulWidget {
  const _LoginScreen({required this.login, required this.onLoggedIn});

  final BrowserLogin login;
  final ValueChanged<Session> onLoggedIn;

  @override
  State<_LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<_LoginScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _signIn() async {
    final l = context.l;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      widget.onLoggedIn(await widget.login.login(donePage: l.loginBrowserDone, failedPage: l.loginFailed));
    } on LoginFailure catch (failure) {
      if (!mounted) return;
      setState(() => _error = switch (failure.problem) {
            LoginProblem.browser => l.loginBrowser,
            LoginProblem.timeout => l.loginTimeout,
            LoginProblem.failed => failure.detail ?? l.loginFailed,
          });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.admin_panel_settings_outlined, size: 64),
            const SizedBox(height: 12),
            Text(l.appTitle, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(l.loginHint, textAlign: TextAlign.center),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _busy ? null : _signIn,
              icon: const Icon(Icons.login),
              label: Text(l.login),
            ),
            if (_error case final error?) ...[
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error), textAlign: TextAlign.center),
            ],
          ]),
        ),
      ),
    );
  }
}
