import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../inbox_screen.dart' show driverDueText, inboxTitle, vehicleDueText;
import '../l10n.dart';

/// Stan pulpitu dla powłoki: połączenie na żywo, zestawy w trasie i liczba pilnych spraw.
class DashSummary {
  const DashSummary({required this.live, this.active, this.total, this.critical = 0, this.telematics = false});

  final bool live;
  final int? active;
  final int? total;
  final int critical;
  final bool telematics;

  @override
  bool operator ==(Object other) =>
      other is DashSummary &&
      other.live == live &&
      other.active == active &&
      other.total == total &&
      other.critical == critical &&
      other.telematics == telematics;

  @override
  int get hashCode => Object.hash(live, active, total, critical, telematics);
}

/// Przycisk karty powitania.
class DashAction {
  const DashAction(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

/// Kafel „Szybki dostęp”: moduł albo ekran rdzenia; [kpiKey] – licznik ze wskaźników pulpitu.
class DashTile {
  const DashTile(this.title, this.icon, this.onTap, {this.description, this.kpiKey});

  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final String? description;
  final String? kpiKey;
}

List<Map<String, dynamic>> maps(dynamic list) => list is List
    ? [
        for (final item in list)
          if (item is Map<String, dynamic>) item
      ]
    : const [];

Map<String, dynamic>? kpiOf(Map<String, dynamic> overview, String key) =>
    maps(overview['kpis']).where((k) => k['key'] == key).firstOrNull;

/// Cztery główne wskaźniki: najpierw stałe miejsca z wzoru, brakujące uzupełniają kolejne znane.
List<Map<String, dynamic>> mainKpis(List<Map<String, dynamic>> kpis) {
  const preferred = ['fleet.active', 'fleet.health', 'trips.km_today', 'costs.today'];
  final known = kpis.where((k) => _kpiKeys.contains(k['key'])).toList();
  final picked = <Map<String, dynamic>>[
    for (final key in preferred) ...known.where((k) => k['key'] == key).take(1),
  ];
  for (final k in known) {
    if (picked.length >= 4) break;
    if (!picked.contains(k)) picked.add(k);
  }
  return picked.take(4).toList();
}

const _kpiKeys = {
  'fleet.active',
  'fleet.available',
  'fleet.service',
  'fleet.health',
  'fleet.deadlines',
  'trips.today',
  'trips.km_today',
  'costs.today',
  'trips.plan_deviation',
  'inbox.unread',
  'drivers.assigned',
  'drivers.deadlines',
  'service.open',
  'documents.today',
};

/// Etykieta, ikona, opis pod liczbą i wypełnienie paska (0–1, `null` – bez paska); nieznany klucz – `null`.
({String label, IconData icon, String? note, double? bar})? kpiInfo(AppLocalizations l, Map<String, dynamic> kpi) {
  final key = '${kpi['key']}';
  if (!_kpiKeys.contains(key)) return null;
  final value = kpi['value'] as num? ?? 0;
  final total = kpi['total'] as num?;
  final ratio = total == null || total == 0 ? null : (value / total).toDouble();
  String? of() => total == null ? null : l.opsOf(l.number(total));
  return switch (key) {
    'fleet.active' => (
        label: l.opsKpiActive,
        icon: Icons.local_shipping_outlined,
        note: ratio == null ? of() : l.opsUtilization(l.number(100 * ratio, decimals: 0)),
        bar: ratio
      ),
    'fleet.available' => (label: l.opsKpiAvailable, icon: Icons.check_circle_outline, note: null, bar: ratio),
    'fleet.service' => (label: l.opsKpiService, icon: Icons.build_outlined, note: null, bar: null),
    'fleet.health' => (
        label: l.opsKpiHealth,
        icon: Icons.health_and_safety_outlined,
        note: l.opsHealthHint,
        bar: value / 100
      ),
    'fleet.deadlines' => (
        label: l.opsKpiDeadlines,
        icon: Icons.event_note_outlined,
        note: l.opsDeadlinesHint,
        bar: null
      ),
    'trips.today' => (label: l.opsKpiTrips, icon: Icons.route_outlined, note: null, bar: null),
    'trips.km_today' => (label: l.opsKpiKm, icon: Icons.speed_outlined, note: null, bar: null),
    'costs.today' => (label: l.opsKpiCosts, icon: Icons.payments_outlined, note: null, bar: null),
    'trips.plan_deviation' => (
        label: l.opsKpiPlan,
        icon: Icons.compare_arrows_outlined,
        note: l.opsPlanHint,
        bar: null
      ),
    'inbox.unread' => (label: l.opsKpiUnread, icon: Icons.mail_outline, note: null, bar: null),
    'drivers.assigned' => (label: l.opsKpiDrivers, icon: Icons.badge_outlined, note: of(), bar: ratio),
    'drivers.deadlines' => (label: l.opsKpiDriverDeadlines, icon: Icons.event_busy_outlined, note: null, bar: null),
    'service.open' => (label: l.opsKpiServiceOpen, icon: Icons.car_repair_outlined, note: null, bar: null),
    _ => (label: l.opsKpiDocuments, icon: Icons.description_outlined, note: null, bar: null),
  };
}

/// Liczba wskaźnika bez jednostki, w formacie języka.
String kpiValue(AppLocalizations l, Map<String, dynamic> kpi) {
  final value = kpi['value'] as num? ?? 0;
  final unit = '${kpi['unit'] ?? ''}';
  if (kpi['key'] == 'trips.plan_deviation' && value > 0) return '+${l.number(value, decimals: 1)}';
  return l.number(value, decimals: unit == 'km' || unit.isEmpty ? 0 : (unit == '%' ? 1 : 2));
}

Key kpiKey(String prefix, Map<String, dynamic> kpi) {
  final unit = '${kpi['unit'] ?? ''}';
  return Key('$prefix-${kpi['key']}${unit.length == 3 ? '-$unit' : ''}');
}

Color _toneFill(BuildContext context, dynamic tone) {
  final scheme = Theme.of(context).colorScheme;
  return switch (tone) {
    'ok' => scheme.tertiaryContainer,
    'warning' => TruckColors.of(context).amber,
    'error' => scheme.error,
    _ => scheme.primaryContainer,
  };
}

/// Biała karta pulpitu (8 px, delikatny cień, padding 20 px).
class DashCard extends StatelessWidget {
  const DashCard({super.key, required this.child, this.padding = const EdgeInsets.all(20)});

  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(child: Padding(padding: padding, child: child));
}

/// Nagłówek sekcji: ikona w kwadracie, tytuł, podtytuł i element po prawej.
class DashHeader extends StatelessWidget {
  const DashHeader({
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
      IconSquare(icon: icon, size: 32, color: iconColor, background: iconBackground),
      const SizedBox(width: Gap.m),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (subtitle != null)
            Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ]),
      ),
      if (trailing != null) ...[const SizedBox(width: Gap.s), trailing!],
    ]);
  }
}

