import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../inbox_screen.dart' show driverDueText, inboxTitle, vehicleDueText;
import '../l10n.dart';

/// Ikony z danych pulpitu (nazwy w `dashboard_screens.payload`) – zawsze w wersji outlined.
IconData dashIcon(String? name) => switch (name) {
      'truck' => Icons.local_shipping_outlined,
      'schedule' => Icons.schedule_outlined,
      'fuel' => Icons.local_gas_station_outlined,
      'payments' => Icons.payments_outlined,
      'trending_up' => Icons.trending_up,
      'eco' => Icons.eco_outlined,
      'timer' => Icons.timer_outlined,
      'tire' => Icons.tire_repair_outlined,
      'ac_unit' => Icons.ac_unit_outlined,
      'alt_route' => Icons.alt_route_outlined,
      'support' => Icons.support_agent_outlined,
      'restart' => Icons.restart_alt_outlined,
      'view_in_ar' => Icons.view_in_ar_outlined,
      'badge' => Icons.badge_outlined,
      'receipt' => Icons.receipt_long_outlined,
      'route' => Icons.route_outlined,
      _ => Icons.circle_outlined,
    };

List<Map<String, dynamic>> uiMaps(dynamic list) => [
      for (final item in list is List ? list : const [])
        if (item is Map<String, dynamic>) item
    ];

String uiStr(dynamic value) => value == null ? '' : '$value';

/// Tekst z danych: `**pogrubienie**`, `!!pogrubienie w kolorze alarmu!!`.
TextSpan richText(String text, TextStyle? base, Color alarm) {
  final spans = <TextSpan>[];
  final pattern = RegExp(r'\*\*(.+?)\*\*|!!(.+?)!!');
  var start = 0;
  for (final m in pattern.allMatches(text)) {
    if (m.start > start) spans.add(TextSpan(text: text.substring(start, m.start)));
    spans.add(m.group(1) != null
        ? TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700))
        : TextSpan(text: m.group(2), style: TextStyle(fontWeight: FontWeight.w700, color: alarm)));
    start = m.end;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return TextSpan(style: base, children: spans);
}

/// Treść kart z prawdziwymi danymi tam, gdzie serwer je ma (wygląd bez zmian): wskaźnik zestawów
/// w trasie, sprawność floty, aktywne jednostki, sprawy pulpitu (`/api/dashboard/alerts`) i wiadomości.
/// Pozostałe pola zostają z `dashboard_screens` (dane pokazowe).
Map<String, dynamic> mergeLive(
  AppLocalizations l,
  Map<String, dynamic> screen, {
  Map<String, dynamic>? overview,
  List<Map<String, dynamic>> alerts = const [],
  List<Map<String, dynamic>> messages = const [],
}) {
  final out = Map<String, dynamic>.of(screen);
  Map<String, dynamic>? kpi(String key) => uiMaps(overview?['kpis']).where((k) => k['key'] == key).firstOrNull;
  if (kpi('fleet.active') case final active?) {
    final value = active['value'] as num? ?? 0;
    final total = active['total'] as num? ?? 0;
    final ratio = total == 0 ? 0.0 : (value / total).toDouble();
    final kpis = uiMaps(out['kpis']);
    final first = kpis.firstOrNull ?? {'label': l.opsKpiActive, 'icon': 'truck', 'bar_tone': 'primary'};
    out['kpis'] = [
      {
        ...first,
        'value': l.number(value),
        'unit': l.mainUnitsOf(l.number(total)),
        'left': l.mainUtilization(l.number(100 * ratio, decimals: 0)),
        'left_icon': 'trending_up',
        'left_tone': 'primary',
        'right': '',
        'bar': ratio,
      },
      ...kpis.skip(1),
    ];
    out['telemetry'] = {...(out['telemetry'] as Map<String, dynamic>? ?? const {}), 'active': value, 'total': total};
  }
  if (kpi('drivers.assigned') case final drivers?) {
    out['modules'] = [
      for (final m in uiMaps(out['modules']))
        if (m['icon'] == 'badge')
          {...m, 'chip': l.mainDriversCount(l.number(drivers['total'] as num? ?? drivers['value'] as num? ?? 0))}
        else
          m
    ];
  }
  if (kpi('fleet.health') case final health?) {
    out['fleet_ok'] = '${l.number(health['value'] as num? ?? 0, decimals: 1)}%';
  }
  if (alerts.isNotEmpty) {
    out['alerts'] = [for (final a in alerts) _liveAlert(l, a)];
    out['alerts_count'] = l.mainPriority(alerts.where((a) => a['severity'] != 'info').length);
  }
  if (messages.isNotEmpty) {
    out['messages'] = [for (final m in messages.take(3)) _liveMessage(l, m)];
  }
  return out;
}

