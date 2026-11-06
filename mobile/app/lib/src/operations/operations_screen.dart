import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../inbox_screen.dart' show driverDueText, vehicleDueText;
import '../l10n.dart';

/// Skrót z pulpitu do innego ekranu (planer, pojazdy, moduły).
class OpsShortcut {
  const OpsShortcut(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;
}

/// Główny pulpit operacyjny dyspozytora: wskaźniki floty, sprawy wymagające uwagi (z akcjami)
/// i szybkie akcje. Dane z `/api/dashboard/*`; na żywo przez Server-Sent Events, gdy ekran jest
/// widoczny ([active]); po zerwaniu połączenia – ponowienie po chwili.
class OperationsScreen extends StatefulWidget {
  const OperationsScreen({
    super.key,
    required this.api,
    required this.companyId,
    this.active = true,
    this.shortcuts = const [],
    this.retryAfter = const Duration(seconds: 10),
  });

  final CoreApi api;
  final String companyId;
  final bool active;
  final List<OpsShortcut> shortcuts;
  final Duration retryAfter;

  @override
  State<OperationsScreen> createState() => _OperationsScreenState();
}

enum _Filter { all, critical, warning, info }

class _OperationsScreenState extends State<OperationsScreen> {
  Map<String, dynamic>? _overview;
  List<Map<String, dynamic>> _alerts = const [];
  List<Map<String, dynamic>>? _handled;
  Object? _error;
  bool _live = false;
  _Filter _filter = _Filter.all;
  final Set<String> _busy = {};
  StreamSubscription<({String event, dynamic data})>? _stream;
  Timer? _retry;

  String get _query => 'company_id=${Uri.encodeQueryComponent(widget.companyId)}';

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.active) _connect();
  }

  @override
  void didUpdateWidget(OperationsScreen old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId) {
      _disconnect();
      _overview = null;
      _handled = null;
      _load();
    }
    if (widget.active && _stream == null) {
      _connect();
    } else if (!widget.active) {
      _disconnect();
    }
  }

  @override
  void dispose() {
    _disconnect();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.get('/api/dashboard/overview?$_query'),
        widget.api.get('/api/dashboard/alerts?$_query'),
        if (_handled != null) widget.api.get('/api/dashboard/alerts?$_query&include_handled=true'),
      ]);
      if (!mounted) return;
      setState(() {
        _overview = results[0] as Map<String, dynamic>;
        _alerts = _maps(results[1]);
        if (results.length > 2) _handled = _maps(results[2]).where((a) => a['handled'] != null).toList();
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _connect() {
    _retry?.cancel();
    _stream = widget.api.events('/api/dashboard/stream?$_query').listen(
      (event) {
        if (event.event != 'snapshot' || event.data is! Map) return;
        final data = event.data as Map<String, dynamic>;
        setState(() {
          _live = true;
          _error = null;
          _overview = data['overview'] as Map<String, dynamic>;
          _alerts = _maps(data['alerts']);
        });
      },
      onError: (_) => _lost(),
      onDone: _lost,
      cancelOnError: true,
    );
  }

  void _lost() {
    _stream = null;
    if (!mounted) return;
    setState(() => _live = false);
    if (widget.active) _retry = Timer(widget.retryAfter, () => mounted && widget.active ? _connect() : null);
  }

  void _disconnect() {
    _retry?.cancel();
    _stream?.cancel();
    _stream = null;
    _live = false;
  }

  Future<void> _act(Map<String, dynamic> alert, String action, {String? text}) async {
    final l = context.l;
    final id = '${alert['id']}';
    if (_busy.contains(id)) return; // podwójne kliknięcie
    setState(() => _busy.add(id));
    try {
      final result = await widget.api.post('/api/dashboard/alerts/${Uri.encodeComponent(id)}/action', {
        'company_id': widget.companyId,
        'action': action,
        if (text != null) 'text': text,
      });
      if (!mounted) return;
      final duplicate = result is Map && result['duplicate'] == true;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(duplicate ? l.opsAlreadyHandled : (action == 'message_driver' ? l.opsSent : l.opsAcked))));
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _reopen(Map<String, dynamic> alert) async {
    try {
      await widget.api.delete('/api/dashboard/alerts/${Uri.encodeComponent('${alert['id']}')}/action?$_query');
      await _load();
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _message(Map<String, dynamic> alert) async {
    final text = await showDialog<String>(
      context: context,
      builder: (context) => _MessageDialog(driver: '${alert['driver_name'] ?? ''}'),
    );
    if (text != null && text.isNotEmpty) await _act(alert, 'message_driver', text: text);
  }

  Future<void> _toggleHandled(bool show) async {
    setState(() => _handled = show ? const [] : null);
    if (show) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final overview = _overview;
    if (overview == null) {
      if (_error != null) {
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('$_error', textAlign: TextAlign.center),
            const SizedBox(height: Gap.m),
            OutlinedButton(onPressed: _load, child: Text(l.retry)),
          ]),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(builder: (context, size) {
        final wide = size.maxWidth >= 1100;
        final pad = size.maxWidth >= 720 ? Gap.xl : Gap.l;
        final kpiColumns = wide ? 4 : (size.maxWidth >= 720 ? 3 : 2);
        final kpiWidth = (size.maxWidth - pad * 2 - Gap.m * (kpiColumns - 1)) / kpiColumns;
        final alerts = _AlertsPanel(
          alerts: _alerts,
          handled: _handled,
          filter: _filter,
          busy: _busy,
          onFilter: (f) => setState(() => _filter = f),
          onShowHandled: _toggleHandled,
          onAck: (a) => _act(a, 'acknowledge'),
          onMessage: _message,
          onReopen: _reopen,
        );
        final side = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.shortcuts.isNotEmpty) _Shortcuts(shortcuts: widget.shortcuts),
          if (overview['telematics'] != true) ...[
            const SizedBox(height: Gap.m),
            _TelematicsCard(),
          ],
        ]);
        return ListView(padding: EdgeInsets.all(pad), children: [
          _Header(overview: overview, live: _live, onRefresh: _load),
          const SizedBox(height: Gap.l),
          Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
            for (final kpi in _maps(overview['kpis']))
              if (_kpiCard(context, kpi) case final card?) SizedBox(width: kpiWidth, child: card),
          ]),
          const SizedBox(height: Gap.l),
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(flex: 8, child: alerts),
              const SizedBox(width: Gap.l),
              Expanded(flex: 4, child: side),
            ])
          else ...[
            alerts,
            const SizedBox(height: Gap.l),
            side,
          ],
        ]);
      }),
    );
  }
}