/// Mały prostokątny znacznik (typ sprawy, licznik, kategoria wiadomości).
class DashTag extends StatelessWidget {
  const DashTag(this.label, {super.key, required this.background, required this.color});

  final String label;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 2),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
        child: Text(label.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, letterSpacing: 0.5)),
      );
}

class WelcomeCard extends StatelessWidget {
  const WelcomeCard({
    super.key,
    required this.overview,
    required this.userName,
    required this.live,
    required this.actions,
    required this.onRefresh,
  });

  final Map<String, dynamic> overview;
  final String userName;
  final bool live;
  final List<DashAction> actions;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final generated = DateTime.tryParse('${overview['generated_at']}')?.toLocal() ?? DateTime.now();
    final bases = [for (final b in overview['bases'] as List? ?? const []) '$b'];
    final name = userName.trim().split(RegExp(r'\s+')).first;
    final health = kpiOf(overview, 'fleet.health');
    final description = [
      l.opsHeader('${overview['company_name']}', DateFormat.yMMMMEEEEd(l.localeName).format(generated)),
      if (bases.isNotEmpty) l.opsBases(bases.join(', ')),
    ].join(' · ');
    final buttons = [
      for (final (i, a) in actions.indexed)
        if (i == actions.length - 1)
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
            onPressed: a.onTap,
            icon: Icon(a.icon, size: 18),
            label: Text(a.label),
          )
        else
          FilledButton.tonalIcon(
            style: FilledButton.styleFrom(
              backgroundColor: i == 0 ? colors.surfaceLow : colors.surfaceHigh,
              foregroundColor: i == 0 ? scheme.onSurface : scheme.primary,
            ),
            onPressed: a.onTap,
            icon: Icon(a.icon, size: 18),
            label: Text(a.label),
          ),
    ];
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Wrap(spacing: Gap.m, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(generated.hour >= 18 ? l.dashHelloEvening(name) : l.dashHello(name),
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        StatusChip(
          key: const Key('ops-live'),
          label: live ? l.dashLiveAt(DateFormat.Hm(l.localeName).format(generated)) : l.opsOffline,
          tone: live ? StatusTone.info : StatusTone.neutral,
          pulse: live,
          uppercase: false,
        ),
        if (health != null)
          StatusChip(
            label: l.dashFleetHealth(l.number(health['value'] as num? ?? 0, decimals: 1)),
            tone: StatusTone.ok,
            icon: Icons.verified_outlined,
            uppercase: false,
          ),
      ]),
      const SizedBox(height: Gap.s),
      Text(description, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
    ]);
    final side = Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
      IconButton(
        tooltip: l.opsRefresh,
        onPressed: onRefresh,
        icon: Icon(Icons.refresh, size: 20, color: scheme.onSurfaceVariant),
      ),
      ...buttons,
    ]);
    return DashCard(
      child: LayoutBuilder(
        builder: (context, size) => size.maxWidth >= 960
            ? Row(children: [Expanded(child: text), const SizedBox(width: Gap.xl), side])
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start, children: [text, const SizedBox(height: Gap.l), side]),
      ),
    );
  }
}

