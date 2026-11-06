import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/operations/operations_screen.dart';

import 'localized.dart';

http.Response json(Object? body, [int status = 200]) => http.Response.bytes(utf8.encode(jsonEncode(body)), status);

final overview = {
  'company_id': 'c1',
  'company_name': 'Trans-Miś',
  'user_name': 'Ewa',
  'role': 'dispatcher',
  'bases': ['Warszawa'],
  'generated_at': '2026-11-06T08:00:00Z',
  'telematics': false,
  'sources': ['core', 'drivers'],
  'kpis': [
    {'key': 'fleet.active', 'value': 2, 'total': 3, 'unit': '', 'tone': 'info', 'order': 10, 'source': 'core'},
    {'key': 'fleet.health', 'value': 66.7, 'total': null, 'unit': '%', 'tone': 'error', 'order': 40, 'source': 'core'},
    {'key': 'costs.today', 'value': 250.5, 'total': null, 'unit': 'PLN', 'tone': 'info', 'order': 80, 'source': 'core'},
    {'key': 'future.kpi', 'value': 1, 'total': null, 'unit': '', 'tone': 'info', 'order': 300, 'source': 'x'},
  ],
  'alert_counts': {'critical': 1, 'warning': 1, 'info': 0},
};

final alerts = [
  {
    'id': 'vehicle:due:v1:inspection_until:2026-11-05',
    'kind': 'vehicle_due',
    'severity': 'critical',
    'data': {'field': 'inspection_until', 'day': '2026-11-05', 'overdue': true},
    'vehicle_id': 'v1',
    'vehicle_name': 'MAN TGX',
    'plate': 'WI 4022P',
    'driver_subject': 'jan',
    'driver_name': 'Jan',
    'actions': ['acknowledge', 'message_driver'],
    'source': 'core',
  },
  {
    'id': 'service:order:o1:new',
    'kind': 'service.order',
    'severity': 'warning',
    'data': {'status': 'new', 'urgency': 'can_drive', 'description': 'Wycieka olej'},
    'vehicle_id': 'v2',
    'vehicle_name': 'Volvo FH',
    'plate': 'WZ 7701L',
    'actions': ['acknowledge'],
    'source': 'service',
  },
];

void main() {
  testWidgets('pulpit operacyjny: wskaźniki, sprawy i akcje dyspozytora', (tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final posts = <String, Object?>{};
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          posts[path] = jsonDecode(request.body);
          return json({'alert_id': 'x', 'action': 'acknowledge', 'duplicate': false, 'handled': {}});
        }
        return switch (path) {
          '/api/dashboard/overview' => json(overview),
          '/api/dashboard/alerts' => json(alerts),
          '/api/dashboard/stream' => http.Response.bytes(
              utf8.encode(
                  ': ping\n\nevent: snapshot\ndata: ${jsonEncode({'overview': overview, 'alerts': alerts})}\n\n'),
              200,
              headers: {'content-type': 'text/event-stream'}),
          _ => json({'detail': 'brak'}, 404),
        };
      }),
    );
    var opened = 0;
    await tester.pumpWidget(localized(Scaffold(
      body: OperationsScreen(
        api: api,
        companyId: 'c1',
        retryAfter: const Duration(hours: 1),
        shortcuts: [OpsShortcut('Zaplanuj trasę', Icons.route_outlined, () => opened++)],
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Pulpit operacyjny'), findsOneWidget);
    expect(find.textContaining('Trans-Miś'), findsOneWidget);
    expect(find.text('Bazy: Warszawa'), findsOneWidget);
    expect(find.byKey(const Key('ops-kpi-fleet.active')), findsOneWidget);
    expect(find.textContaining('z 3 · wykorzystanie 67%'), findsOneWidget);
    expect(find.byKey(const Key('ops-kpi-costs.today-PLN')), findsOneWidget);
    expect(find.text('SPRAWNOŚĆ FLOTY'), findsOneWidget);
    // Nieznany wskaźnik (nowszy moduł) jest pomijany.
    expect(find.byKey(const Key('ops-kpi-future.kpi')), findsNothing);
    expect(find.textContaining('Brak integracji telematycznej'), findsOneWidget);

    expect(find.text('Zlecenie serwisowe: Volvo FH · WZ 7701L'), findsOneWidget);
    expect(find.textContaining('Wycieka olej'), findsOneWidget);
    expect(find.text('Kierowca: Jan'), findsOneWidget);

    // Filtr: tylko pilne.
    await tester.tap(find.text('Pilne (1)'));
    await tester.pump();
    expect(find.textContaining('Zlecenie serwisowe'), findsNothing);
    await tester.tap(find.text('Wszystkie (2)'));
    await tester.pump();

    // Wiadomość do kierowcy.
    await tester.tap(find.byKey(Key('ops-message-${alerts[0]['id']}')));
    await tester.pumpAndSettle();
    expect(find.text('Wiadomość do: Jan'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('ops-message-text')), '  Zjedź na przegląd ');
    await tester.tap(find.byKey(const Key('ops-message-send')));
    await tester.pumpAndSettle();
    final messagePath = '/api/dashboard/alerts/${Uri.encodeComponent('${alerts[0]['id']}')}/action';
    expect(posts[Uri.decodeComponent(messagePath)] ?? posts[messagePath],
        {'company_id': 'c1', 'action': 'message_driver', 'text': 'Zjedź na przegląd'});
    expect(find.text('Wysłano do kierowcy'), findsOneWidget);

    // Obsłużone – zlecenie serwisowe nie ma kierowcy, więc tylko ten przycisk.
    expect(find.byKey(Key('ops-message-${alerts[1]['id']}')), findsNothing);
    await tester.tap(find.byKey(Key('ops-ack-${alerts[1]['id']}')));
    await tester.pumpAndSettle();
    expect(posts.values.last, {'company_id': 'c1', 'action': 'acknowledge'});

    await tester.tap(find.text('Zaplanuj trasę'));
    expect(opened, 1);

    await tester.pumpWidget(const SizedBox()); // zamyka strumień i timer ponowienia
  });
}
