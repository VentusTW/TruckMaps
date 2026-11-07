import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_drivers/module_drivers.dart';

http.Response _json(Object? body) => http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

void main() {
  testWidgets('przydział kierowcy z kartoteki w pojeździe (nie konta użytkownika)', (tester) async {
    final posts = <(String, Object?)>[];
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        if (request.method == 'POST') {
          posts.add((request.url.path, jsonDecode(request.body)));
          return _json({});
        }
        if (request.url.path == '/api/m/drivers/drivers') {
          return _json([
            {
              'id': 'd1',
              'company_id': 'c1',
              'name': 'Piotr Nowak',
              'license_categories': ['CE'],
              'can_edit': true
            },
            {'id': 'd2', 'company_id': 'c2', 'name': 'Obcy', 'can_edit': true},
          ]);
        }
        if (request.url.path.endsWith('/check')) return _json({'warnings': <String>[], 'required_category': 'CE'});
        return _json(null);
      }),
    );
    final action =
        DriversModule().vehicleActions(ModuleContext(api: api, userName: 'Olek', locale: const Locale('pl'))).single;
    expect(action.id, assignDriverActionId);
    expect(action.applies!({'company_id': null, 'kind': 'tractor'}), isFalse);

    bool? changed;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async =>
                changed = await action.run(context, {'id': 'v1', 'name': 'MAN', 'company_id': 'c1', 'kind': 'tractor'}),
            child: const Text('przydziel'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('przydziel'));
    await tester.pumpAndSettle();
    expect(find.text('Piotr Nowak'), findsOneWidget);
    expect(find.text('Obcy'), findsNothing); // kierowca innej firmy
    await tester.tap(find.text('Piotr Nowak'));
    await tester.pumpAndSettle();

    expect(changed, isTrue);
    expect(posts.single.$1, '/api/m/drivers/drivers/d1/assign');
    expect(posts.single.$2, {'vehicle_id': 'v1'});
  });
}
