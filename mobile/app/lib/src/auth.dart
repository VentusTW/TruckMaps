import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:core_sdk/core_sdk.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

/// Zalogowany użytkownik: klient API z tokenem i nazwa do wyświetlenia.
class Session {
  Session({required this.api, required this.userName, required this.expiresAt});

  final CoreApi api;
  final String userName;
  final DateTime expiresAt;
}

/// Logowanie przez przeglądarkę systemową (RFC 8252): aplikacja nasłuchuje na adresie
/// lokalnym 127.0.0.1, serwer po zalogowaniu wraca tam z jednorazowym kodem, a aplikacja
/// wymienia kod na token. Hasło ani token nie przechodzą przez aplikację w adresie.
class BrowserLogin {
  BrowserLogin(this.serverUrl, {http.Client? client}) : _client = client ?? http.Client();

  final String serverUrl;
  final http.Client _client;
  static const timeout = Duration(minutes: 5);

  Future<Session> login() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    try {
      final callback = 'http://127.0.0.1:${server.port}/callback';
      final url = Uri.parse('$serverUrl/auth/login').replace(queryParameters: {'app': callback});
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw const HttpException('Nie udało się otworzyć przeglądarki.');
      }
      final request = await server
          .firstWhere((r) => r.uri.path == '/callback')
          .timeout(timeout, onTimeout: () => throw TimeoutException('Logowanie trwało zbyt długo.'));
      final code = request.uri.queryParameters['code'];
      request.response
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><meta charset="utf-8"><title>TruckMaps</title>'
            '<p style="font:16px system-ui;margin:40px">'
            '${code == null ? 'Logowanie nie powiodło się.' : 'Zalogowano. Możesz wrócić do aplikacji TruckMaps.'}</p>');
      await request.response.close();
      if (code == null) {
        throw HttpException(request.uri.queryParameters['error'] ?? 'Logowanie przerwane.');
      }
      return exchange(code);
    } finally {
      await server.close(force: true);
    }
  }

  /// Jednorazowy kod → token (`POST /auth/app/token`).
  Future<Session> exchange(String code) async {
    final response = await _client.post(
      Uri.parse('$serverUrl/auth/app/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'code': code}),
    );
    final body = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode != 200) {
      throw HttpException(body is Map ? '${body['detail']}' : 'Logowanie nie powiodło się.');
    }
    return Session(
      api: CoreApi(baseUrl: serverUrl, token: body['access_token'] as String, client: _client),
      userName: body['name'] as String? ?? '',
      expiresAt: DateTime.now().add(Duration(seconds: body['expires_in'] as int? ?? 3600)),
    );
  }
}
