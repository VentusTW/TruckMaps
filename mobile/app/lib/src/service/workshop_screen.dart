import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:module_service/module_service.dart' show ReportScreen;

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'service_data.dart';

/// „Warsztat i Serwis” według projektu Stitch: dostępność floty, przestoje, otwarte zlecenia i koszty
/// z modułu Serwis, zlecenia w realizacji jako stanowiska, kolejka zleceń; stanowiska fizyczne,
/// kody DTC, pogotowie i magazyn części – „W budowie”.
class WorkshopScreen extends StatefulWidget {
  const WorkshopScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.companyName,
    required this.onOpen,
    required this.onOpenOrder,
    required this.onOpenRepairs,
    required this.onOpenTco,
    this.today,
  });

  final CoreApi api;
  final String? companyId;
  final String companyName;
  final ValueChanged<String> onOpen;
  final void Function(String id, String name) onOpenOrder;
  final VoidCallback onOpenRepairs;
  final VoidCallback onOpenTco;
  final DateTime? today;

  @override
  State<WorkshopScreen> createState() => _WorkshopScreenState();
}

class _WorkshopScreenState extends State<WorkshopScreen> {
  FleetData? _data;
  Object? _error;
  String _query = '';
  int _page = 0;

  DateTime get _now => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Nowe zgłoszenie usterki (formularz modułu serwisu); po powrocie – świeże dane.
  Future<void> _newOrder() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReportScreen(api: widget.api)));
    if (mounted) await _load();
  }

  /// Wolne stanowisko: wybór czekającego zgłoszenia i przyjęcie pojazdu (`accept`).
  Future<void> _bringIn(FleetData data) async {
    final l = context.l;
    final waiting = [
      for (final o in data.open)
        if (o['status'] == 'new') o
    ];
    if (waiting.isEmpty) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.wsNoWaiting)));
      return;
    }
    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.wsBringIn),
        children: [
          for (final o in waiting)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, o),
              child: ListTile(
                leading: Icon(o['urgency'] == 'stopped' ? Icons.car_crash_outlined : Icons.build_outlined),
                title:
                    Text('${data.vehicle(o['vehicle_id'])?['plate'] ?? data.vehicle(o['vehicle_id'])?['name'] ?? ''}'),
                subtitle: Text('${o['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    try {
      await widget.api.post('/api/m/service/orders/${chosen['id']}/accept', {});
      if (mounted) await _load();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _load() async {
    try {
      final data = await FleetData.load(widget.api, widget.companyId);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final data = _data;
    if (data == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error'));
    }
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final wide = inner >= 900;
      final kpiColumns = wide ? 4 : (inner >= 560 ? 2 : 1);
      final kpiWidth = (inner - gap * (kpiColumns - 1)) / kpiColumns;
      final left = _queue(context, data);
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _wipPanel(context, l.wsRoadside, l.wsRoadsideNote, Icons.car_crash_outlined),
        const SizedBox(height: gap),
        _wipPanel(context, l.wsParts, l.wsPartsNote, Icons.inventory_outlined),
      ]);
      return ListView(padding: EdgeInsets.all(pad), children: [
        _header(context, data),
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          for (final k in _kpis(context, data)) SizedBox(width: kpiWidth, child: k),
        ]),
        const SizedBox(height: gap),
        _bays(context, data, inner),
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

  Widget _header(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    Widget tab(String label, IconData icon,
            {int? count, bool selected = false, VoidCallback? onTap, bool dot = false}) =>
        Material(
          color: selected ? scheme.primaryContainer : colors.surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          child: InkWell(
            borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
            onTap: onTap ?? () => widget.onOpen(label),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 18, color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
                const SizedBox(width: Gap.s),
                Text(label,
                    style: theme.textTheme.labelLarge
                        ?.copyWith(color: selected ? scheme.onPrimaryContainer : scheme.onSurface)),
                if (count != null) ...[
                  const SizedBox(width: Gap.s),
                  UiTag('$count', tone: 'info'),
                ],
                if (dot) ...[
                  const SizedBox(width: Gap.s),
                  Container(
                      width: 6, height: 6, decoration: BoxDecoration(color: scheme.error, shape: BoxShape.circle)),
                ],
              ]),
            ),
          ),
        );
    return UiPanel(
      child: Wrap(
        spacing: Gap.l,
        runSpacing: Gap.m,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconSquare(icon: Icons.handyman_outlined, size: 36, color: scheme.onPrimary, background: scheme.primary),
              const SizedBox(width: Gap.m),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.wsCenter.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.5)),
                Text(widget.companyName, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              ]),
            ]),
            const SizedBox(height: Gap.m),
            Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
              tab(l.wsTabBays, Icons.view_quilt_outlined, selected: true, onTap: () {}),
              tab(l.wsTabOrders, Icons.assignment_outlined, count: data.open.length, onTap: widget.onOpenRepairs),
              tab(l.mainSubParts, Icons.inventory_2_outlined, dot: true),
              tab(l.wsTabSchedule, Icons.event_outlined),
            ]),
          ]),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
              onPressed: widget.onOpenTco,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(l.wsTcoReport),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
              onPressed: () => _newOrder(),
              icon: const Icon(Icons.add_box_outlined, size: 18),
              label: Text(l.wsNewOrder),
            ),
          ]),
        ],
      ),
    );
  }

  List<Widget> _kpis(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final power = data.power;
    final down = power.where((v) => v['in_repair'] == true || v['repair_reported'] == true).length;
    final availability = power.isEmpty ? null : 100 * (power.length - down) / power.length;
    final mttr = [
      for (final o in data.done)
        if ((day(o['completed_at']), day(o['created_at'])) case (final a?, final b?)) a.difference(b).inMinutes / 60
    ];
    final avgMttr = mttr.isEmpty ? null : mttr.reduce((a, b) => a + b) / mttr.length;
    final open = data.open;
    final critical = open.where((o) => o['urgency'] == 'stopped').length;
    final month = [
      for (final o in data.done)
        if (day(o['completed_at']) case final d? when d.year == _now.year && d.month == _now.month) o
    ];
    final monthCost = month.fold(0.0, (a, o) => a + orderTotal(o));
    Widget card(String label, IconData icon, Widget value, Widget foot,
            {double? bar, Color? barColor, Color? iconColor}) =>
        Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                    child: Text(label.toUpperCase(),
                        style:
                            theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.5))),
                IconSquare(icon: icon, size: 32, color: iconColor),
              ]),
              const SizedBox(height: Gap.s),
              value,
              const SizedBox(height: Gap.m),
              DefaultTextStyle.merge(style: theme.textTheme.bodySmall, child: foot),
              const SizedBox(height: Gap.s),
              TruckProgressBar(value: bar ?? 0, height: 6, color: barColor),
            ]),
          ),
        );
    final big = theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700);
    return [
      card(
        l.wsAvailability,
        Icons.verified_outlined,
        Text(availability == null ? '–' : '${l.number(availability, decimals: 1)}%', style: big),
        Row(children: [
          Expanded(child: Text(l.wsActiveOf(l.number(power.length - down), l.number(power.length)))),
          Text(l.wsInService(l.number(down)), style: TextStyle(color: scheme.error)),
        ]),
        bar: (availability ?? 0) / 100,
        barColor: colors.success,
      ),
      card(
        l.wsMttr,
        Icons.timelapse_outlined,
        Text.rich(TextSpan(children: [
          TextSpan(text: avgMttr == null ? '–' : l.number(avgMttr, decimals: 1), style: big),
          TextSpan(text: ' ${l.wsHours}', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
        ])),
        Row(children: [
          Expanded(child: Text(l.wsMttrNote(l.number(mttr.length)))),
          WipTag(what: l.wsMttrTarget, onOpen: widget.onOpen),
        ]),
        bar: avgMttr == null ? 0 : (avgMttr / 24).clamp(0, 1),
        barColor: scheme.primaryContainer,
      ),
      card(
        l.wsOpen,
        Icons.car_repair_outlined,
        Wrap(spacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text(l.number(open.length), style: big),
          if (critical > 0) UiTag(l.wsCritical(l.number(critical)), tone: 'error'),
        ]),
        Row(children: [
          Expanded(child: Text(l.wsNewCount(l.number(open.where((o) => o['status'] == 'new').length)))),
          Text(l.wsProgressCount(l.number(open.where((o) => o['status'] != 'new').length))),
        ]),
        bar: open.isEmpty ? 0 : critical / open.length,
        barColor: scheme.error,
        iconColor: scheme.error,
      ),
      card(
        l.wsMonthCost,
        Icons.account_balance_wallet_outlined,
        Text.rich(TextSpan(children: [
          TextSpan(text: l.number(monthCost, decimals: 0), style: big),
          TextSpan(text: ' PLN', style: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline)),
        ])),
        Row(children: [
          Expanded(child: Text(l.wsMonthOrders(l.number(month.length)))),
          WipTag(what: l.wsBudget, onOpen: widget.onOpen),
        ]),
        bar: 0,
      ),
    ];
  }

  Widget _bays(BuildContext context, FleetData data, double inner) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final active = [
      for (final o in data.open)
        if (o['status'] != 'new') o
    ];
    final shown = active.take(4).toList();
    final columns = inner >= 900 ? 4 : (inner >= 560 ? 2 : 1);
    final width = (inner - 40 - Gap.m * (columns - 1)) / columns;
    Widget bay(int i, Map<String, dynamic>? o) {
      if (o == null) {
        return Container(
          width: width,
          height: 250,
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(
            border: Border.all(color: colors.surfaceHigh, width: 1.5),
            borderRadius: BorderRadius.circular(TruckTheme.radius),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              UiTag(l.wsBay(l.number(i + 1)), tone: 'info'),
              const Spacer(),
              UiTag(l.wsFree, tone: 'info', uppercase: false),
            ]),
            const Spacer(),
            Text(l.wsFreeNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
            const SizedBox(height: Gap.s),
            TextButton.icon(
              onPressed: () => _bringIn(data),
              icon: const Icon(Icons.play_arrow_outlined, size: 18),
              label: Text(l.wsBringIn),
            ),
          ]),
        );
      }
      final v = data.vehicle(o['vehicle_id']);
      final vor = o['urgency'] == 'stopped';
      final progress = orderProgress(o['status']);
      return InkWell(
        key: Key('ws-bay-${o['id']}'),
        onTap: () => widget.onOpenOrder('${o['id']}', orderNo(o)),
        child: Container(
          width: width,
          height: 250,
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              UiTag(l.wsBay(l.number(i + 1)), tone: 'info'),
              const Spacer(),
              UiTag(vor ? l.wsVor : orderStatus(l, o['status']), tone: vor ? 'error' : 'tertiary', uppercase: false),
            ]),
            const SizedBox(height: Gap.m),
            Text('${o['vehicle_plate'] ?? o['vehicle_name']}',
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text('${v?['name'] ?? o['vehicle_name']}',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.primary)),
            const SizedBox(height: Gap.s),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.s),
                decoration:
                    BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.wsTask.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                  Text('${o['description']}',
                      maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                ]),
              ),
            ),
            const SizedBox(height: Gap.s),
            Text(l.wsMechanic('${o['mechanic_name'] ?? '–'}'), style: theme.textTheme.labelMedium),
            const SizedBox(height: Gap.s),
            Text(l.wsProgress(orderStatus(l, o['status'])), style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            TruckProgressBar(value: progress, height: 6, color: vor ? scheme.error : scheme.primaryContainer),
          ]),
        ),
      );
    }

    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Container(
              width: 8, height: 8, decoration: BoxDecoration(color: scheme.tertiaryContainer, shape: BoxShape.circle)),
          const SizedBox(width: Gap.s),
          Expanded(
              child: Text(l.wsBaysTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          UiTag(l.wsBusy(l.number(shown.length)), tone: 'ok', uppercase: false),
          const SizedBox(width: Gap.s),
          WipTag(what: l.wsBaysTitle, onOpen: widget.onOpen),
        ]),
        Text(l.wsBaysSubtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.l),
        if (data.orders == null) UiEmpty(l.vehNoServiceModule),
        if (data.orders != null)
          Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
            for (var i = 0; i < 4; i++) bay(i, i < shown.length ? shown[i] : null),
          ]),
      ]),
    );
  }

  Widget _queue(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final q = _query.trim().toLowerCase();
    final rows = [
      for (final o in data.open)
        if (q.isEmpty ||
            [o['vehicle_plate'], o['vehicle_name'], o['description'], orderNo(o)]
                .any((s) => '${s ?? ''}'.toLowerCase().contains(q)))
          o
    ];
    const size = 4;
    final pages = (rows.length / size).ceil().clamp(1, 1 << 20);
    final page = _page.clamp(0, pages - 1);
    final shown = rows.skip(page * size).take(size).toList();
    final head = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4);
    final time = DateFormat.Hm(l.localeName);
    final date = DateFormat.yMd(l.localeName);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(
          spacing: Gap.m,
          runSpacing: Gap.s,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisSize: MainAxisSize.min, children: [
                Text(l.wsQueueTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(width: Gap.s),
                UiTag(l.wsOpenCount(l.number(data.open.length)), tone: 'info', uppercase: false),
              ]),
              Text(l.wsQueueSubtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            SizedBox(
              width: 240,
              child: TextField(
                key: const Key('ws-search'),
                onChanged: (v) => setState(() {
                  _query = v;
                  _page = 0;
                }),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l.wsSearch,
                  prefixIcon: Icon(Icons.filter_list, size: 18, color: scheme.outline),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Gap.l),
        Container(
          color: colors.surfaceLow,
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          child: Row(children: [
            Expanded(flex: 3, child: Text(l.wsColNo.toUpperCase(), style: head)),
            Expanded(flex: 3, child: Text(l.wsColVehicle.toUpperCase(), style: head)),
            Expanded(flex: 3, child: Text(l.wsColType.toUpperCase(), style: head)),
            Expanded(flex: 4, child: Text(l.wsColDtc.toUpperCase(), style: head)),
            Expanded(flex: 3, child: Text(l.wsColPriority.toUpperCase(), style: head)),
            Expanded(flex: 3, child: Text(l.wsColMechanic.toUpperCase(), style: head)),
          ]),
        ),
        if (data.orders == null) Padding(padding: const EdgeInsets.all(Gap.m), child: UiEmpty(l.vehNoServiceModule)),
        if (data.orders != null && shown.isEmpty)
          Padding(padding: const EdgeInsets.all(Gap.m), child: UiEmpty(l.wsNoOrders)),
        for (final o in shown)
          InkWell(
            key: Key('ws-row-${o['id']}'),
            onTap: () => widget.onOpenOrder('${o['id']}', orderNo(o)),
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.surfaceHigh))),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  flex: 3,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(orderNo(o), style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
                    if (day(o['created_at']) case final d?)
                      Text('${date.format(d)}\n${time.format(d)}',
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                  ]),
                ),
                Expanded(
                  flex: 3,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${o['vehicle_plate'] ?? ''}', style: theme.textTheme.labelLarge),
                    Text('${o['vehicle_name']}',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ]),
                ),
                Expanded(
                  flex: 3,
                  child: Row(children: [
                    Icon(o['urgency'] == 'stopped' ? Icons.warning_amber_outlined : Icons.person_outline,
                        size: 14, color: o['urgency'] == 'stopped' ? scheme.error : scheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(o['urgency'] == 'stopped' ? l.wsTypeBreakdown : l.wsTypeReport,
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: o['urgency'] == 'stopped' ? scheme.error : scheme.onSurfaceVariant)),
                    ),
                  ]),
                ),
                Expanded(
                  flex: 4,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    WipTag(what: l.wsColDtc, onOpen: widget.onOpen),
                    const SizedBox(height: 4),
                    Text('${o['description']}',
                        maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
                  ]),
                ),
                Expanded(
                  flex: 3,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: UiTag(o['urgency'] == 'stopped' ? l.wsVorCritical : l.wsStandard,
                        tone: o['urgency'] == 'stopped' ? 'critical' : 'info'),
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text('${o['mechanic_name'] ?? l.wsUnassigned}',
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontStyle: o['mechanic_name'] == null ? FontStyle.italic : null,
                          color: o['mechanic_name'] == null ? scheme.outline : null)),
                ),
              ]),
            ),
          ),
        const SizedBox(height: Gap.m),
        Row(children: [
          Expanded(
            child: Text(l.wsShown(l.number(shown.length), l.number(rows.length)),
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
          TextButton(onPressed: page > 0 ? () => setState(() => _page = page - 1) : null, child: Text(l.fleetPrev)),
          Text('${page + 1} / $pages', style: theme.textTheme.labelMedium),
          TextButton(
              onPressed: page < pages - 1 ? () => setState(() => _page = page + 1) : null, child: Text(l.fleetNext)),
        ]),
      ]),
    );
  }

  Widget _wipPanel(BuildContext context, String title, String note, IconData icon) {
    final theme = Theme.of(context);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: title, icon: icon, trailing: WipTag(what: title, onOpen: widget.onOpen)),
        const SizedBox(height: Gap.m),
        Text(note, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ]),
    );
  }
}
