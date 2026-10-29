import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/auth.dart';

import 'widget_test.dart' show MemoryStore;

Tokens saved({required Duration expiresIn, String? refresh = 'r-1'}) => Tokens(
      access: 'stary',
      expiresAt: DateTime.now().add(expiresIn),
      refresh: refresh,
      userName: 'Anna',
    );

void main() {
  test('zapisana, ważna sesja – bez logowania i bez odświeżania', () async {
    final store = MemoryStore()..tokens = saved(expiresIn: const Duration(minutes: 30));
    final client = MockClient((request) async => fail('nie powinno być zapytań: ${request.url}'));

    final session = await BrowserLogin('http://serwer.test', client: client, store: store).restore();

    expect(session?.userName, 'Anna');
    expect(await session!.tokens!.token(), 'stary');
  });

  test('wygasły token – odświeżenie i zapis nowego', () async {
    final store = MemoryStore()..tokens = saved(expiresIn: const Duration(minutes: -5));
    final client = MockClient((request) async {
      expect(request.url.path, '/auth/app/refresh');
      expect(jsonDecode(request.body), {'refresh_token': 'r-1'});
      return http.Response(jsonEncode({'access_token': 'nowy', 'expires_in': 900, 'name': ''}), 200);
    });

    final session = await BrowserLogin('http://serwer.test', client: client, store: store).restore();

    expect(await session!.tokens!.token(), 'nowy');
    expect(store.tokens?.access, 'nowy');
    expect(store.tokens?.refresh, 'r-1'); // serwer nie dał nowego – zostaje stary
    expect(session.userName, 'Anna');
  });

  test('serwer odrzuca sesję – magazyn wyczyszczony, logowanie od nowa', () async {
    final store = MemoryStore()..tokens = saved(expiresIn: const Duration(minutes: -5));
    final client = MockClient((request) async => http.Response('{"detail": "expired"}', 401));

    final session = await BrowserLogin('http://serwer.test', client: client, store: store).restore();

    expect(session, isNull);
    expect(store.tokens, isNull);
  });

  test('brak sieci przy starcie – sesja zostaje', () async {
    final store = MemoryStore()..tokens = saved(expiresIn: const Duration(minutes: -5));
    final client = MockClient((request) async => throw http.ClientException('brak sieci'));

    final session = await BrowserLogin('http://serwer.test', client: client, store: store).restore();

    expect(session, isNotNull);
    expect(store.tokens, isNotNull);
  });
}
