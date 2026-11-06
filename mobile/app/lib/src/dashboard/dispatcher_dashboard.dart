import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'dispatcher_parts.dart';

export 'dispatcher_parts.dart' show DashAction, DashStatusCard, DashSummary, DashTile;

/// Pulpit główny dyspozytora: powitanie, cztery wskaźniki, sprawy wymagające decyzji, zestawy w trasie,
/// szybki dostęp do modułów i komunikaty. Dane z `/api/dashboard/*`, `/api/vehicles` i `/api/me/messages`;
/// na żywo przez Server-Sent Events, gdy ekran jest widoczny ([active]); po zerwaniu – ponowienie po chwili.
class DispatcherDashboard extends StatefulWidget {
  const DispatcherDashboard({
    super.key,
    required this.api,
    required this.companyId,
    required this.userName,
    this.active = true,
    this.actions = const [],
    this.tiles = const [],
    this.onOpenInbox,
    this.onSummary,
    this.retryAfter = const Duration(seconds: 10),
  });

  final CoreApi api;
  final String companyId;
  final String userName;
  final bool active;

  /// Przyciski karty powitania (ostatni – główny).
  final List<DashAction> actions;

  /// Kafle „Szybki dostęp do modułów”.
  final List<DashTile> tiles;
  final VoidCallback? onOpenInbox;
  final ValueChanged<DashSummary>? onSummary;
  final Duration retryAfter;

  @override
  State<DispatcherDashboard> createState() => _DispatcherDashboardState();
}

class _DispatcherDashboardState extends State<DispatcherDashboard> {
  Map<String, dynamic>? _overview;
  List<Map<String, dynamic>> _alerts = const [];
  List<Map<String, dynamic>>? _handled;
  List<Map<String, dynamic>> _onRoute = const [];
  List<Map<String, dynamic>> _messages = const [];
  Object? _error;
  bool _live = false;
  final Set<String> _busy = {};
  StreamSubscription<({String event, dynamic data})>? _stream;
  Timer? _retry;
  DashSummary? _lastSummary;

  String get _query => 'company_id=${Uri.encodeQueryComponent(widget.companyId)}';

  @override
  void initState() {
    super.initState();
    _load();
    if (widget.active) _connect();
  }

  @override
  void didUpdateWidget(DispatcherDashboard old) {
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
        _alerts = maps(results[1]);
        if (results.length > 2) _handled = maps(results[2]).where((a) => a['handled'] != null).toList();
        _error = null;
      });
      _report();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
    _loadExtras();
  }

  /// Zestawy w trasie i ostatnie wiadomości – dodatki: bez nich pulpit działa dalej.
  Future<void> _loadExtras() async {
    try {
      final vehicles = maps(await widget.api.get('/api/vehicles'));
      if (mounted) {
        setState(() => _onRoute = [
              for (final v in vehicles)
                if (v['company_id'] == widget.companyId &&
                    v['in_use'] == true &&
                    !const {'semitrailer', 'trailer'}.contains(v['kind']))
                  v
            ]);
      }
    } catch (_) {}
    try {
      final inbox = await widget.api.get('/api/me/messages') as Map<String, dynamic>;
      if (mounted) setState(() => _messages = maps(inbox['items']).take(3).toList());
    } catch (_) {}
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
          _alerts = maps(data['alerts']);
        });
        _report();
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
    _report();
    if (widget.active) _retry = Timer(widget.retryAfter, () => mounted && widget.active ? _connect() : null);
  }

  void _disconnect() {
    _retry?.cancel();
    _stream?.cancel();
    _stream = null;
    _live = false;
  }

  void _report() {
    final overview = _overview;
    final active = overview == null ? null : kpiOf(overview, 'fleet.active');
    final summary = DashSummary(
      live: _live,
      active: (active?['value'] as num?)?.toInt(),
      total: (active?['total'] as num?)?.toInt(),
      critical: _alerts.where((a) => a['severity'] == 'critical').length,
      telematics: overview?['telematics'] == true,
    );
    if (summary == _lastSummary) return;
    _lastSummary = summary;
    widget.onSummary?.call(summary);
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
      builder: (context) => MessageDialog(driver: '${alert['driver_name'] ?? ''}'),
    );
    if (text != null && text.isNotEmpty) await _act(alert, 'message_driver', text: text);
  }

  Future<void> _toggleHandled() async {
    final show = _handled == null;
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
    final kpis = maps(overview['kpis']);
    final main = mainKpis(kpis);
    final rest = [
      for (final k in kpis)
        if (!main.contains(k) && kpiInfo(l, k) != null) k
    ];
    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(builder: (context, size) {
        const gap = 20.0;
        final pad = size.maxWidth >= 720 ? Gap.xl : Gap.l;
        final inner = size.maxWidth - pad * 2;
        final twoColumns = size.maxWidth >= 1100;
        final kpiColumns = twoColumns ? 4 : (size.maxWidth >= 600 ? 2 : 1);
        final kpiWidth = (inner - gap * (kpiColumns - 1)) / kpiColumns;
        final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AlertsCard(
            alerts: _alerts,
            handled: _handled,
            busy: _busy,
            onToggleHandled: _toggleHandled,
            onAck: (a) => _act(a, 'acknowledge'),
            onMessage: _message,
            onReopen: _reopen,
          ),
          const SizedBox(height: gap),
          OnRouteCard(vehicles: _onRoute),
        ]);
        final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (widget.tiles.isNotEmpty) ...[
            QuickAccessCard(tiles: widget.tiles, kpis: kpis),
            const SizedBox(height: gap),
          ],
          MessagesCard(messages: _messages, onOpen: widget.onOpenInbox),
          if (overview['telematics'] != true) ...[
            const SizedBox(height: gap),
            const TelematicsCard(),
          ],
        ]);
        return ListView(padding: EdgeInsets.all(pad), children: [
          WelcomeCard(
            overview: overview,
            userName: widget.userName,
            live: _live,
            actions: widget.actions,
            onRefresh: _load,
          ),
          const SizedBox(height: gap),
          Wrap(spacing: gap, runSpacing: gap, children: [
            for (final kpi in main) SizedBox(width: kpiWidth, child: DashKpiCard(kpi: kpi)),
          ]),
          if (rest.isNotEmpty) ...[
            const SizedBox(height: gap),
            MoreKpis(kpis: rest),
          ],
          const SizedBox(height: gap),
          if (twoColumns)
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
      }),
    );
  }
}
