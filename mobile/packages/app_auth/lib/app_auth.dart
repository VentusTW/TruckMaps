import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:core_sdk/core_sdk.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Tokeny zalogowanego użytkownika: dostępu (krótko ważny) i odświeżania.
class Tokens {
  const Tokens({required this.access, required this.expiresAt, this.refresh, this.userName = ''});

  factory Tokens.fromServer(Map<String, dynamic> body, {String? previousName, String? previousRefresh}) {
    final name = body['name'] as String? ?? '';
    return Tokens(
      access: body['access_token'] as String,
      expiresAt: DateTime.now().add(Duration(seconds: body['expires_in'] as int? ?? 3600)),
      refresh: body['refresh_token'] as String? ?? previousRefresh,
      userName: name.isNotEmpty ? name : previousName ?? '',
    );
  }

  factory Tokens.fromJson(Map<String, dynamic> json) => Tokens(
        access: json['access'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        refresh: json['refresh'] as String?,
        userName: json['user_name'] as String? ?? '',
      );

  final String access;
  final DateTime expiresAt;
  final String? refresh;
  final String userName;

  Map<String, dynamic> toJson() => {
        'access': access,
        'expires_at': expiresAt.toIso8601String(),
        'refresh': refresh,
        'user_name': userName,
      };
}

/// Gdzie sesja przetrwa zamknięcie aplikacji (testy podają magazyn w pamięci).
abstract class SessionStore {
  Future<Tokens?> load();
  Future<void> save(Tokens tokens);
  Future<void> clear();
}

/// Magazyn systemu: Menedżer poświadczeń (Windows), Keystore (Android), Keychain (iOS).
class SecureSessionStore implements SessionStore {
  /// [key] rozdziela sesje programów na jednym komputerze (aplikacja i program administracyjny).
  SecureSessionStore([this._storage = const FlutterSecureStorage(), this._key = 'truckmaps.session']);

  final FlutterSecureStorage _storage;
  final String _key;

  @override
  Future<Tokens?> load() async {
    try {
      final text = await _storage.read(key: _key);
      return text == null ? null : Tokens.fromJson(jsonDecode(text) as Map<String, dynamic>);
    } catch (_) {
      return null; // uszkodzony albo niedostępny magazyn – po prostu logowanie od nowa
    }
  }

  @override
  Future<void> save(Tokens tokens) => _storage.write(key: _key, value: jsonEncode(tokens.toJson()));

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Źródło tokenu dla klienta API: odświeża token przed wygaśnięciem i zapisuje sesję.
class SessionTokens implements TokenSource {
  SessionTokens(this.serverUrl, this._tokens, this._store, {http.Client? client, this.onExpired})
      : _client = client ?? http.Client();

  final String serverUrl;
  final SessionStore _store;
  final http.Client _client;

  /// Sesja wygasła (token odświeżania nieważny) – powłoka wraca do logowania.
  void Function()? onExpired;
  Tokens _tokens;
  Future<bool>? _refreshing;

  Tokens get current => _tokens;
  static const _margin = Duration(minutes: 1);

  @override
  Future<String> token() async {
    if (_tokens.expiresAt.isBefore(DateTime.now().add(_margin)) && _tokens.refresh != null) {
      await refresh();
    }
    return _tokens.access;
  }

  @override
  Future<bool> refresh() => _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<bool> _refresh() async {
    final refresh = _tokens.refresh;
    if (refresh == null) return _expired();
    try {
      final response = await _client.post(
        Uri.parse('$serverUrl/auth/app/refresh'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'refresh_token': refresh}),
      );
      // Odrzucony token odświeżania – koniec sesji; chwilowy błąd serwera – spróbujemy później.
      if (response.statusCode == 400 || response.statusCode == 401) return _expired();
      if (response.statusCode != 200) return false;
      _tokens = Tokens.fromServer(
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>,
        previousName: _tokens.userName,
        previousRefresh: refresh,
      );
      await _store.save(_tokens);
      return true;
    } on http.ClientException {
      return false; // brak sieci – sesja zostaje, spróbujemy przy następnym zapytaniu
    } on SocketException {
      return false;
    }
  }

  Future<bool> _expired() async {
    await _store.clear();
    onExpired?.call();
    return false;
  }
}

/// Zalogowany użytkownik: klient API (z odświeżanym tokenem) i nazwa do wyświetlenia.
class Session {
  Session({required this.api, required this.userName, this.tokens});

