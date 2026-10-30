import 'dart:convert';
import 'dart:io';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/auth.dart';
import 'package:truckmaps_app/src/home.dart';
import 'package:truckmaps_app/src/planner/planner_screen.dart';
import 'package:truckmaps_app/src/updates.dart';

import 'localized.dart';

http.Response json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

void main() {
  setUp(() => mapTiles = () => const SizedBox());

  test('wersja aplikacji jak w pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: ([^+\s]+)', multiLine: true).firstMatch(pubspec)!.group(1), appVersion);
  });

  Future<(List<Map?>, List<Uri>)> home(WidgetTester tester, List<Object> updates) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final sent = <Map?>[];
    final opened = <Uri>[];
    final client = MockClient((request) async {
      if (request.url.path == '/api/updates/check') {
        sent.add(jsonDecode(request.body) as Map);
        return json(updates);
      }
      return json(request.url.path == '/api/me/settings' ? {'onboarded': true} : []);
    });
    await tester.pumpWidget(localized(HomeScreen(
      session: Session(api: CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client), userName: 'Anna'),
      registry: ModuleRegistry(const []),
      onLogout: () {},
      openUrl: opened.add,
    )));
    await tester.pumpAndSettle();
    return (sent, opened);
  }

  testWidgets('po zalogowaniu pyta o nową wersję: rozmiar, zmiany, pobranie', (tester) async {
    final (sent, opened) = await home(tester, [
      {
        'kind': 'app',
        'name': 'truckmaps',
        'installed_version': appVersion,
        'version': '0.2.0',
        'action': 'update',
        'url': 'https://example.test/truckmaps-0.2.0.zip',
        'size_bytes': 52400000,
        'sha256': '',
        'notes': 'Konto i firmy',
        'published_at': '2026-10-30T10:00:00Z',
      },
    ]);

    expect(sent.single!['installed'], [
      {'kind': 'app', 'name': 'truckmaps', 'version': appVersion}
    ]);
    expect(find.text('Jest nowa wersja'), findsOneWidget);
    expect(find.text('TruckMaps $appVersion → 0.2.0 (52,4 MB)'), findsOneWidget);
    expect(find.text('Konto i firmy'), findsOneWidget);
    await tester.tap(find.text('Pobierz'));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://example.test/truckmaps-0.2.0.zip')]);
    expect(find.text('Jest nowa wersja'), findsNothing);
  });

  testWidgets('bez nowszej wersji – bez pytania', (tester) async {
    await home(tester, []);
    expect(find.byType(UpdateDialog), findsNothing);
  });
}
