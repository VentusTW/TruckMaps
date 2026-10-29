import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_hello/module_hello.dart';

void main() {
  testWidgets('ekran powitania pokazuje odpowiedź serwera', (tester) async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/m/hello/greeting');
      return http.Response(jsonEncode({'message': 'Witaj!', 'core_version': '0.1.0'}), 200);
    });
    final api = CoreApi(baseUrl: 'http://serwer.test', token: 't', client: client);
    final entries = HelloModule().entries(ModuleContext(api: api, userName: 'Anna'));

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(builder: entries.single.builder))));
    await tester.pumpAndSettle();

    expect(entries.single.title, 'Powitanie');
    expect(find.text('Witaj!'), findsOneWidget);
  });
}