Map<String, dynamic> _liveAlert(AppLocalizations l, Map<String, dynamic> a) {
  final data = (a['data'] as Map<String, dynamic>?) ?? const {};
  final vehicle = [a['vehicle_name'], if (a['plate'] != null) a['plate']].whereType<Object>().join(' · ');
  final (String tag, String title, String text, String icon) = switch (a['kind']) {
    'vehicle_due' => (l.mainKindVehicleDue, vehicle, vehicleDueText(l, data), 'schedule'),
    'vehicle_reported' => (l.mainKindReported, vehicle, '', 'support'),
    'vehicle_repair' => (l.mainKindRepair, vehicle, '', 'support'),
    'drivers.due' => (l.mainKindDriverDue, '${data['driver_name'] ?? ''}', driverDueText(l, data), 'badge'),
    'service.order' => (
        l.mainKindServiceOrder,
        vehicle,
        [
          '„${data['description']}”',
          switch (data['status']) {
            'accepted' => l.opsOrderAccepted('${data['mechanic_name'] ?? ''}'),
            'in_progress' => l.opsOrderInProgress,
            _ => l.opsOrderNew,
          },
        ].join(' · '),
        'support'
      ),
    _ => ('${a['kind']}', vehicle, '', 'schedule'),
  };
  return {
    'tag': tag,
    'severity': a['severity'],
    'icon': icon,
    'title': title,
    'text': text,
    'meta': [if (a['driver_name'] != null && a['kind'] != 'drivers.due') l.opsDriver('${a['driver_name']}')],
    'action': l.mainAck,
    'action_icon': 'restart',
  };
}

Map<String, dynamic> _liveMessage(AppLocalizations l, Map<String, dynamic> m) {
  final kind = '${m['kind']}';
  final data = (m['data'] as Map<String, dynamic>?) ?? const {};
  final at = DateTime.tryParse('${m['created_at']}')?.toLocal();
  final (String tag, String tone) = switch (kind) {
    'dispatch_note' => (l.mainMsgDispatch, 'info'),
    'service.order_new' || 'service.order_done' => (l.mainMsgService, 'error'),
    'vehicle_due' || 'drivers.due' => (l.mainMsgDeadline, 'error'),
    _ when kind.startsWith('admin_') => (l.mainMsgAdmin, 'tertiary'),
    _ => (l.mainMsgOther, 'info'),
  };
  return {
    'tag': tag,
    'tone': tone,
    'time': at == null ? '' : DateFormat.Hm(l.localeName).format(at),
    'title': inboxTitle(l, m),
    'text': '${data['text'] ?? data['description'] ?? ''}',
    'sender': '${m['sender_name'] ?? ''}',
  };
}

/// Pulpit główny według projektu Stitch. Dane z `/api/dashboard/screen` (odświeżane co minutę);
/// każde kliknięcie (przycisk, kafel, akcja) – [onOpen] z nazwą klikniętego elementu (ekran „W budowie”).
class MainDashboard extends StatefulWidget {
  const MainDashboard({
    super.key,
    required this.api,
    required this.companyId,
    required this.userName,
    required this.onOpen,
    this.onDrivers,
    this.onSection,
    this.onScreen,
    this.refreshEvery = const Duration(minutes: 1),
  });

  final CoreApi api;

  /// Firma użytkownika; `null` – bez firmy (stany puste).
  final String? companyId;
  final String userName;
  final ValueChanged<String> onOpen;

  /// Kafel kierowców – ekran „Kierowcy i Czas Pracy”.
  final VoidCallback? onDrivers;

