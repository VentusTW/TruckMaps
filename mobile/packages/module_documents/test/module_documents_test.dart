import 'dart:convert';
import 'dart:typed_data';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:module_documents/module_documents.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

const kinds = [
  {
    'id': 'cmr',
    'name': 'CMR consignment note',
    'basis': '',
    'fields': [
      {'key': 'sender', 'type': 'multiline', 'label': '1. Sender', 'width': 0.5, 'box': '1', 'columns': []},
      {
        'key': 'tractor_plate',
        'type': 'text',
        'label': 'Vehicle registration',
        'width': 0.25,
        'box': '',
        'columns': []
      },
      {
        'key': 'goods',
        'type': 'rows',
        'label': 'Goods',
        'width': 1.0,
        'box': '6–12',
        'columns': [
          {'key': 'packages', 'label': 'Number of packages'},
          {'key': 'nature', 'label': 'Nature of the goods'},
        ],
      },
    ],
  },
];

// 1×1 PNG
final png =
    base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  late List<(String, String, Object?)> requests;
  late Map<String, dynamic> template;
  late Map<String, dynamic> profile;
  late List<Map<String, dynamic>> documents;
  late List<Uri> opened;

  Map<String, dynamic> templateOut() => {
        ...template,
        'kind': 'cmr',
        'fields': [
          for (final f in (kinds.first['fields'] as List))
            if (!(template['hidden'] as List).contains((f as Map)['key'])) f,
          for (final x in template['extra_fields'] as List) {...(x as Map), 'box': '', 'columns': []},
        ],
      };

  CoreApi api() => CoreApi(
        baseUrl: 'http://serwer.test',
        token: 't',
        client: MockClient((request) async {
          final body = request.body.isEmpty ? null : jsonDecode(request.body);
          final path = request.url.path;
          requests.add((request.method, path, body));
          if (path == '/api/companies') {
            return json([
              {'id': 'c1', 'name': 'Trans-Miś', 'role': 'owner'}
            ]);
          }
          if (path == '/api/vehicles') {
            return json([
              {'id': 'v1', 'name': 'MAN', 'plate': 'WGM 1', 'company_id': 'c1'},
              {'id': 'v2', 'name': 'Prywatny', 'plate': null, 'company_id': null},
            ]);
          }
          if (path == '/api/m/documents/kinds') return json(kinds);
          if (path == '/api/m/documents/documents' && request.method == 'GET') return json(documents);
          if (path == '/api/m/documents/documents') {
            final doc = {
              'id': 'd1',
              'company_id': 'c1',
              'kind': 'cmr',
              'number': 'CMR/2026/11/0001',
              'vehicle_id': (body as Map)['vehicle_id'],
              'data': body['data'],
              'created_by_name': 'Olek',
              'created_at': '2026-11-05T08:00:00Z',
              'updated_at': '2026-11-05T08:00:00Z',
            };
            documents = [doc];
            return json(doc, 201);
          }
          if (path == '/api/m/documents/documents/d1/link') return json({'path': '/api/shared/abc', 'filename': 'x'});
          if (path == '/api/m/documents/templates/cmr' && request.method == 'GET') return json(templateOut());
          if (path == '/api/m/documents/templates/cmr') {
            final extra = [
              for (final (i, x) in ((body as Map)['extra_fields'] as List).indexed)
                {...(x as Map), 'key': (x['key'] as String).isEmpty ? 'x_field_$i' : x['key']},
            ];
            template = {...body.cast<String, dynamic>(), 'extra_fields': extra};
            return json(templateOut());
          }
          if (path == '/api/m/documents/prefill') {
            return json({
              'data': {
                'tractor_plate': 'WGM 1',
                'goods': [
                  {'packages': 10, 'nature': 'Płytki'}
                ],
              },
              'sources': {'tractor_plate': 'vehicle', 'goods': 'cargo'},
              'warnings': ['Complete the company profile.'],
            });
          }
          if (path == '/api/m/documents/profile') {
            if (request.method == 'PUT') profile = {...(body as Map).cast<String, dynamic>(), 'logo': profile['logo']};
            return json(profile);
          }
          if (path == '/api/m/documents/profile/logo') {
            profile = {...profile, 'has_logo': true, 'logo': base64Encode(png)};
            return json(profile);
          }
          return json({'detail': 'nie ma $path'}, 404);
        }),
      );

  setUp(() {
    requests = [];
    documents = [];
    opened = [];
    template = {'labels': {}, 'defaults': {}, 'hidden': [], 'extra_fields': [], 'terms': ''};
    profile = {'city': 'Warszawa', 'has_logo': false, 'logo': null};
  });

  // Domyślny język MaterialApp w testach – angielski.
  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  // Wysoki ekran – cały formularz bez przewijania.
  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(1000, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('new document: vehicle prefills fields, save, PDF link', (tester) async {
    await tester.pumpWidget(app(DocumentFormScreen(
      api: api(),
      companyId: 'c1',
      kind: 'cmr',
      vehicleId: 'v1',
      linkOpener: (link) async {
        opened.add(link);
        return true;
      },
    )));
    await tester.pumpAndSettle();

    // Pojazd z karty – podpowiedzi od razu.
    expect(requests.where((r) => r.$2 == '/api/m/documents/prefill').single.$3, containsPair('vehicle_id', 'v1'));
    expect(find.widgetWithText(TextField, 'WGM 1'), findsOneWidget);
    expect(find.text('from the vehicle'), findsOneWidget);
    expect(find.text('Complete the company profile.'), findsOneWidget);
    expect(find.text('Prywatny'), findsNothing);

    await tester.enterText(find.byKey(const Key('field-sender')), 'Nadawca SA');
    await tester.tap(find.byKey(const Key('add-row-goods')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('document-save')));
    await tester.pumpAndSettle();

    final saved = requests.lastWhere((r) => r.$1 == 'POST' && r.$2 == '/api/m/documents/documents').$3 as Map;
    expect(saved['kind'], 'cmr');
    expect(saved['vehicle_id'], 'v1');
    expect(saved['data'], {
      'sender': 'Nadawca SA',
      'tractor_plate': 'WGM 1',
      'goods': [
        {'packages': '10', 'nature': 'Płytki'}
      ],
    });
    expect(find.text('CMR/2026/11/0001'), findsOneWidget);

    await tester.tap(find.byKey(const Key('document-pdf')));
    await tester.pumpAndSettle();
    expect(opened.single.toString(), 'http://serwer.test/api/shared/abc');
  });

  testWidgets('template: rename, hide and add a company field', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(TemplateScreen(api: api(), companyId: 'c1', kind: 'cmr')));
    await tester.pumpAndSettle();
    expect(find.text('CMR consignment note'), findsOneWidget);

    // Ukrycie pola
    await tester
        .tap(find.descendant(of: find.byKey(const Key('template-tractor_plate')), matching: find.byType(Switch)));
    // Zmiana nazwy pola wzoru
    await tester
        .tap(find.descendant(of: find.byKey(const Key('template-sender')), matching: find.byIcon(Icons.edit_outlined)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('template-field-label')), 'Shipper');
    await tester.enterText(find.byKey(const Key('template-field-default')), 'Our warehouse');
    await tester.tap(find.byKey(const Key('template-field-ok')));
    await tester.pumpAndSettle();
    // Nowe pole firmy
    await tester.tap(find.byKey(const Key('template-add-field')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('template-field-label')), 'Customer PO');
    await tester.tap(find.byKey(const Key('template-field-ok')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('template-terms')), 'Pallet exchange: no.');
    await tester.tap(find.byKey(const Key('template-save')));
    await tester.pumpAndSettle();

    final body = requests.lastWhere((r) => r.$1 == 'PUT').$3 as Map;
    expect(body['labels'], {'sender': 'Shipper'});
    expect(body['defaults'], {'sender': 'Our warehouse'});
    expect(body['hidden'], ['tractor_plate']);
    expect(body['extra_fields'], [
      {'key': '', 'label': 'Customer PO', 'type': 'text', 'width': 1.0}
    ]);
    expect(body['terms'], 'Pallet exchange: no.');
    expect(find.text('Saved.'), findsOneWidget);
    expect(find.text('Customer PO'), findsOneWidget);
  });

  testWidgets('company details and logo', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(CompanyProfileScreen(
      api: api(),
      companyId: 'c1',
      imagePicker: () async => Uint8List.fromList(png),
    )));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Warszawa'), findsOneWidget);
    expect(find.byKey(const Key('profile-logo')), findsNothing);

    await tester.tap(find.byKey(const Key('profile-logo-pick')));
    await tester.pumpAndSettle();
    expect(requests.last.$2, '/api/m/documents/profile/logo');
    expect((requests.last.$3 as Map)['image'], base64Encode(png));
    expect(find.byKey(const Key('profile-logo')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('profile-licence_number')), 'LW/1');
    await tester.tap(find.byKey(const Key('profile-save')));
    await tester.pumpAndSettle();
    final body = requests.last.$3 as Map;
    expect(body['licence_number'], 'LW/1');
    expect(body['city'], 'Warszawa');
  });

  testWidgets('list: documents of the company, new document by type', (tester) async {
    documents = [
      {
        'id': 'd9',
        'company_id': 'c1',
        'kind': 'cmr',
        'number': 'CMR/2026/11/0009',
        'vehicle_id': null,
        'data': {},
        'created_by_name': 'Jan',
        'created_at': '2026-11-05T08:00:00Z',
        'updated_at': '2026-11-05T08:00:00Z',
      }
    ];
    await tester.pumpWidget(app(DocumentsScreen(api: api())));
    await tester.pumpAndSettle();
    expect(find.text('CMR/2026/11/0009'), findsOneWidget);
    expect(find.textContaining('CMR consignment note · Jan'), findsOneWidget);
    expect(find.byKey(const Key('documents-profile')), findsOneWidget);

    await tester.tap(find.byKey(const Key('documents-add')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('kind-cmr')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('document-save')), findsOneWidget);
  });
}
