import 'package:app_auth/app_auth.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sesja przetrwa zapis i odczyt z magazynu', () {
    final tokens = Tokens(access: 'a', expiresAt: DateTime.utc(2026, 10, 30, 12), refresh: 'r', userName: 'Anna');
    final back = Tokens.fromJson(tokens.toJson());
    expect((back.access, back.expiresAt, back.refresh, back.userName), ('a', DateTime.utc(2026, 10, 30, 12), 'r', 'Anna'));
  });

  test('odświeżenie bez nowego tokenu odświeżania zostawia poprzedni', () {
    final tokens = Tokens.fromServer({'access_token': 'b', 'expires_in': 60}, previousName: 'Anna', previousRefresh: 'r');
    expect((tokens.refresh, tokens.userName), ('r', 'Anna'));
  });
}
