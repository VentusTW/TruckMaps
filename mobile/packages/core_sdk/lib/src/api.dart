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

  Future<dynamic> delete(String path) => _send((headers) => _client.delete(uri(path), headers: headers));

  /// Zdarzenia Server-Sent Events (np. pulpit operacyjny na żywo): nazwa i dane JSON.
  /// Anulowanie subskrypcji zamyka połączenie.
  Stream<({String event, dynamic data})> events(String path) async* {
    Future<http.StreamedResponse> attempt() async {
      final request = http.Request('GET', uri(path))
        ..headers.addAll({
          'Authorization': 'Bearer ${await _tokens.token()}',
          'Accept': 'text/event-stream',
          if (language != null) 'Accept-Language': language!,
        });
      return _client.send(request);
    }

    var response = await attempt();
    if (response.statusCode == 401 && await _tokens.refresh()) response = await attempt();
    if (response.statusCode >= 400) {
      final text = await response.stream.bytesToString();
      dynamic body;
      try {
        body = text.isEmpty ? null : jsonDecode(text);
      } on FormatException {
        body = null;
      }
      throw ApiException(response.statusCode, _message(body, response.statusCode));
    }
    var event = 'message';
    final data = StringBuffer();
    await for (final line in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (data.isNotEmpty) yield (event: event, data: jsonDecode(data.toString()));
        event = 'message';
        data.clear();
      } else if (line.startsWith('event:')) {
        event = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        if (data.isNotEmpty) data.write('\n');
        data.write(line.substring(5).trimLeft());
      }
      // Linie zaczynające się od „:” to komentarze podtrzymujące połączenie.
    }
  }

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
