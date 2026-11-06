import 'dart:convert';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:truckmaps_app/src/dashboard/dispatcher_dashboard.dart';

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
  'sources': ['core', 'service'],
  'kpis': [
    {'key': 'fleet.active', 'value': 2, 'total': 3, 'unit': '', 'tone': 'info', 'order': 10, 'source': 'core'},
    {'key': 'fleet.health', 'value': 66.7, 'total': null, 'unit': '%', 'tone': 'error', 'order': 40, 'source': 'core'},
    {'key': 'costs.today', 'value': 250.5, 'total': null, 'unit': 'PLN', 'tone': 'info', 'order': 80, 'source': 'core'},
    {'key': 'service.open', 'value': 4, 'total': null, 'unit': '', 'tone': 'info', 'order': 120, 'source': 'service'},
    {'key': 'inbox.unread', 'value': 1, 'total': null, 'unit': '', 'tone': 'info', 'order': 200, 'source': 'core'},
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

final vehicles = [
  {
    'id': 'v1',
    'name': 'MAN TGX',
    'plate': 'WI 4022P',
    'kind': 'tractor',
    'company_id': 'c1',
    'in_use': true,
    'driver_name': 'Jan',
    'trailer_name': 'Krone SD'
  },
  {'id': 't1', 'name': 'Krone SD', 'kind': 'semitrailer', 'company_id': 'c1', 'in_use': true},
  {'id': 'v3', 'name': 'DAF XF', 'kind': 'tractor', 'company_id': 'c1', 'in_use': false},
  {'id': 'v9', 'name': 'Obcy', 'kind': 'tractor', 'company_id': 'inna', 'in_use': true},
];

final messages = {
  'unread': 1,
  'items': [
    {
      'id': 'm1',
      'kind': 'dispatch_note',
      'sender_name': 'Ewa',
      'created_at': '2026-11-06T07:30:00Z',
      'data': {'text': 'Zjedź na MOP Świebodzin'},
    },
  ],
};

void main() {
  testWidgets('pulpit główny: powitanie, wskaźniki, sprawy z akcjami, zestawy w trasie, kafle i komunikaty',
      (tester) async {
    tester.view.physicalSize = const Size(1600, 2400);
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
          '/api/vehicles' => json(vehicles),
          '/api/me/messages' => json(messages),
          '/api/dashboard/stream' => http.Response.bytes(
              utf8.encode(
                  ': ping\n\nevent: snapshot\ndata: ${jsonEncode({'overview': overview, 'alerts': alerts})}\n\n'),
              200,
              headers: {'content-type': 'text/event-stream'}),
          _ => json({'detail': 'brak'}, 404),
        };
      }),
    );
    var opened = <String>[];
    final summaries = <DashSummary>[];
    await tester.pumpWidget(localized(Scaffold(
      body: DispatcherDashboard(
        api: api,
        companyId: 'c1',
        userName: 'Ewa Nowak',
        retryAfter: const Duration(hours: 1),
        onSummary: summaries.add,
        onOpenInbox: () => opened.add('inbox'),
        actions: [DashAction('Nowa trasa', Icons.add, () => opened.add('route'))],
        tiles: [
          DashTile('Serwis', Icons.build_outlined, () => opened.add('service'),
              description: 'Zlecenia napraw', kpiKey: 'service.open'),
        ],
      ),
    )));
    await tester.pumpAndSettle();

    // Powitanie z imieniem, stan floty i firma.
    expect(find.text('Dzień dobry, Ewa'), findsOneWidget);
    expect(find.text('66,7% sprawności floty'), findsOneWidget);
    expect(find.textContaining('Trans-Miś'), findsOneWidget);
    expect(find.textContaining('Bazy: Warszawa'), findsOneWidget);

    // Cztery główne wskaźniki; reszta znanych w wierszu, nieznany pominięty.
    expect(find.byKey(const Key('ops-kpi-fleet.active')), findsOneWidget);
    expect(find.text('wykorzystanie 67%'), findsOneWidget);
    expect(find.text('SPRAWNOŚĆ FLOTY'), findsOneWidget);
    expect(find.byKey(const Key('ops-kpi-costs.today-PLN')), findsOneWidget);
    expect(find.byKey(const Key('ops-kpi-inbox.unread')), findsOneWidget);
    expect(find.byKey(const Key('ops-kpi-future.kpi')), findsNothing);

    // Sprawy: rodzaj, pojazd, opis; licznik priorytetowych.
    expect(find.text('2 ZDARZENIA PRIORYTETOWE'), findsOneWidget);
    expect(find.text('ZLECENIE SERWISOWE'), findsOneWidget);
    expect(find.text('Volvo FH · WZ 7701L'), findsOneWidget);
    expect(find.textContaining('Wycieka olej'), findsOneWidget);
    expect(find.text('Kierowca: Jan'), findsWidgets);

    // Zamiast korytarzy: tylko własne pojazdy silnikowe w trasie.
    expect(find.text('WI 4022P'), findsOneWidget);
    expect(find.textContaining('Naczepa: Krone SD'), findsOneWidget);
    expect(find.text('Obcy'), findsNothing);
    expect(find.text('DAF XF'), findsNothing);

    // Kafel z licznikiem ze wskaźnika modułu, komunikat, stan pusty telematyki.
    expect(find.text('Zlecenia napraw'), findsOneWidget);
    expect(find.text('Zjedź na MOP Świebodzin'), findsOneWidget);
    expect(find.textContaining('Brak integracji telematycznej'), findsOneWidget);
    expect(summaries.last.critical, 1);
    expect(summaries.last.active, 2);
    expect(summaries.last.total, 3);

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

    // Zlecenie serwisowe nie ma kierowcy – tylko „Obsłużone”.
    expect(find.byKey(Key('ops-message-${alerts[1]['id']}')), findsNothing);
    await tester.tap(find.byKey(Key('ops-ack-${alerts[1]['id']}')));
    await tester.pumpAndSettle();
    expect(posts.values.last, {'company_id': 'c1', 'action': 'acknowledge'});

    await tester.tap(find.text('Nowa trasa'));
    await tester.tap(find.text('Zlecenia napraw'));
    await tester.tap(find.text('Otwórz wiadomości'));
    expect(opened, ['route', 'service', 'inbox']);

    await tester.pumpWidget(const SizedBox()); // zamyka strumień i timer ponowienia
  });

  testWidgets('pulpit główny: bez spraw i zestawów w trasie – czytelne stany puste', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = CoreApi(
      baseUrl: 'http://serwer.test',
      token: 't',
      client: MockClient((request) async => switch (request.url.path) {
            '/api/dashboard/overview' => json({...overview, 'kpis': <Object>[]}),
            '/api/dashboard/alerts' => json(<Object>[]),
            '/api/vehicles' => json(<Object>[]),
            '/api/me/messages' => json({'unread': 0, 'items': <Object>[]}),
            _ => json({'detail': 'brak'}, 404),
          }),
    );
    await tester.pumpWidget(localized(Scaffold(
      body: DispatcherDashboard(api: api, companyId: 'c1', userName: 'Ewa', active: false),
    )));
    await tester.pumpAndSettle();
    expect(find.text('Brak spraw – wszystko w porządku'), findsOneWidget);
    expect(find.byKey(const Key('dash-on-route-empty')), findsOneWidget);
    expect(find.text('Brak komunikatów.'), findsOneWidget);
    expect(find.textContaining('sprawności floty'), findsNothing);
  });
}
