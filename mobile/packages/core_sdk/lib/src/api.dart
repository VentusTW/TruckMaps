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

/// Klient API rdzenia: adres serwera i token zalogowanego użytkownika.
class CoreApi {
  CoreApi({required this.baseUrl, required this.token, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final String token;
  final http.Client _client;

  Map<String, String> get _headers => {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      };

  Uri uri(String path) => Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path');

  Future<dynamic> get(String path) async =>
      _decode(await _client.get(uri(path), headers: _headers));

  Future<dynamic> post(String path, Object? body) async =>
      _decode(await _client.post(uri(path), headers: _headers, body: jsonEncode(body)));

  Future<dynamic> put(String path, Object? body) async =>
      _decode(await _client.put(uri(path), headers: _headers, body: jsonEncode(body)));

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
    return 'Błąd serwera ($status).';
  }
}