  /// Przejście do ekranu aplikacji (`live`, `repairs`, `load3d`…) dla akcji alertu albo kafla modułu,
  /// który ma już swój ekran (`dashboardSection`); inne – [onOpen].
  final ValueChanged<String>? onSection;

  /// Treść kart po wczytaniu (powłoka pokazuje z niej m.in. kartę telemetrii).
  final ValueChanged<Map<String, dynamic>?>? onScreen;
  final Duration refreshEvery;

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

/// Ekran aplikacji dla ikony akcji alertu albo kafla modułu z danych pulpitu; `null` – ekranu
/// jeszcze nie ma (np. zdalny reset agregatu wymaga telematyki).
String? dashboardSection(String? icon) => switch (icon) {
      'alt_route' || 'route' || 'map' => 'live',
      'support' || 'build' || 'tire' => 'repairs',
      'view_in_ar' => 'load3d',
      'receipt' || 'inventory' => 'orders',
      'badge' || 'timer' || 'schedule' => 'drivers',
      'truck' => 'fleet',
      'payments' => 'tco',
      _ => null,
    };

class _MainDashboardState extends State<MainDashboard> {
  Map<String, dynamic>? _data;
  Map<String, dynamic>? _overview;
  List<Map<String, dynamic>> _alerts = const [];
  List<Map<String, dynamic>> _messages = const [];
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(widget.refreshEvery, (_) => _load());
  }

  @override
  void didUpdateWidget(MainDashboard old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId) _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    // Po bieżącej klatce: powłoka odświeża się z [onScreen], a nie wolno jej przebudować w trakcie budowania.
    await Future<void>.delayed(Duration.zero);
    final company = widget.companyId;
    Map<String, dynamic>? data;
    Map<String, dynamic>? overview;
    var alerts = const <Map<String, dynamic>>[];
    var messages = const <Map<String, dynamic>>[];
    Future<dynamic> get(String path) async {
      try {
        return await widget.api.get(path);
      } catch (_) {
        return null; // brak danych albo uprawnień – ta część zostaje pusta / pokazowa
      }
    }

    if (company != null) {
      final query = 'company_id=${Uri.encodeQueryComponent(company)}';
      final results = await Future.wait([
        get('/api/dashboard/screen?$query'),
        get('/api/dashboard/overview?$query'),
        get('/api/dashboard/alerts?$query'),
        get('/api/me/messages'),
      ]);
      data = results[0] is Map<String, dynamic> ? results[0] as Map<String, dynamic> : null;
      overview = results[1] is Map<String, dynamic> ? results[1] as Map<String, dynamic> : null;
      alerts = uiMaps(results[2]);
      messages = results[3] is Map ? uiMaps((results[3] as Map)['items']) : const [];
    }
    if (!mounted) return;
    setState(() {
      _data = data;
      _overview = overview;
      _alerts = alerts;
      _messages = messages;
      _loading = false;
    });
    widget.onScreen?.call(data?['screen'] == null && overview == null ? null : _screen(context.l));
  }

  Map<String, dynamic> _screen(AppLocalizations l) => mergeLive(
        l,
        (_data?['screen'] as Map<String, dynamic>?) ?? const {},
        overview: _overview,
        alerts: _alerts,
        messages: _messages,
      );

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final screen = _screen(context.l);
    final open = widget.onOpen;
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final wide = inner >= 780;
      final kpiColumns = wide ? 4 : (inner >= 520 ? 2 : 1);
      final kpiWidth = (inner - gap * (kpiColumns - 1)) / kpiColumns;
      final kpis = uiMaps(screen['kpis']);
      final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _AlertsCard(screen: screen, onOpen: open, onSection: widget.onSection),
        const SizedBox(height: gap),
        _CorridorsCard(screen: screen),
      ]);
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _ModulesCard(screen: screen, onOpen: open, onDrivers: widget.onDrivers, onSection: widget.onSection),
        const SizedBox(height: gap),
        _MessagesCard(screen: screen, onOpen: open),
      ]);
      return ListView(padding: EdgeInsets.all(pad), children: [
        _WelcomeCard(screen: screen, userName: widget.userName, onOpen: open),
        const SizedBox(height: gap),
        if (kpis.isEmpty)
          _EmptyCard(text: context.l.mainNoData)
        else
          Wrap(spacing: gap, runSpacing: gap, children: [
            for (final kpi in kpis) SizedBox(width: kpiWidth, child: _KpiCard(kpi: kpi)),
          ]),
        const SizedBox(height: gap),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 8, child: left),
            const SizedBox(width: gap),
            Expanded(flex: 4, child: right),
          ])
        else ...[
          left,
          const SizedBox(height: gap),
          right,
        ],
      ]);
    });
  }
}

