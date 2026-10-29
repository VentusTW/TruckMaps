import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_sdk/core_sdk.dart';
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
  SecureSessionStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _key = 'truckmaps.session';

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

/// Logowanie przez przeglądarkę systemową (RFC 8252): aplikacja nasłuchuje na adresie
/// lokalnym 127.0.0.1, serwer po zalogowaniu wraca tam z jednorazowym kodem, a aplikacja
/// wymienia kod na tokeny. Hasło ani token nie przechodzą przez aplikację w adresie.
/// Na telefonie działa tak samo (przeglądarka i aplikacja na tym samym urządzeniu).
class BrowserLogin {
  BrowserLogin(this.serverUrl, {http.Client? client, SessionStore? store})
      : _client = client ?? http.Client(),
        _store = store ?? SecureSessionStore();

  final String serverUrl;
  final http.Client _client;
  final SessionStore _store;
  static const timeout = Duration(minutes: 5);

  /// Sesja zapisana przy poprzednim uruchomieniu (odświeżona, jeśli token wygasł).
  Future<Session?> restore() async {
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
  Future<Session> login({required String donePage, required String failedPage}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final callback = 'http://127.0.0.1:${server.port}/callback';
      final url = Uri.parse('$serverUrl/auth/login').replace(queryParameters: {'app': callback});
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const LoginFailure(LoginProblem.browser);
      }
      final request = await server
          .firstWhere((r) => r.uri.path == '/callback')
          .timeout(timeout, onTimeout: () => throw const LoginFailure(LoginProblem.timeout));
      final code = request.uri.queryParameters['code'];
      request.response
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><meta charset="utf-8"><title>TruckMaps</title>'
            '<p style="font:16px system-ui;margin:40px">'
            '${htmlEscape.convert(code == null ? failedPage : donePage)}</p>');
      await request.response.close();
      if (code == null) {
        throw LoginFailure(LoginProblem.failed, request.uri.queryParameters['error']);
      }
      return exchange(code);
    } finally {
      await server.close(force: true);
    }
  }

  /// Jednorazowy kod → tokeny (`POST /auth/app/token`), zapisane na kolejne uruchomienia.
  Future<Session> exchange(String code) async {
    final response = await _client.post(
      Uri.parse('$serverUrl/auth/app/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code}),
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
