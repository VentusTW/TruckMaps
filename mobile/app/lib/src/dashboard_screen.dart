import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'inbox_screen.dart' show inboxTitle;
import 'l10n.dart';
import 'planner/recent.dart';
import 'vehicles/service_dates.dart';
import 'vehicles/vehicle_actions.dart' show vehicleTitle;
import 'vehicles/vehicle_form.dart' show kindIcon;
import 'vehicles/vehicle_state.dart';

/// Pulpit startowy: szybkie akcje i to, co wymaga uwagi – terminy i stan pojazdów, nowe
/// wiadomości, ostatnie trasy oraz sekcje modułów (np. otwarte usterki, terminy kierowców).
class DashboardScreen extends StatefulWidget {
  const DashboardScreen({
    super.key,
    required this.api,
    required this.userName,
    required this.memory,
    required this.onPlanRoute,
    required this.onOpenVehicle,
    required this.onAddVehicle,
    required this.onOpenPage,
    this.sections = const [],
  });

  final CoreApi api;
  final String userName;
  final PlannerMemory memory;

  /// Planer – pusty albo z ostatnią trasą.
  final ValueChanged<RecentRoute?> onPlanRoute;
  final ValueChanged<Map<String, dynamic>> onOpenVehicle;
  final VoidCallback onAddVehicle;

  /// Inny ekran menu (np. „inbox”, „vehicles”).
  final ValueChanged<String> onOpenPage;

  /// Sekcje modułów z dostępem.
  final List<DashboardSection> sections;

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<dynamic> _vehicles = widget.api.get('/api/vehicles');
  late Future<dynamic> _inbox = widget.api.get('/api/me/messages');
  int _version = 0;

  @override
  void initState() {
    super.initState();
    widget.memory.addListener(_changed);
    widget.memory.load();
  }

  @override
  void dispose() {
    widget.memory.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    final vehicles = widget.api.get('/api/vehicles');
    final inbox = widget.api.get('/api/me/messages');
    setState(() {
      _vehicles = vehicles;
      _inbox = inbox;
      _version++;
    });
    await Future.wait([vehicles, inbox].map((f) => f.catchError((_) => null)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final sections = [...widget.sections]..sort((a, b) => a.order.compareTo(b.order));
    final hour = DateTime.now().hour;
    final greeting = hour < 5 || hour >= 18 ? l.dashGreetingEvening : l.dashGreeting;
    final cards = <Widget>[
      _VehiclesAttention(future: _vehicles, onOpen: widget.onOpenVehicle, onAll: () => widget.onOpenPage('vehicles')),
      _MessagesCard(future: _inbox, onOpen: () => widget.onOpenPage('inbox')),
      _RecentCard(routes: widget.memory.routes, onOpen: widget.onPlanRoute),
      for (final s in sections) KeyedSubtree(key: ValueKey((s.id, _version)), child: Builder(builder: s.builder)),
    ];
    return RefreshIndicator(
      onRefresh: _refresh,
      child: LayoutBuilder(builder: (context, size) {
        final columns = size.maxWidth >= 1100 ? 3 : (size.maxWidth >= 720 ? 2 : 1);
        final width = (size.maxWidth - Gap.l * 2 - Gap.m * (columns - 1)) / columns;
        return ListView(padding: const EdgeInsets.all(Gap.l), children: [
          Row(children: [
            Expanded(
              child: Text(widget.userName.isEmpty ? greeting : '$greeting, ${widget.userName}',
                  style: theme.textTheme.headlineSmall),
            ),
            IconButton(tooltip: l.dashRefresh, onPressed: _refresh, icon: const Icon(Icons.refresh)),
          ]),
          Text(DateFormat.yMMMMEEEEd(l.localeName).format(DateTime.now()), style: theme.textTheme.bodyMedium),
          const SizedBox(height: Gap.l),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            FilledButton.icon(
              key: const Key('dash-plan'),
              onPressed: () => widget.onPlanRoute(null),
              icon: const Icon(Icons.route_outlined),
              label: Text(l.planRoute),
            ),
            if (widget.memory.routes.firstOrNull case final last?)
              FilledButton.tonalIcon(
                key: const Key('dash-repeat'),
                onPressed: () => widget.onPlanRoute(last),
                icon: const Icon(Icons.replay),
                label: Text(l.dashRepeatRoute(_short(last.to.label))),
              ),
            OutlinedButton.icon(
              onPressed: widget.onAddVehicle,
              icon: const Icon(Icons.add),
              label: Text(l.vehicleAdd),
            ),
          ]),
          const SizedBox(height: Gap.l),
          Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ]),
        ]);
      }),
    );
  }
}

