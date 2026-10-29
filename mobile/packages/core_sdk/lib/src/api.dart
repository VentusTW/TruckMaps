import 'dart:convert';

import 'package:http/http.dart' as http;

/// Błąd odpowiedzi serwera z komunikatem dla użytkownika (pole `detail` FastAPI).
class ApiException implements Exception {
  ApiException(this.status, this.message);

  final int status;
  final String message;

  /// 402 – moduł nie jest aktywny dla tego konta.
  bool get needsPurchase => status == 402;

  @override
  String toString() => message;
}

/// Skąd klient API bierze token: powłoka odświeża go, zanim wygaśnie.
abstract class TokenSource {
  /// Aktualny token dostępu (odświeżony, jeśli zaraz wygasa).
  Future<String> token();

  /// Odświeżenie po odpowiedzi 401; `false` – sesja wygasła, trzeba się zalogować.
  Future<bool> refresh();
}

class _FixedToken implements TokenSource {
  _FixedToken(this._token);

  final String _token;

  @override
  Future<String> token() async => _token;

  @override
  Future<bool> refresh() async => false;
}

/// Klient API rdzenia: adres serwera i token zalogowanego użytkownika.
class CoreApi {
  CoreApi({required this.baseUrl, String? token, TokenSource? tokens, http.Client? client})
      : assert(token != null || tokens != null),
        _tokens = tokens ?? _FixedToken(token!),
        _client = client ?? http.Client();

  final String baseUrl;

  /// Język użytkownika (np. "pl", "en") – serwer odpowiada w nim (`Accept-Language`).
  String? language;

  final TokenSource _tokens;
  final http.Client _client;

  Uri uri(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Future<dynamic> get(String path) => _send((headers) => _client.get(uri(path), headers: headers));

  Future<dynamic> post(String path, Object? body) =>
      _send((headers) => _client.post(uri(path), headers: headers, body: jsonEncode(body)));

  Future<dynamic> put(String path, Object? body) =>
      _send((headers) => _client.put(uri(path), headers: headers, body: jsonEncode(body)));

  Future<dynamic> _send(Future<http.Response> Function(Map<String, String> headers) request) async {
    Future<http.Response> attempt() async => request({
          'Authorization': 'Bearer ${await _tokens.token()}',
          'Content-Type': 'application/json',
          if (language != null) 'Accept-Language': language!,
        });
    var response = await attempt();
    // Token wygasł po drodze (np. komputer był uśpiony) – jedno odświeżenie i ponowienie.
    if (response.statusCode == 401 && await _tokens.refresh()) response = await attempt();
    return _decode(response);
  }

  dynamic _decode(http.Response response) {
    final text = utf8.decode(response.bodyBytes);
    final body = text.isEmpty ? null : jsonDecode(text);
    if (response.statusCode >= 400) {
      throw ApiException(response.statusCode, _message(body, response.statusCode));
    }
    return body;
  }

  static String _message(dynamic body, int status) {
    final detail = body is Map ? body['detail'] : null;
    if (detail is String) return detail;
    if (detail is List && detail.isNotEmpty && detail.first is Map) {
      return '${detail.first['msg']}';
    }
    return 'HTTP $status';
  }
}