/// Karta wskaźnika jak we wzorze: etykieta i ikona, duża liczba z jednostką, opis, pasek 6 px.
class DashKpiCard extends StatelessWidget {
  const DashKpiCard({super.key, required this.kpi});

  final Map<String, dynamic> kpi;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final info = kpiInfo(l, kpi)!;
    final unit = '${kpi['unit'] ?? ''}';
    final total = kpi['total'] as num?;
    final unitText = [if (total != null) '/ ${l.number(total)}', if (unit.isNotEmpty) unit].join(' ');
    return Card(
      key: kpiKey('ops-kpi', kpi),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Text(info.label.toUpperCase(),
                  maxLines: 2,
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.6)),
            ),
            IconSquare(icon: info.icon, size: 32, background: colors.surfaceLow),
          ]),
          const SizedBox(height: Gap.s),
          Text.rich(
            TextSpan(children: [
              TextSpan(
                  text: kpiValue(l, kpi),
                  style:
                      theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface)),
              if (unitText.isNotEmpty)
                TextSpan(text: '  $unitText', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
            ]),
          ),
          SizedBox(
            height: 36,
            child: info.note == null
                ? null
                : Align(
                    alignment: Alignment.centerLeft,
                    child: Text(info.note!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ),
          ),
          SizedBox(
            height: Gap.l + 6,
            child: Align(
              alignment: Alignment.topCenter,
              child: info.bar == null
                  ? null
                  : TruckProgressBar(value: info.bar!, height: 6, color: _toneFill(context, kpi['tone'])),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Pozostałe wskaźniki (z modułów) w jednym wierszu – bez osobnych kart.
class MoreKpis extends StatelessWidget {
  const MoreKpis({super.key, required this.kpis});

  final List<Map<String, dynamic>> kpis;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return DashCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: Gap.m),
      child: Wrap(spacing: Gap.xl, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(l.dashMoreKpis.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline, letterSpacing: 0.6)),
        for (final kpi in kpis)
          Row(key: kpiKey('ops-kpi', kpi), mainAxisSize: MainAxisSize.min, children: [
            Icon(kpiInfo(l, kpi)!.icon, size: 18, color: _toneFill(context, kpi['tone'])),
            const SizedBox(width: Gap.xs),
            Text('${kpiInfo(l, kpi)!.label}: ', style: theme.textTheme.bodySmall),
            Text([kpiValue(l, kpi), if ('${kpi['unit'] ?? ''}'.isNotEmpty) kpi['unit']].join(' '),
                style: theme.textTheme.labelLarge),
          ]),
      ]),
    );
  }
}