// ------------------------------------------------------------------ elementy wspólne

class UiPanel extends StatelessWidget {
  const UiPanel({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: const EdgeInsets.all(20), child: child));
}

/// Pole wewnątrz karty (alert, korytarz, kafel, komunikat): jasne tło, 8 px.
class UiBox extends StatelessWidget {
  const UiBox({super.key, required this.child, this.onTap, this.padding = const EdgeInsets.all(Gap.l)});

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Material(
          color: TruckColors.of(context).surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.radius),
          child: InkWell(
            borderRadius: BorderRadius.circular(TruckTheme.radius),
            onTap: onTap,
            child: Padding(padding: padding, child: child),
          ),
        ),
      );
}

/// Prostokątny znacznik (typ alertu, kategoria komunikatu, licznik modułu).
class UiTag extends StatelessWidget {
  const UiTag(this.label, {super.key, required this.tone, this.uppercase = true});

  final String label;
  final String? tone;
  final bool uppercase;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = tagColors(context, tone);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
      child: Text(uppercase ? label.toUpperCase() : label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg, letterSpacing: 0.4)),
    );
  }
}

/// Kolory znaczników: `critical` – czerwone tło, `error` – jasnoczerwone, `tertiary`/`ok` – ciemnozielone, reszta – niebieskawe.
(Color, Color) tagColors(BuildContext context, String? tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    'critical' => (scheme.error, scheme.onError),
    'error' => (scheme.errorContainer, scheme.onErrorContainer),
    'tertiary' || 'ok' => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
    _ => (scheme.secondaryContainer, scheme.onSecondaryContainer),
  };
}

Color uiBarColor(BuildContext context, String? tone) {
  final scheme = Theme.of(context).colorScheme;
  final colors = TruckColors.of(context);
  return switch (tone) {
    'tertiary' => scheme.tertiaryContainer,
    'mint' => const Color(0xFF68DBA9),
    'neutral' => scheme.outline,
    'error' => scheme.error,
    _ => colors.inUse,
  };
}

Color uiToneColor(BuildContext context, String? tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    'primary' => scheme.primaryContainer,
    'error' => scheme.error,
    'success' => TruckColors.of(context).success,
    _ => scheme.onSurfaceVariant,
  };
}

class UiSectionHeader extends StatelessWidget {
  const UiSectionHeader({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.trailing,
    this.iconColor,
    this.iconBackground,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final Widget? trailing;
  final Color? iconColor;
  final Color? iconBackground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        width: 32,
        height: 32,
        margin: const EdgeInsets.only(top: 2),
        decoration: BoxDecoration(
          color: iconBackground ?? TruckColors.of(context).surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        ),
        child: Icon(icon, size: 18, color: iconColor ?? theme.colorScheme.primary),
      ),
      const SizedBox(width: Gap.m),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (subtitle != null)
            Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      if (trailing != null) ...[const SizedBox(width: Gap.m), trailing!],
    ]);
  }
}

class _EmptyCard extends StatelessWidget {
  const _EmptyCard({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => UiPanel(child: UiEmpty(text));
}

class UiEmpty extends StatelessWidget {
  const UiEmpty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Gap.m),
      child: Row(children: [
        Icon(Icons.inbox_outlined, size: 20, color: theme.colorScheme.outline),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline))),
      ]),
    );
  }
}

// ------------------------------------------------------------------ karty

class _WelcomeCard extends StatelessWidget {
  const _WelcomeCard({required this.screen, required this.userName, required this.onOpen});