List<Map<String, dynamic>> _maps(dynamic list) => list is List
    ? [
        for (final item in list)
          if (item is Map<String, dynamic>) item
      ]
    : const [];

StatusTone _tone(dynamic tone) => switch (tone) {
      'ok' => StatusTone.ok,
      'warning' => StatusTone.warning,
      'error' => StatusTone.error,
      _ => StatusTone.info,
    };

/// Karta wskaźnika z klucza serwera; nieznany klucz (nowszy moduł) – pomijany.
Widget? _kpiCard(BuildContext context, Map<String, dynamic> kpi) {
  final l = context.l;
  final value = kpi['value'] as num? ?? 0;
  final total = kpi['total'] as num?;
  final unit = '${kpi['unit'] ?? ''}';
  String? of() => total == null ? null : l.opsOf(l.number(total));
  final (String label, IconData icon, String? status) = switch ('${kpi['key']}') {
    'fleet.active' => (
        l.opsKpiActive,
        Icons.local_shipping_outlined,
        total == null || total == 0 ? of() : '${of()} · ${l.opsUtilization(l.number(100 * value / total, decimals: 0))}'
      ),
    'fleet.available' => (l.opsKpiAvailable, Icons.check_circle_outline, of()),
    'fleet.service' => (l.opsKpiService, Icons.build_outlined, null),
    'fleet.health' => (l.opsKpiHealth, Icons.health_and_safety_outlined, l.opsHealthHint),
    'fleet.deadlines' => (l.opsKpiDeadlines, Icons.event_note_outlined, l.opsDeadlinesHint),
    'trips.today' => (l.opsKpiTrips, Icons.route_outlined, null),
    'trips.km_today' => (l.opsKpiKm, Icons.speed_outlined, null),
    'costs.today' => (l.opsKpiCosts, Icons.payments_outlined, null),
    'trips.plan_deviation' => (l.opsKpiPlan, Icons.compare_arrows, l.opsPlanHint),
    'inbox.unread' => (l.opsKpiUnread, Icons.mail_outline, null),
    'drivers.assigned' => (l.opsKpiDrivers, Icons.badge_outlined, of()),
    'drivers.deadlines' => (l.opsKpiDriverDeadlines, Icons.event_busy_outlined, null),
    'service.open' => (l.opsKpiServiceOpen, Icons.car_repair_outlined, null),
    'documents.today' => (l.opsKpiDocuments, Icons.description_outlined, null),
    _ => ('', Icons.circle, null),
  };
  if (label.isEmpty) return null;
  final shown = unit == '%' && kpi['key'] == 'trips.plan_deviation' && value > 0
      ? '+${l.number(value, decimals: 1)}'
      : l.number(value, decimals: unit == 'km' ? 0 : (unit == '%' ? 1 : 2));
  return KpiCard(
    key: Key('ops-kpi-${kpi['key']}${unit.length == 3 ? '-$unit' : ''}'),
    label: label,
    value: shown,
    unit: unit.isEmpty ? null : unit,
    icon: icon,
    status: status,
    tone: _tone(kpi['tone']),
  );
}

