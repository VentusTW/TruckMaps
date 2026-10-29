import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Module extends TruckMapsModule {
  _Module(this.id);

  @override
  final String id;

  @override
  String get name => 'Moduł $id';

  @override
  String get description => 'opis';

  @override
  List<ModuleEntry> entries(ModuleContext context) => const [];
}

void main() {
  test('rejestr łączy pakiety aplikacji z modułami serwera', () {
    final registry = ModuleRegistry([_Module('hello'), _Module('tolls')]);

    final access = registry.resolve([
      const ServerModule(id: 'hello', name: 'Hello', granted: true),
      const ServerModule(id: 'parking', name: 'Parkingi', granted: false),
    ]);

    expect(access.map((a) => a.id), ['hello', 'parking']);
    expect(access[0].usable, isTrue);
    expect(access[0].name, 'Moduł hello');
    expect(access[1].usable, isFalse);
    expect(access[1].needsAppUpdate, isTrue);
  });

  test('klient API wysyła token i podaje komunikat błędu serwera', () async {
    final client = MockClient((request) async {
      expect(request.headers['Authorization'], 'Bearer t-1');
      if (request.url.path == '/api/m/tolls/x') {
        return http.Response.bytes(utf8.encode(jsonEncode({'detail': "Moduł 'tolls' nie jest aktywny."})), 402);
      }
      return http.Response.bytes(utf8.encode(jsonEncode([{'name': 'Zestaw ż'}])), 200);
    });
    final api = CoreApi(baseUrl: 'http://serwer.test/', token: 't-1', client: client);

    expect(await api.get('/api/vehicles'), [{'name': 'Zestaw ż'}]);
    final error = await api.get('/api/m/tolls/x').then<Object?>((_) => null, onError: (e) => e);
    expect(error, isA<ApiException>());
    expect((error as ApiException).needsPurchase, isTrue);
    expect(error.message, "Moduł 'tolls' nie jest aktywny.");
  });

  test('ServerModule z JSON', () {
    final module = ServerModule.fromJson({'id': 'hello', 'name': 'Hello', 'version': '0.1.0', 'granted': true});
    expect((module.id, module.granted, module.version), ('hello', true, '0.1.0'));
    expect(const ModuleEntry(title: 'x', icon: IconData(1), builder: _empty).title, 'x');
  });
}

Widget _empty(BuildContext context) => const SizedBox();