  final Map<String, dynamic> screen;
  final String userName;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    // Imię zalogowanego użytkownika (z profilu konta); dane pulpitu – tylko gdy imienia brak.
    final first = userName.trim().split(RegExp(r'\s+')).first;
    final name = first.isNotEmpty ? first : uiStr(screen['greeting_name']);
    Widget button(String label, IconData icon, Color bg, Color fg, Key key) => Padding(
          padding: const EdgeInsets.only(bottom: Gap.s),
          child: FilledButton.icon(
            key: key,
            style: FilledButton.styleFrom(
              backgroundColor: bg,
              foregroundColor: fg,
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: 14),
              textStyle: theme.textTheme.labelLarge,
            ),
            onPressed: () => onOpen(label),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Wrap(spacing: Gap.m, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(l.mainHello(name), style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        if (uiStr(screen['shift']).isNotEmpty)
          StatusChip(label: l.mainShift(uiStr(screen['shift'])), tone: StatusTone.info, pulse: true, uppercase: false),
      ]),
      if (uiStr(screen['fleet_ok']).isNotEmpty) ...[
        const SizedBox(height: Gap.s),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
          decoration: ShapeDecoration(color: scheme.tertiaryContainer, shape: const StadiumBorder()),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.verified_outlined, size: 14, color: scheme.onTertiaryContainer),
            const SizedBox(width: 6),
            Text(l.mainFleetOk(uiStr(screen['fleet_ok'])),
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onTertiaryContainer)),
          ]),
        ),
      ],
      const SizedBox(height: Gap.s),
      Text(uiStr(screen['description']).isEmpty ? l.mainNoData : uiStr(screen['description']),
          style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
    ]);
    final buttons = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      button(l.mainReport, Icons.download_outlined, colors.surfaceLow, scheme.onSurface, const Key('main-report')),
      button(l.mainAssign, Icons.link_outlined, colors.surfaceHigh, scheme.primary, const Key('main-assign')),
      button(l.mainNewOrder, Icons.add_circle_outline, scheme.primaryContainer, scheme.onPrimaryContainer,
          const Key('main-new-order')),
    ]);
    return UiPanel(
      child: LayoutBuilder(
        builder: (context, size) => size.maxWidth >= 640
            ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: text),
                const SizedBox(width: Gap.xl),
                buttons,
              ])
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                text,
                const SizedBox(height: Gap.l),
                buttons,
              ]),
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({required this.kpi});

  final Map<String, dynamic> kpi;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final leftTone = uiToneColor(context, kpi['left_tone'] as String?);
    final leftIcon = kpi['left_icon'] as String?;
    final small = theme.textTheme.bodySmall;
    final bar = (kpi['bar'] as num?)?.toDouble();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(uiStr(kpi['label']).toUpperCase(),
                  maxLines: 2,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.6)),
            ),
            Container(
              width: 32,
              height: 32,
              decoration:
                  BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
              child: Icon(dashIcon(kpi['icon'] as String?), size: 18, color: scheme.primary),
            ),
          ]),
          const SizedBox(height: Gap.m),
          Text.rich(TextSpan(children: [
            TextSpan(
                text: uiStr(kpi['value']),
                style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurface)),
            if (uiStr(kpi['unit']).isNotEmpty)
              TextSpan(
                  text: '  ${uiStr(kpi['unit'])}', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
          ])),
          const SizedBox(height: Gap.s),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (leftIcon == 'dot')
              Padding(
                padding: const EdgeInsets.only(top: 5, right: 6),
                child:
                    Container(width: 7, height: 7, decoration: BoxDecoration(color: leftTone, shape: BoxShape.circle)),
              )
            else if (leftIcon != null)
              Padding(
                padding: const EdgeInsets.only(top: 1, right: 4),
                child: Icon(dashIcon(leftIcon), size: 14, color: leftTone),
              ),
            Flexible(
              flex: 3,
              fit: FlexFit.tight,
              child: Text(uiStr(kpi['left']),
                  style: small?.copyWith(
                      color: leftIcon == 'dot' ? scheme.onSurface : leftTone, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: Gap.s),
            Flexible(
              flex: 2,
              child: Text(uiStr(kpi['right']),
                  textAlign: TextAlign.end,
                  style: small?.copyWith(color: uiToneColor(context, kpi['right_tone'] as String?))),
            ),
          ]),
          const SizedBox(height: Gap.m),
          if (bar != null)
            TruckProgressBar(value: bar, height: 6, color: uiBarColor(context, kpi['bar_tone'] as String?)),
        ]),
      ),
    );
  }
}

