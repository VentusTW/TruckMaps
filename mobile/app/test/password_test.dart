import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/account/password.dart';
import 'package:truckmaps_app/src/auth.dart';
import 'package:truckmaps_app/src/login.dart';

import 'localized.dart';
import 'widget_test.dart' show MemoryStore;

http.Response json(Object? body, int status) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

void main() {
  late List<(String, Object?)> sent;

  setUp(() => sent = []);

  testWidgets('panel logowania: „Nie pamiętasz hasła?” wysyła prośbę o link', (tester) async {
    final client = MockClient((request) async {
      sent.add((request.url.path, jsonDecode(request.body)));
      return json({'detail': 'Jeśli to konto istnieje, wysłaliśmy link.'}, 202);
    });
    final login = BrowserLogin('http://serwer.test', client: client, store: MemoryStore());
    await tester.pumpWidget(
        localized(LoginScreen(serverUrl: 'http://serwer.test', login: login, onLoggedIn: (_) {})));

    expect(find.text('Utwórz konto'), findsOneWidget);
    await tester.tap(find.text('Nie pamiętasz hasła?'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), 'ola');
    await tester.tap(find.text('Wyślij link'));
    await tester.pumpAndSettle();
    expect(find.text('Wpisz poprawny adres e-mail.'), findsOneWidget);
    expect(sent, isEmpty);

    await tester.enterText(find.byType(TextFormField), ' ola@firma.pl ');
    await tester.tap(find.text('Wyślij link'));
    await tester.pumpAndSettle();
    expect(sent.single.$1, '/api/auth/password-reset');
    expect(sent.single.$2, {'email': 'ola@firma.pl'});
    expect(find.text('Jeśli to konto istnieje, wysłaliśmy link.'), findsOneWidget);
  });

  testWidgets('zmiana hasła: zasady, powtórzenie, błąd obecnego hasła z serwera', (tester) async {
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        final body = jsonDecode(request.body) as Map;
        sent.add((request.url.path, body));
        return body['current_password'] == 'Stare-haslo1'
            ? http.Response('', 204)
            : json({'detail': 'Obecne hasło jest nieprawidłowe.'}, 400);
      }),
    );
    await tester.pumpWidget(localized(ChangePasswordScreen(api: api)));

    Future<void> fill(String current, String next, String repeat) async {
      await tester.enterText(find.widgetWithText(TextFormField, 'Obecne hasło'), current);
      await tester.enterText(find.widgetWithText(TextFormField, 'Nowe hasło'), next);
      await tester.enterText(find.widgetWithText(TextFormField, 'Powtórz nowe hasło'), repeat);
      await tester.tap(find.byIcon(Icons.lock_reset));
      await tester.pumpAndSettle();
    }

    await fill('Stare-haslo1', 'slabe', 'slabe');
    expect(find.text('Co najmniej 8 znaków, wielka i mała litera, cyfra i symbol.'), findsNWidgets(2));
    await fill('Stare-haslo1', 'Nowe-haslo2', 'Nowe-haslo3');
    expect(find.text('Hasła się różnią.'), findsOneWidget);
    expect(sent, isEmpty);

    await fill('zle', 'Nowe-haslo2', 'Nowe-haslo2');
    expect(find.text('Obecne hasło jest nieprawidłowe.'), findsOneWidget);
    await fill('Stare-haslo1', 'Nowe-haslo2', 'Nowe-haslo2');
    expect(sent.last.$1, '/api/me/password');
    expect(sent.last.$2, {'current_password': 'Stare-haslo1', 'new_password': 'Nowe-haslo2'});
  });
}