  final CoreApi api;
  final String userName;
  final SessionTokens? tokens;

  factory Session.fromTokens(String serverUrl, SessionTokens tokens, {http.Client? client}) => Session(
        api: CoreApi(baseUrl: serverUrl, tokens: tokens, client: client),
        userName: tokens.current.userName,
        tokens: tokens,
      );
}

/// Dokąd przeglądarka oddaje jednorazowy kod po zalogowaniu.
enum LoginRedirect {
  /// Adres lokalny 127.0.0.1 (RFC 8252) – komputer; telefon tylko z `adb reverse` do serwera.
  loopback,

  /// Schemat aplikacji `truckmaps://auth/callback` z PKCE – telefon; Windows po rejestracji
  /// schematu przy starcie aplikacji.
  appScheme;

  /// `--dart-define=TRUCKMAPS_LOGIN_REDIRECT=app|loopback`; domyślnie schemat na telefonie,
  /// adres lokalny na komputerze.
  static LoginRedirect get platformDefault {
    const configured = String.fromEnvironment('TRUCKMAPS_LOGIN_REDIRECT');
    if (configured == 'app') return appScheme;
    if (configured == 'loopback' || kIsWeb) return loopback;
    return Platform.isAndroid || Platform.isIOS ? appScheme : loopback;
  }
}

/// Linki `truckmaps://…` od systemu (kanał `truckmaps/links` w kodzie natywnym aplikacji:
/// `MainActivity`, `AppDelegate`, `flutter_window.cpp`).
class AppLinks {
  AppLinks([this._channel = const MethodChannel('truckmaps/links')]) {
    _channel.setMethodCallHandler((call) async {
      final link = call.method == 'link' && call.arguments is String ? Uri.tryParse(call.arguments as String) : null;
      if (link != null) _links.add(link);
    });
  }

  final MethodChannel _channel;
  final _links = StreamController<Uri>.broadcast();

  Stream<Uri> get links => _links.stream;