class _AlertsCard extends StatelessWidget {
  const _AlertsCard({required this.screen, required this.onOpen, this.onSection});

  final Map<String, dynamic> screen;
  final ValueChanged<String> onOpen;
  final ValueChanged<String>? onSection;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final alerts = uiMaps(screen['alerts']);
    final count = uiStr(screen['alerts_count']);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.mainAlertsTitle,
          subtitle: l.mainAlertsSubtitle,
          icon: Icons.emergency_outlined,
          iconColor: scheme.error,
          iconBackground: scheme.errorContainer,
          trailing: count.isEmpty ? null : UiTag(count, tone: 'error', uppercase: false),
        ),
        const SizedBox(height: 20),
        if (alerts.isEmpty) UiEmpty(l.mainNoAlerts),
        for (final alert in alerts) _AlertTile(alert: alert, onOpen: onOpen, onSection: onSection),
      ]),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert, required this.onOpen, this.onSection});

  final Map<String, dynamic> alert;
  final ValueChanged<String> onOpen;
  final ValueChanged<String>? onSection;

  void _act(String action) {
    final target = dashboardSection(alert['action_icon'] as String?);
    if (target != null && onSection != null) return onSection!(target);
    onOpen(action);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final critical = alert['severity'] == 'critical';
    final meta = [for (final m in alert['meta'] as List? ?? const []) '$m'];
    final action = uiStr(alert['action']);
    final button = action.isEmpty
        ? null
        : critical
            ? FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
                onPressed: () => _act(action),
                icon: Icon(dashIcon(alert['action_icon'] as String?), size: 18),
                label: Text(action),
              )
            : OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  backgroundColor: colors.card,
                  foregroundColor: scheme.onSurface,
                  side: BorderSide(color: colors.surfaceHigh),
                ),
                onPressed: () => _act(action),
                icon: Icon(dashIcon(alert['action_icon'] as String?), size: 18),
                label: Text(action),
              );
    final body = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      UiTag(uiStr(alert['tag']), tone: critical ? 'critical' : 'info'),
      const SizedBox(height: Gap.s),
      Text(uiStr(alert['title']), style: theme.textTheme.titleSmall?.copyWith(fontSize: 15)),
      if (uiStr(alert['location']).isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text('•  ${uiStr(alert['location'])}',
              style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      const SizedBox(height: Gap.s),
      Text.rich(richText(uiStr(alert['text']), theme.textTheme.bodyMedium, scheme.error)),
      if (meta.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(meta.join('   •   '), style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
        ),
    ]);
    return UiBox(
      child: LayoutBuilder(builder: (context, size) {
        final side = size.maxWidth >= 520;
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: critical ? scheme.errorContainer : colors.card,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Icon(dashIcon(alert['icon'] as String?), size: 22, color: critical ? scheme.error : scheme.primary),
          ),
          const SizedBox(width: Gap.l),
          Expanded(
            child: side || button == null
                ? body
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    body,
                    const SizedBox(height: Gap.m),
                    button,
                  ]),
          ),
          if (side && button != null) ...[
            const SizedBox(width: Gap.l),
            Padding(padding: const EdgeInsets.only(top: 64), child: button),
          ],
        ]);
      }),
    );
  }
}

class _CorridorsCard extends StatelessWidget {
  const _CorridorsCard({required this.screen});