class _Header extends StatelessWidget {
  const _Header({required this.overview, required this.live, required this.onRefresh});

  final Map<String, dynamic> overview;
  final bool live;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final generated = DateTime.tryParse('${overview['generated_at']}')?.toLocal();
    final bases = [for (final b in overview['bases'] as List? ?? const []) '$b'];
    final date = DateFormat.yMMMMEEEEd(l.localeName).format(generated ?? DateTime.now());
    return Wrap(
      spacing: Gap.m,
      runSpacing: Gap.s,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.spaceBetween,
      children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(l.menuOperations, style: theme.textTheme.headlineMedium),
          Text(l.opsHeader('${overview['company_name']}', date),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary)),
          if (bases.isNotEmpty)
            Text(l.opsBases(bases.join(', ')),
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary)),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          StatusChip(
            key: const Key('ops-live'),
            label: live ? l.opsLive : l.opsOffline,
            tone: live ? StatusTone.ok : StatusTone.neutral,
            pulse: live,
          ),
          if (generated != null) ...[
            const SizedBox(width: Gap.s),
            Text(l.opsUpdated(DateFormat.Hms(l.localeName).format(generated)), style: theme.textTheme.bodySmall),
          ],
          IconButton(tooltip: l.opsRefresh, onPressed: onRefresh, icon: const Icon(Icons.refresh)),
        ]),
      ],
    );
  }
}

class _AlertsPanel extends StatelessWidget {
  const _AlertsPanel({
    required this.alerts,
    required this.handled,
    required this.filter,
    required this.busy,
    required this.onFilter,
    required this.onShowHandled,
    required this.onAck,
    required this.onMessage,
    required this.onReopen,
  });

  final List<Map<String, dynamic>> alerts;
  final List<Map<String, dynamic>>? handled;
  final _Filter filter;
  final Set<String> busy;
  final ValueChanged<_Filter> onFilter;
  final ValueChanged<bool> onShowHandled;
  final ValueChanged<Map<String, dynamic>> onAck;
  final ValueChanged<Map<String, dynamic>> onMessage;
  final ValueChanged<Map<String, dynamic>> onReopen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    int count(String s) => alerts.where((a) => a['severity'] == s).length;
    final shown = filter == _Filter.all ? alerts : alerts.where((a) => a['severity'] == filter.name).toList();
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(TruckTheme.dialogRadius)),
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: SectionLabel(l.opsAlerts)),
            Text(l.opsShowHandled, style: Theme.of(context).textTheme.labelMedium),
            Switch(key: const Key('ops-show-handled'), value: handled != null, onChanged: onShowHandled),
          ]),
          const SizedBox(height: Gap.s),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final (f, label) in [
              (_Filter.all, l.opsFilterAll(l.number(alerts.length))),
              (_Filter.critical, l.opsCritical(l.number(count('critical')))),
              (_Filter.warning, l.opsWarning(l.number(count('warning')))),
              (_Filter.info, l.opsInfo(l.number(count('info')))),
            ])
              ChoiceChip(label: Text(label), selected: filter == f, onSelected: (_) => onFilter(f)),
          ]),
          const SizedBox(height: Gap.m),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Gap.xl),
              child: Center(child: StatusChip(label: l.opsAlertsEmpty, tone: StatusTone.ok, uppercase: false)),
            ),
          for (final alert in shown)
            _AlertTile(
              alert: alert,
              busy: busy.contains(alert['id']),
              onAck: () => onAck(alert),
              onMessage: () => onMessage(alert),
            ),
          if (handled case final done? when done.isNotEmpty) ...[
            const Divider(height: Gap.xl),
            for (final alert in done) _AlertTile(alert: alert, busy: false, onReopen: () => onReopen(alert)),
          ],
        ]),
      ),
    );
  }
}

class _AlertTile extends StatelessWidget {
  const _AlertTile({required this.alert, required this.busy, this.onAck, this.onMessage, this.onReopen});