  /// Link, którym system uruchomił aplikację (powrót z przeglądarki po zamknięciu aplikacji).
  Future<Uri?> initial() async {
    try {
      final link = await _channel.invokeMethod<String>('initial');
      return link == null ? null : Uri.tryParse(link);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// Logowanie przez przeglądarkę systemową (RFC 8252): serwer po zalogowaniu wraca do
/// aplikacji z jednorazowym kodem, a aplikacja wymienia kod na tokeny. Hasło ani token nie
/// przechodzą przez aplikację w adresie. Powrót ([LoginRedirect]): adres lokalny 127.0.0.1
/// (komputer) albo schemat `truckmaps://auth/callback` z PKCE (telefon – bez adresu lokalnego,
/// serwer z konfiguracji `TRUCKMAPS_SERVER`).
class BrowserLogin {
  BrowserLogin(this.serverUrl,
      {http.Client? client,
      SessionStore? store,
      LoginRedirect? redirect,
      AppLinks? links,
      FlutterSecureStorage? pending})
      : _client = client ?? http.Client(),
        _store = store ?? SecureSessionStore(),
        redirect = redirect ?? LoginRedirect.platformDefault,
        _givenLinks = links,
        _pending = pending ?? const FlutterSecureStorage();

  final String serverUrl;
  final http.Client _client;
  final SessionStore _store;
  final LoginRedirect redirect;
  final AppLinks? _givenLinks;
  late final AppLinks _links = _givenLinks ?? AppLinks();

  /// Weryfikator PKCE logowania w toku – przetrwa zamknięcie aplikacji przez system,
  /// gdy użytkownik jest w przeglądarce.
  final FlutterSecureStorage _pending;
  static const _pendingKey = 'truckmaps.login.verifier';
  static const timeout = Duration(minutes: 5);
  static const appCallback = 'truckmaps://auth/callback';

  /// Sesja zapisana przy poprzednim uruchomieniu (odświeżona, jeśli token wygasł).
  Future<Session?> restore() async {
    // Wersja przeglądarkowa: powrót z logowania z jednorazowym kodem w adresie strony.
    if (kIsWeb) {
      final code = Uri.base.queryParameters['code'];
      if (code != null) {
        try {
          return await exchange(code);
        } on LoginFailure {
          // Kod już użyty (np. odświeżona strona) – zostaje zapisana sesja albo logowanie.
        }
      }
    }
    if (!kIsWeb && redirect == LoginRedirect.appScheme) {
      // Powrót z przeglądarki, gdy system w międzyczasie zamknął aplikację.
      final link = await _links.initial();
      final verifier = link != null && _isCallback(link) ? await _readPending() : null;
      if (link != null && verifier != null) {
        try {
          return await _finishAppLink(link, verifier);
        } on LoginFailure {
          // Kod już użyty albo przeterminowany – zostaje zapisana sesja albo logowanie.
        }
      }
    }
    final saved = await _store.load();
    if (saved == null) return null;
    final tokens = SessionTokens(serverUrl, saved, _store, client: _client);
    if (saved.expiresAt.isBefore(DateTime.now()) && !await tokens.refresh()) {
      // Serwer odrzucił sesję (magazyn wyczyszczony) – logowanie; brak sieci – sesja zostaje.
      if (await _store.load() == null) return null;
    }
    return _session(tokens);
  }

  Session _session(SessionTokens tokens) => Session.fromTokens(serverUrl, tokens, client: _client);

  /// Logowanie w przeglądarce; [donePage] i [failedPage] – tekst strony po powrocie z logowania.
  /// [register] – najpierw formularz nowego konta, potem od razu zalogowanie.
  Future<Session> login({required String donePage, required String failedPage, bool register = false}) async {
    if (kIsWeb) return _webLogin(register: register);
    if (redirect == LoginRedirect.appScheme) return _appSchemeLogin(register: register);
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final callback = 'http://127.0.0.1:${server.port}/callback';
      final url = Uri.parse('$serverUrl/auth/login')
          .replace(queryParameters: {'app': callback, if (register) 'register': 'true'});
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const LoginFailure(LoginProblem.browser);
      }
      final request = await server
          .firstWhere((r) => r.uri.path == '/callback')
          .timeout(timeout, onTimeout: () => throw const LoginFailure(LoginProblem.timeout));
      final code = request.uri.queryParameters['code'];
      request.response
        ..headers.contentType = ContentType.html
        ..write(callbackPage(code == null ? failedPage : donePage, failed: code == null));
      await request.response.close();
      if (code == null) {
        throw LoginFailure(LoginProblem.failed, request.uri.queryParameters['error']);
      }
      return exchange(code);
    } finally {
      await server.close(force: true);
    }
  }

  /// Strona w przeglądarce po powrocie z logowania – w wyglądzie ekranów logowania TruckMaps.
  static String callbackPage(String message, {bool failed = false}) {
    final text = htmlEscape.convert(message);
    final color = failed ? 'var(--bad)' : 'var(--text)';
    return '<!doctype html><html><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width, initial-scale=1"><title>TruckMaps</title>'
        '<style>:root{--bg:#f6f8fb;--card:#fff;--text:#16202e;--line:#dde3ec;--bad:#c2410c}'
        '@media (prefers-color-scheme:dark){:root{--bg:#0f1722;--card:#16202e;--text:#e8eef7;'
        '--line:#2a3646;--bad:#f2994a}}'
        'body{margin:0;min-height:100vh;display:grid;place-items:center;padding:16px;'
        'background:var(--bg);color:var(--text);font:16px/1.6 "Segoe UI",system-ui,sans-serif}'
        'main{max-width:380px;width:100%;background:var(--card);border:1px solid var(--line);'
        'border-radius:14px;padding:24px;text-align:center}'
        '.logo{display:inline-flex;align-items:center;gap:10px;font-weight:700;font-size:20px}'
        'p{margin:16px 0 0;color:$color}</style></head><body><main><div class="logo">'
        '<svg width="32" height="32" viewBox="0 0 32 32" aria-hidden="true"><rect width="32" '
        'height="32" rx="8" fill="#0f5bd8"/><g fill="none" stroke="#fff" stroke-width="2.4" '
        'stroke-linecap="round"><circle cx="9" cy="23" r="3"/><circle cx="23" cy="9" r="3"/>'
        '<path d="M12 23h8a4 4 0 0 0 0-8h-8a4 4 0 0 1 0-8h8"/></g></svg>TruckMaps</div>'
        '<p>$text</p></main></body></html>';
  }

  /// Adres powrotu wersji przeglądarkowej: ta sama strona bez zapytania i fragmentu
  /// (serwer musi go mieć na liście `TRUCKMAPS_WEB_APP_ORIGINS`).
  static String webReturnUrl(Uri page) => '${page.origin}${page.path}';

  /// Wersja przeglądarkowa: przejście na stronę logowania w tej samej karcie; po powrocie
  /// [restore] wymienia kod z adresu na tokeny. Ta przyszłość się nie kończy (strona znika).
  Future<Session> _webLogin({required bool register}) async {
    final url = Uri.parse('$serverUrl/auth/login')
        .replace(queryParameters: {'app': webReturnUrl(Uri.base), if (register) 'register': 'true'});
    if (!await launchUrl(url, webOnlyWindowName: '_self')) {
      throw const LoginFailure(LoginProblem.browser);
    }
    return Completer<Session>().future;
  }

  /// Powrót przez schemat aplikacji: przeglądarka otwiera `truckmaps://auth/callback?code=…`,
  /// system przekazuje link aplikacji, a kod działa tylko z weryfikatorem PKCE tej aplikacji.
  Future<Session> _appSchemeLogin({required bool register}) async {
    final verifier = pkceVerifier();
    await _writePending(verifier);
    final returned = _links.links
        .firstWhere(_isCallback)
        .timeout(timeout, onTimeout: () => throw const LoginFailure(LoginProblem.timeout));
    final url = Uri.parse('$serverUrl/auth/login').replace(queryParameters: {
      'app': appCallback,
      'challenge': pkceChallenge(verifier),
      if (register) 'register': 'true',
    });
    if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
      returned.ignore();
      throw const LoginFailure(LoginProblem.browser);
    }
    return _finishAppLink(await returned, verifier);
  }