  final Map<String, dynamic> screen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final corridors = uiMaps(screen['corridors']);
    final updated = uiStr(screen['corridors_updated']);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.mainCorridorsTitle,
          subtitle: l.mainCorridorsSubtitle,
          icon: Icons.route_outlined,
          trailing: updated.isEmpty
              ? null
              : Text(l.mainUpdated(updated),
                  style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ),
        const SizedBox(height: 20),
        if (corridors.isEmpty) UiEmpty(l.mainNoCorridors),
        for (final c in corridors) _corridor(context, c),
      ]),
    );
  }

  Widget _corridor(BuildContext context, Map<String, dynamic> c) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final ok = c['status_tone'] == 'ok';
    final small = theme.textTheme.bodySmall;
    final rightAlarm = uiStr(c['right']).startsWith('!!');
    return UiBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
            constraints: const BoxConstraints(minWidth: 32),
            padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.xs),
            decoration:
                BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Text(uiStr(c['road']),
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(width: Gap.m),
          Expanded(child: Text(uiStr(c['name']), style: theme.textTheme.titleSmall)),
          const SizedBox(width: Gap.s),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
            decoration: BoxDecoration(
              color: ok ? scheme.tertiaryContainer : colors.surfaceHigh,
              borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 6,
                height: 6,
                decoration:
                    BoxDecoration(color: ok ? scheme.onTertiaryContainer : scheme.error, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(uiStr(c['status']),
                  style:
                      theme.textTheme.labelSmall?.copyWith(color: ok ? scheme.onTertiaryContainer : scheme.onSurface)),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.m),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text.rich(richText(uiStr(c['left']), small, scheme.error))),
          const SizedBox(width: Gap.m),
          Flexible(
            child: Text.rich(richText(uiStr(c['right']), small, scheme.error),
                textAlign: rightAlarm ? TextAlign.end : TextAlign.end),
          ),
        ]),
        if (uiStr(c['note']).isNotEmpty) ...[
          const SizedBox(height: Gap.s),
          Text(uiStr(c['note']), style: small?.copyWith(color: scheme.onSurfaceVariant)),
        ],
        if ((c['bar'] as num?) != null) ...[
          const SizedBox(height: Gap.s),
          TruckProgressBar(
              value: (c['bar'] as num).toDouble(), height: 6, color: uiBarColor(context, c['bar_tone'] as String?)),
        ],
      ]),
    );
  }
}

class _ModulesCard extends StatelessWidget {
  const _ModulesCard({required this.screen, required this.onOpen, this.onDrivers, this.onSection});

  final Map<String, dynamic> screen;
  final ValueChanged<String> onOpen;
  final VoidCallback? onDrivers;
  final ValueChanged<String>? onSection;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final modules = uiMaps(screen['modules']);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
              child:
                  Text(l.mainModulesTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          Icon(Icons.apps_outlined, size: 20, color: scheme.outline),
        ]),
        const SizedBox(height: Gap.l),
        if (modules.isEmpty) UiEmpty(l.mainNoData),
        for (final m in modules) _tile(context, m),
      ]),
    );
  }

  Widget _tile(BuildContext context, Map<String, dynamic> m) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stats = [for (final s in m['stats'] as List? ?? const []) '$s'];
    final dots = [for (final s in m['stat_dots'] as List? ?? const []) '$s'];
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return UiBox(
      padding: const EdgeInsets.all(Gap.m),
      onTap: m['icon'] == 'badge' && onDrivers != null
          ? onDrivers
          : () {
              final target = dashboardSection(m['icon'] as String?);
              target != null && onSection != null ? onSection!(target) : onOpen(uiStr(m['title']));
            },
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(dashIcon(m['icon'] as String?), size: 20, color: scheme.primary),
          ),
          const SizedBox(width: Gap.m),
          Expanded(flex: 3, child: Text(uiStr(m['title']), style: theme.textTheme.titleSmall)),
          if (uiStr(m['chip']).isNotEmpty) ...[
            const SizedBox(width: Gap.s),
            Flexible(
                flex: 2,
                child: Align(
                    alignment: Alignment.topRight,
                    child: UiTag(uiStr(m['chip']),
                        tone: m['chip_tone'] as String?, uppercase: m['chip_tone'] == 'tertiary'))),
          ],
        ]),
        if (uiStr(m['text']).isNotEmpty) ...[
          const SizedBox(height: Gap.s),
          Text(uiStr(m['text']), style: small),
        ],
        const SizedBox(height: Gap.m),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Wrap(spacing: Gap.l, runSpacing: Gap.xs, children: [
              for (final (i, s) in stats.indexed)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  if (i < dots.length) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                          color: dots[i] == 'primary' ? scheme.primary : scheme.outline, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: Gap.xs),
                  ],
                  Flexible(child: Text(s, style: small?.copyWith(color: scheme.outline))),
                ]),
            ]),
          ),
          if (uiStr(m['link']).isNotEmpty)
            Text('${uiStr(m['link'])} →', style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
        ]),
      ]),
    );
  }
}