/// Rodzaj sprawy, tytuł (pojazd / kierowca), opis i ikona – teksty z .arb.
({String kind, String title, String body, IconData icon}) alertParts(AppLocalizations l, Map<String, dynamic> alert) {
  final data = (alert['data'] as Map<String, dynamic>?) ?? const {};
  final vehicle = [alert['vehicle_name'], if (alert['plate'] != null) alert['plate']].whereType<Object>().join(' · ');
  return switch (alert['kind']) {
    'vehicle_due' => (
        kind: l.dashKindVehicleDue,
        title: vehicle,
        body: vehicleDueText(l, data),
        icon: Icons.event_note_outlined
      ),
    'vehicle_reported' => (kind: l.dashKindReported, title: vehicle, body: '', icon: Icons.report_problem_outlined),
    'vehicle_repair' => (kind: l.dashKindRepair, title: vehicle, body: '', icon: Icons.build_outlined),
    'drivers.due' => (
        kind: l.dashKindDriverDue,
        title: '${data['driver_name']}',
        body: driverDueText(l, data),
        icon: Icons.badge_outlined
      ),
    'service.order' => (
        kind: l.dashKindServiceOrder,
        title: vehicle,
        body: [
          '„${data['description']}”',
          switch (data['status']) {
            'accepted' => l.opsOrderAccepted('${data['mechanic_name'] ?? ''}'),
            'in_progress' => l.opsOrderInProgress,
            _ => l.opsOrderNew,
          },
          if (data['urgency'] == 'stopped') l.opsOrderStopped,
        ].join(' · '),
        icon: Icons.car_repair_outlined
      ),
    _ => (kind: '${alert['kind']}', title: vehicle, body: '', icon: Icons.info_outline),
  };
}

class AlertsCard extends StatelessWidget {
  const AlertsCard({
    super.key,
    required this.alerts,
    required this.handled,
    required this.busy,
    required this.onToggleHandled,
    required this.onAck,
    required this.onMessage,
    required this.onReopen,
  });

  final List<Map<String, dynamic>> alerts;
  final List<Map<String, dynamic>>? handled;
  final Set<String> busy;
  final VoidCallback onToggleHandled;
  final ValueChanged<Map<String, dynamic>> onAck;
  final ValueChanged<Map<String, dynamic>> onMessage;
  final ValueChanged<Map<String, dynamic>> onReopen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final priority = alerts.where((a) => a['severity'] != 'info').length;
    return DashCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DashHeader(
          title: l.dashAlertsTitle,
          subtitle: l.dashAlertsSubtitle,
          icon: Icons.notification_important_outlined,
          iconColor: scheme.error,
          iconBackground: scheme.errorContainer,
          trailing: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            if (priority > 0)
              DashTag(l.dashPriority(priority), background: scheme.errorContainer, color: scheme.onErrorContainer),
            TextButton(
              key: const Key('ops-show-handled'),
              onPressed: onToggleHandled,
              child: Text(handled == null ? l.opsShowHandled : l.dashHideHandled),
            ),
          ]),
        ),
        const SizedBox(height: Gap.l),
        if (alerts.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: Gap.xl),
            child: Center(child: StatusChip(label: l.opsAlertsEmpty, tone: StatusTone.ok, uppercase: false)),
          ),
        for (final alert in alerts)
          AlertTile(
            alert: alert,
            busy: busy.contains(alert['id']),
            onAck: () => onAck(alert),
            onMessage: () => onMessage(alert),
          ),
        if (handled case final done? when done.isNotEmpty) ...[
          const Divider(height: Gap.xl),
          for (final alert in done) AlertTile(alert: alert, busy: false, onReopen: () => onReopen(alert)),
        ],
      ]),
    );
  }
}