  final Map<String, dynamic> alert;
  final bool busy;
  final VoidCallback? onAck;
  final VoidCallback? onMessage;
  final VoidCallback? onReopen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    final severity = alert['severity'];
    final accent = switch (severity) {
      'critical' => theme.colorScheme.error,
      'warning' => colors.amber,
      _ => theme.colorScheme.primary,
    };
    final (title, body, icon) = alertText(l, alert);
    final actions = [for (final a in alert['actions'] as List? ?? const []) '$a'];
    final handled = alert['handled'] as Map<String, dynamic>?;
    final details = [
      if (body.isNotEmpty) body,
      if (alert['driver_name'] != null && alert['kind'] != 'drivers.due') l.opsDriver('${alert['driver_name']}'),
      if (handled != null)
        l.opsHandledBy('${handled['by_name']}', l.when(DateTime.parse('${handled['at']}').toLocal())),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.s),
      child: Container(
        key: Key('ops-alert-${alert['id']}'),
        decoration: BoxDecoration(
          color: handled != null ? colors.surfaceLow : colors.card,
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          border: Border.all(color: colors.surfaceHigh),
        ),
        clipBehavior: Clip.antiAlias,
        // Pasek wagi sprawy po lewej (bez promienia – zaokrągla go obrys karty).
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: accent, width: 4))),
          child: Padding(
            padding: const EdgeInsets.all(Gap.m),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(icon, color: accent),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: theme.textTheme.titleSmall),
                  for (final line in details)
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.xs),
                      child: Text(line, style: theme.textTheme.bodySmall),
                    ),
                  if (handled == null && (onAck != null || onMessage != null))
                    Padding(
                      padding: const EdgeInsets.only(top: Gap.s),
                      child: Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                        if (actions.contains('message_driver'))
                          FilledButton.tonalIcon(
                            key: Key('ops-message-${alert['id']}'),
                            onPressed: busy ? null : onMessage,
                            icon: const Icon(Icons.send_outlined, size: 18),
                            label: Text(l.opsMessage),
                          ),
                        if (actions.contains('acknowledge'))
                          OutlinedButton.icon(
                            key: Key('ops-ack-${alert['id']}'),
                            onPressed: busy ? null : onAck,
                            icon: const Icon(Icons.done, size: 18),
                            label: Text(l.opsAck),
                          ),
                      ]),
                    ),
                ]),
              ),
              if (handled != null && onReopen != null) TextButton(onPressed: onReopen, child: Text(l.opsReopen)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Tytuł, treść i ikona sprawy z jej rodzaju i danych (teksty z .arb).
(String, String, IconData) alertText(AppLocalizations l, Map<String, dynamic> alert) {
  final data = (alert['data'] as Map<String, dynamic>?) ?? const {};
  final vehicle = [alert['vehicle_name'], if (alert['plate'] != null) alert['plate']].whereType<Object>().join(' · ');
  return switch (alert['kind']) {
    'vehicle_due' => (l.inboxVehicleDue(vehicle), vehicleDueText(l, data), Icons.event_note_outlined),
    'vehicle_reported' => (l.opsAlertReported(vehicle), '', Icons.report_problem_outlined),
    'vehicle_repair' => (l.opsAlertRepair(vehicle), '', Icons.build_outlined),
    'drivers.due' => (l.inboxDriverDue('${data['driver_name']}'), driverDueText(l, data), Icons.badge_outlined),
    'service.order' => (
        l.opsAlertServiceOrder(vehicle),
        [
          '„${data['description']}”',
          switch (data['status']) {
            'accepted' => l.opsOrderAccepted('${data['mechanic_name'] ?? ''}'),
            'in_progress' => l.opsOrderInProgress,
            _ => l.opsOrderNew,
          },
          if (data['urgency'] == 'stopped') l.opsOrderStopped,
        ].join(' · '),
        Icons.car_repair_outlined
      ),
    _ => ('${alert['kind']}', vehicle, Icons.info_outline),
  };
}

class _Shortcuts extends StatelessWidget {
  const _Shortcuts({required this.shortcuts});

  final List<OpsShortcut> shortcuts;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionLabel(context.l.opsQuick),
          const SizedBox(height: Gap.s),
          for (final s in shortcuts)
            Padding(
              padding: const EdgeInsets.only(top: Gap.s),
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(alignment: Alignment.centerLeft),
                onPressed: s.onTap,
                icon: Icon(s.icon),
                label: Text(s.label),
              ),
            ),
        ]),
      ),
    );
  }
}

class _TelematicsCard extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.sensors_off_outlined, color: theme.colorScheme.secondary),
            const SizedBox(width: Gap.s),
            SectionLabel(l.opsTelematics),
          ]),
          const SizedBox(height: Gap.s),
          Text(l.opsTelematicsNone, style: theme.textTheme.bodySmall),
        ]),
      ),
    );
  }
}

/// Okno wiadomości do kierowcy; kontroler żyje tyle co okno (także w animacji zamykania).
class _MessageDialog extends StatefulWidget {
  const _MessageDialog({required this.driver});

  final String driver;

  @override
  State<_MessageDialog> createState() => _MessageDialogState();
}

class _MessageDialogState extends State<_MessageDialog> {
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