class _MessagesCard extends StatelessWidget {
  const _MessagesCard({required this.screen, required this.onOpen});

  final Map<String, dynamic> screen;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final messages = uiMaps(screen['messages']);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: scheme.tertiaryContainer, shape: BoxShape.circle)),
          const SizedBox(width: Gap.s),
          Expanded(
              child:
                  Text(l.mainMessagesTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          Icon(Icons.campaign_outlined, size: 20, color: scheme.outline),
        ]),
        const SizedBox(height: Gap.l),
        if (messages.isEmpty) UiEmpty(l.mainNoMessages),
        for (final m in messages)
          UiBox(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                UiTag(uiStr(m['tag']), tone: m['tone'] as String?),
                const Spacer(),
                Text(uiStr(m['time']), style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
              ]),
              const SizedBox(height: Gap.s),
              Text(uiStr(m['title']), style: theme.textTheme.titleSmall),
              if (uiStr(m['text']).isNotEmpty) ...[
                const SizedBox(height: Gap.xs),
                Text(uiStr(m['text']), style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
              if (uiStr(m['sender']).isNotEmpty) ...[
                const SizedBox(height: Gap.s),
                Text(l.mainSender(uiStr(m['sender'])),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              ],
            ]),
          ),
        const SizedBox(height: Gap.xs),
        FilledButton.icon(
          key: const Key('main-channel'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.surfaceLow,
            foregroundColor: scheme.onSurface,
            padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.l),
          ),
          onPressed: () => onOpen(l.mainChannel),
          icon: const Icon(Icons.forum_outlined, size: 18),
          label: Text(l.mainChannel, textAlign: TextAlign.center),
        ),
      ]),
    );
  }
}

/// Karta telemetrii na dole menu (z treści pulpitu); bez danych – stan pusty.
class TelemetryCard extends StatelessWidget {
  const TelemetryCard({super.key, required this.screen});

  final Map<String, dynamic>? screen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final t = (screen?['telemetry'] as Map<String, dynamic>?) ?? const {};
    final active = t['active'] as num?;
    final total = t['total'] as num?;
    return Container(
      key: const Key('shell-telemetry'),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 8,
              height: 8,
              decoration:
                  BoxDecoration(color: t.isEmpty ? scheme.outline : scheme.tertiaryContainer, shape: BoxShape.circle)),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text((t.isEmpty ? l.mainTelemetry : uiStr(t['label'])).toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurface)),
          ),
          Text(t.isEmpty ? '–' : uiStr(t['percent']),
              style: theme.textTheme.labelLarge?.copyWith(color: scheme.tertiaryContainer)),
        ]),
        const SizedBox(height: Gap.s),
        Row(children: [
          Expanded(child: Text(l.mainActiveUnits, style: theme.textTheme.bodySmall)),
          Text(active == null || total == null ? '–' : '$active / $total', style: theme.textTheme.labelLarge),
        ]),
        const SizedBox(height: Gap.s),
        TruckProgressBar(
          value: active == null || total == null || total == 0 ? 0 : active / total,
          height: 6,
          color: scheme.tertiaryContainer,
        ),
        const SizedBox(height: Gap.s),
        Row(children: [
          Expanded(
            child: Text(l.mainGps(t.isEmpty ? l.mainTelemetryNone : uiStr(t['gps'])),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
          ),
          Icon(t.isEmpty ? Icons.sensors_off_outlined : Icons.sensors_outlined, size: 16, color: scheme.outline),
        ]),
      ]),
    );
  }
}

/// Znacznik „W budowie” w miejscu danych, których jeszcze nie ma (telematyka, rampy, opony…);
/// kliknięcie – ekran „W budowie” z nazwą elementu.
class WipTag extends StatelessWidget {
  const WipTag({super.key, required this.what, required this.onOpen});

  final String what;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
      onTap: () => onOpen(what),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration:
            BoxDecoration(color: colors.surfaceHigh, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.construction_outlined, size: 12, color: theme.colorScheme.outline),
          const SizedBox(width: 4),
          Flexible(
            child: Text(context.l.underConstruction.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline, fontSize: 10)),
          ),
        ]),
      ),
    );
  }
}