class AlertTile extends StatelessWidget {
  const AlertTile({super.key, required this.alert, required this.busy, this.onAck, this.onMessage, this.onReopen});

  final Map<String, dynamic> alert;
  final bool busy;
  final VoidCallback? onAck;
  final VoidCallback? onMessage;
  final VoidCallback? onReopen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final severity = alert['severity'];
    // Czerwień i bursztyn tylko dla spraw pilnych / ostrzeżeń.
    final (Color fg, Color iconBg, Color tagBg, Color tagFg) = switch (severity) {
      'critical' => (scheme.error, scheme.errorContainer, scheme.error, scheme.onError),
      'warning' => (
          colors.warning,
          colors.amber.withOpacity(0.14),
          colors.amber.withOpacity(0.18),
          colors.warning,
        ),
      _ => (scheme.primary, colors.surfaceHigh, scheme.secondaryContainer, scheme.onSecondaryContainer),
    };
    final parts = alertParts(l, alert);
    final actions = [for (final a in alert['actions'] as List? ?? const []) '$a'];
    final handled = alert['handled'] as Map<String, dynamic>?;
    final meta = [
      if (alert['driver_name'] != null && alert['kind'] != 'drivers.due') l.opsDriver('${alert['driver_name']}'),
      if (handled != null)
        l.opsHandledBy('${handled['by_name']}', l.when(DateTime.parse('${handled['at']}').toLocal())),
    ];
    final buttons = <Widget>[
      if (handled == null && actions.contains('message_driver') && onMessage != null)
        FilledButton.icon(
          key: Key('ops-message-${alert['id']}'),
          style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
          onPressed: busy ? null : onMessage,
          icon: const Icon(Icons.send_outlined, size: 18),
          label: Text(l.opsMessage),
        ),
      if (handled == null && actions.contains('acknowledge') && onAck != null)
        OutlinedButton.icon(
          key: Key('ops-ack-${alert['id']}'),
          style: OutlinedButton.styleFrom(backgroundColor: colors.card, side: BorderSide(color: colors.surfaceHigh)),
          onPressed: busy ? null : onAck,
          icon: const Icon(Icons.done, size: 18),
          label: Text(l.opsAck),
        ),
      if (handled != null && onReopen != null) TextButton(onPressed: onReopen, child: Text(l.opsReopen)),
    ];
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      DashTag(parts.kind, background: tagBg, color: tagFg),
      const SizedBox(height: Gap.s),
      if (parts.title.isNotEmpty) Text(parts.title, style: theme.textTheme.titleSmall),
      if (parts.body.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Text(parts.body, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
        ),
      if (meta.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: Gap.s),
          child: Text(meta.join('  •  '), style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
        ),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.m),
      child: Container(
        key: Key('ops-alert-${alert['id']}'),
        padding: const EdgeInsets.all(Gap.l),
        decoration: BoxDecoration(
          color: handled != null ? colors.card : colors.surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.radius),
          border: handled != null ? Border.all(color: colors.surfaceHigh) : null,
        ),
        child: LayoutBuilder(builder: (context, size) {
          final side = size.maxWidth >= 560;
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            IconSquare(icon: parts.icon, color: fg, background: iconBg),
            const SizedBox(width: Gap.l),
            Expanded(
              child: side || buttons.isEmpty
                  ? text
                  : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      text,
                      const SizedBox(height: Gap.m),
                      Wrap(spacing: Gap.s, runSpacing: Gap.s, children: buttons),
                    ]),
            ),
            if (side && buttons.isNotEmpty) ...[
              const SizedBox(width: Gap.l),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                for (final (i, b) in buttons.indexed) ...[if (i > 0) const SizedBox(height: Gap.s), b],
              ]),
            ],
          ]);
        }),
      ),
    );
  }
}

/// Zamiast korytarzy (brak źródła danych o ruchu): zestawy z aktywną nawigacją TruckMaps.
class OnRouteCard extends StatelessWidget {
  const OnRouteCard({super.key, required this.vehicles});