String _short(String label) => label.split(',').first.trim();

/// Lista obiektów z odpowiedzi serwera; inny kształt (np. stary serwer) – pusta.
List<Map<String, dynamic>> _maps(Object? data) => data is List
    ? [
        for (final item in data)
          if (item is Map<String, dynamic>) item
      ]
    : const [];

/// Pojazdy z terminem po czasie / bliskim, serwisem według przebiegu albo w naprawie / z usterką.
class _VehiclesAttention extends StatelessWidget {
  const _VehiclesAttention({required this.future, required this.onOpen, required this.onAll});

  final Future<dynamic> future;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final VoidCallback onAll;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return SectionCard(
      title: l.dashVehiclesTitle,
      icon: Icons.local_shipping_outlined,
      action: TextButton(onPressed: onAll, child: Text(l.dashShowAll)),
      child: FutureBuilder<dynamic>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final items = <(int, Widget)>[];
          for (final v in _maps(snapshot.data)) {
            final state = vehicleState(v);
            final urgent = mostUrgent(v);
            final km = serviceKmLeft(v);
            final notes = [
              if (state == VehicleState.repair || state == VehicleState.reported) stateText(l, v)!,
              if (urgent != null)
                (urgent.overdue ? l.vehicleOverdue : l.vehicleDueSoon)(
                    serviceDateLabel(l, urgent.key), DateFormat.yMd(l.localeName).format(urgent.day)),
              if (km != null) km < 0 ? l.vehicleServiceKmOverdue(l.number(-km)) : l.vehicleServiceKmSoon(l.number(km)),
            ];
            if (notes.isEmpty) continue;
            final overdue = state == VehicleState.repair || (urgent?.overdue ?? false) || (km != null && km < 0);
            items.add((
              overdue ? 0 : 1,
              AttentionTile(
                title: vehicleTitle(v),
                subtitle: notes.join(' · '),
                overdue: overdue,
                icon: kindIcon(v['kind'] as String?),
                onTap: () => onOpen(v),
              ),
            ));
          }
          if (items.isEmpty) return _AllGood(text: l.dashVehiclesOk);
          items.sort((a, b) => a.$1.compareTo(b.$1));
          return Column(children: [for (final (_, tile) in items.take(6)) tile]);
        },
      ),
    );
  }
}

class _MessagesCard extends StatelessWidget {
  const _MessagesCard({required this.future, required this.onOpen});

  final Future<dynamic> future;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return SectionCard(
      title: l.dashMessagesTitle,
      icon: Icons.mail_outline,
      action: TextButton(onPressed: onOpen, child: Text(l.dashShowAll)),
      child: FutureBuilder<dynamic>(
        future: future,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final data = snapshot.data;
          final items = _maps(data is Map ? data['items'] : null).where((m) => m['read'] != true).toList();
          if (items.isEmpty) return _AllGood(text: l.dashMessagesNone);
          return Column(children: [
            for (final m in items.take(4))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.mark_email_unread_outlined, color: Theme.of(context).colorScheme.primary),
                title: Text(inboxTitle(l, m), maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(l.when(DateTime.parse('${m['created_at']}').toLocal())),
                onTap: onOpen,
              ),
          ]);
        },
      ),
    );
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.routes, required this.onOpen});

  final List<RecentRoute> routes;
  final ValueChanged<RecentRoute?> onOpen;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return SectionCard(
      title: l.dashRecentTitle,
      icon: Icons.history,
      child: routes.isEmpty
          ? Text(l.dashRecentEmpty, style: Theme.of(context).textTheme.bodySmall)
          : Column(children: [
              for (final r in routes.take(4))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.route_outlined),
                  title: Text('${_short(r.from.label)} → ${_short(r.to.label)}'),
                  subtitle: r.vehicleName == null ? null : Text(r.vehicleName!),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => onOpen(r),
                ),
            ]),
    );
  }
}

class _AllGood extends StatelessWidget {
  const _AllGood({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Row(children: [
        Icon(Icons.check_circle_outline, color: TruckColors.of(context).success, size: 20),
        const SizedBox(width: Gap.s),
        Expanded(child: Text(text)),
      ]);
}