  Future<Session> _finishAppLink(Uri link, String verifier) async {
    await _writePending(null);
    final code = link.queryParameters['code'];
    if (code == null) throw LoginFailure(LoginProblem.failed, link.queryParameters['error']);
    return exchange(code, verifier: verifier);
  }

  static bool _isCallback(Uri link) => '${link.scheme}://${link.host}${link.path}' == appCallback;

  Future<String?> _readPending() async {
    try {
      return await _pending.read(key: _pendingKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writePending(String? verifier) async {
    try {
      verifier == null
          ? await _pending.delete(key: _pendingKey)
          : await _pending.write(key: _pendingKey, value: verifier);
    } catch (_) {
      // Bez magazynu logowanie i tak działa, dopóki system nie zamknie aplikacji.
    }
  }

  /// Losowy weryfikator PKCE (RFC 7636): 32 bajty w base64url bez dopełnienia (43 znaki).
  static String pkceVerifier([Random? random]) {
    final source = random ?? Random.secure();
    return base64Url.encode(List.generate(32, (_) => source.nextInt(256))).replaceAll('=', '');
  }

  /// S256: base64url(SHA-256(weryfikator)) bez dopełnienia – to samo liczy serwer.
  static String pkceChallenge(String verifier) =>
      base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');

  /// Jednorazowy kod → tokeny (`POST /auth/app/token`), zapisane na kolejne uruchomienia.
  /// [verifier] – PKCE, gdy kod wrócił przez schemat aplikacji.
  Future<Session> exchange(String code, {String? verifier}) async {
    final response = await _client.post(
      Uri.parse('$serverUrl/auth/app/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code, if (verifier != null) 'verifier': verifier}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw LoginFailure(LoginProblem.failed, body is Map ? '${body['detail']}' : null);
    }
    final tokens = Tokens.fromServer(body as Map<String, dynamic>);
    await _store.save(tokens);
    return _session(SessionTokens(serverUrl, tokens, _store, client: _client));
  }

  Future<void> logout() => _store.clear();

  /// Prośba o link do ustawienia nowego hasła (bez logowania). Zwraca komunikat serwera
  /// – ten sam, czy konto istnieje, czy nie.
  Future<String> requestPasswordReset(String email, {required String language}) async {
    final response = await _client.post(
      Uri.parse('$serverUrl/api/auth/password-reset'),
      headers: {'Content-Type': 'application/json', 'Accept-Language': language},
      body: jsonEncode({'email': email}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    final detail = body is Map ? body['detail'] : null;
    if (response.statusCode != 202) throw ApiException(response.statusCode, detail is String ? detail : '$detail');
    return '$detail';
  }
}

enum LoginProblem { browser, timeout, failed }

/// Nieudane logowanie; tekst dla użytkownika dobiera ekran logowania (w jego języku).
class LoginFailure implements Exception {
  const LoginFailure(this.problem, [this.detail]);

  final LoginProblem problem;

  /// Powód z serwera logowania, jeśli jest.
  final String? detail;

  @override
  String toString() => detail ?? problem.name;
}