  final List<Map<String, dynamic>> vehicles;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return DashCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        DashHeader(
          title: l.dashOnRouteTitle,
          subtitle: l.dashOnRouteSubtitle,
          icon: Icons.alt_route_outlined,
          trailing: vehicles.isEmpty
              ? null
              : DashTag(l.number(vehicles.length), background: colors.surfaceHigh, color: scheme.primary),
        ),
        const SizedBox(height: Gap.l),
        if (vehicles.isEmpty)
          Container(
            key: const Key('dash-on-route-empty'),
            padding: const EdgeInsets.all(Gap.l),
            decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
            child: Row(children: [
              Icon(Icons.local_parking_outlined, color: scheme.outline),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(l.dashOnRouteEmpty, style: theme.textTheme.bodyMedium)),
            ]),
          ),
        for (final v in vehicles)
          Container(
            margin: const EdgeInsets.only(bottom: Gap.m),
            padding: const EdgeInsets.all(Gap.l),
            decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
            child: Row(children: [
              if (v['plate'] != null) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.xs),
                  decoration:
                      BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
                  child: Text('${v['plate']}', style: theme.textTheme.labelLarge?.copyWith(color: scheme.onPrimary)),
                ),
                const SizedBox(width: Gap.m),
              ],
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${v['name']}', style: theme.textTheme.titleSmall),
                  Text(
                    [
                      if (v['driver_name'] != null) l.opsDriver('${v['driver_name']}'),
                      if (v['trailer_name'] != null) l.dashTrailer('${v['trailer_name']}'),
                    ].join('  •  '),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ]),
              ),
              StatusChip(label: l.opsKpiActive, tone: StatusTone.ok),
            ]),
          ),
        const SizedBox(height: Gap.s),
        Text(l.dashCorridorsHint, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
      ]),
    );
  }
}

class QuickAccessCard extends StatelessWidget {
  const QuickAccessCard({super.key, required this.tiles, required this.kpis});

  final List<DashTile> tiles;
  final List<Map<String, dynamic>> kpis;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return DashCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(l.dashQuickTitle, style: theme.textTheme.titleMedium)),
          Icon(Icons.apps_outlined, color: scheme.outline, size: 20),
        ]),
        const SizedBox(height: Gap.l),
        for (final tile in tiles)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.m),
            child: Material(
              color: colors.surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
              child: InkWell(
                borderRadius: BorderRadius.circular(TruckTheme.radius),
                onTap: tile.onTap,
                child: Padding(
                  padding: const EdgeInsets.all(Gap.l),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(tile.icon, color: scheme.primary, size: 22),
                      const SizedBox(width: Gap.m),
                      Expanded(child: Text(tile.title, style: theme.textTheme.titleSmall)),
                      if (kpis.where((k) => k['key'] == tile.kpiKey).firstOrNull case final kpi?)
                        DashTag(kpiValue(l, kpi), background: colors.surfaceHigh, color: scheme.primary),
                    ]),
                    if (tile.description != null)
                      Padding(
                        padding: const EdgeInsets.only(top: Gap.xs, left: 34),
                        child: Text(tile.description!,
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                      ),
                    Align(
                      alignment: Alignment.centerRight,
                      child:
                          Text('${l.dashOpen} →', style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class MessagesCard extends StatelessWidget {
  const MessagesCard({super.key, required this.messages, this.onOpen});

  final List<Map<String, dynamic>> messages;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return DashCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 8, height: 8, decoration: BoxDecoration(color: scheme.tertiaryContainer, shape: BoxShape.circle)),
          const SizedBox(width: Gap.s),
          Expanded(child: Text(l.dashFleetMessages, style: theme.textTheme.titleMedium)),
          Icon(Icons.campaign_outlined, color: scheme.outline, size: 20),
        ]),
        const SizedBox(height: Gap.l),
        if (messages.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.m),
            child: Text(l.dashMessagesEmpty, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
          ),
        for (final m in messages) _message(context, m),
        if (onOpen != null)
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(backgroundColor: colors.surfaceLow, side: BorderSide.none),
            onPressed: onOpen,
            icon: const Icon(Icons.forum_outlined, size: 18),
            label: Text(l.dashMessagesOpen),
          ),
      ]),
    );
  }

  Widget _message(BuildContext context, Map<String, dynamic> m) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final data = (m['data'] as Map<String, dynamic>?) ?? const {};
    final kind = '${m['kind']}';
    final category = switch (kind) {
      'dispatch_note' => l.dashMsgDispatch,
      'service.order_new' || 'service.order_done' => l.dashMsgService,
      'vehicle_due' || 'drivers.due' => l.dashMsgDeadline,
      _ when kind.startsWith('admin_') => l.dashMsgAdmin,
      _ => l.dashMsgOther,
    };
    final body = '${data['text'] ?? data['description'] ?? ''}';
    final at = DateTime.tryParse('${m['created_at']}')?.toLocal();
    final unread = m['read_at'] == null;
    return Container(
      margin: const EdgeInsets.only(bottom: Gap.m),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          DashTag(category,
              background: unread ? scheme.secondaryContainer : colors.surfaceHigh,
              color: unread ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
          const Spacer(),
          if (at != null) Text(l.when(at), style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
        ]),
        const SizedBox(height: Gap.s),
        Text(inboxTitle(l, m), style: theme.textTheme.titleSmall),
        if (body.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.xs),
            child: Text(body,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

/// Stan pusty telematyki: czego pulpit jeszcze nie pokazuje i dlaczego.
class TelematicsCard extends StatelessWidget {
  const TelematicsCard({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return DashCard(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.sensors_off_outlined, color: theme.colorScheme.outline, size: 20),
          const SizedBox(width: Gap.s),
          Text(l.opsTelematics, style: theme.textTheme.titleSmall),
        ]),
        const SizedBox(height: Gap.s),
        Text(l.opsTelematicsNone,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}

/// Okno wiadomości do kierowcy; kontroler żyje tyle co okno (także w animacji zamykania).
class MessageDialog extends StatefulWidget {
  const MessageDialog({super.key, required this.driver});

  final String driver;

  @override
  State<MessageDialog> createState() => _MessageDialogState();
}

class _MessageDialogState extends State<MessageDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      title: Text(l.opsMessageTitle(widget.driver)),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const Key('ops-message-text'),
          controller: _controller,
          autofocus: true,
          maxLength: 500,
          maxLines: 4,
          minLines: 2,
          decoration: InputDecoration(hintText: l.opsMessageHint),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          key: const Key('ops-message-send'),
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l.opsSend),
        ),
      ],
    );
  }
}

/// Karta stanu na dole menu: połączenie z serwerem na żywo, zestawy w trasie, telematyka.
class DashStatusCard extends StatelessWidget {
  const DashStatusCard({super.key, required this.summary});

  final DashSummary summary;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final DashSummary(:live, :active, :total, :telematics) = summary;
    final dot = Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: live ? scheme.tertiaryContainer : scheme.outline, shape: BoxShape.circle),
    );
    return Container(
      key: const Key('shell-status'),
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          dot,
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(l.statusServer.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          Text(live ? l.opsLive : l.statusOffline,
              style: theme.textTheme.labelMedium?.copyWith(color: live ? scheme.tertiaryContainer : scheme.outline)),
        ]),
        if (active != null && total != null) ...[
          const SizedBox(height: Gap.s),
          Row(children: [
            Expanded(child: Text(l.dashOnRouteTitle, style: theme.textTheme.bodySmall)),
            Text('${l.number(active)} / ${l.number(total)}', style: theme.textTheme.labelLarge),
          ]),
          const SizedBox(height: Gap.s),
          TruckProgressBar(value: total == 0 ? 0 : active / total, height: 6, color: scheme.tertiaryContainer),
        ],
        const SizedBox(height: Gap.s),
        Row(children: [
          Expanded(
            child: Text(telematics ? l.statusTelematicsOn : l.statusTelematicsNone,
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
          ),
          Icon(telematics ? Icons.sensors_outlined : Icons.sensors_off_outlined, size: 16, color: scheme.outline),
        ]),
      ]),
    );
  }
}
