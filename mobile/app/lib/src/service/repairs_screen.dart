import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'service_data.dart';

enum _Filter { all, progress, waiting, done }

/// „Zlecenia Napraw”: lista zleceń modułu Serwis z filtrami, a po wybraniu ([orderId]) – karta
/// zlecenia według projektu Stitch: zgłoszenie, mechanik, zakres prac, części i rozliczenie,
/// historia kosztów pojazdu. Akcje (przyjęcie, protokół odbioru) – „W budowie”.
class RepairsScreen extends StatefulWidget {
  const RepairsScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.onOpen,
    required this.onOpenOrder,
    this.onOpenVehicle,
    this.onClearOrder,
    this.orderId,
    this.today,
  });

  final CoreApi api;
  final String? companyId;
  final ValueChanged<String> onOpen;
  final void Function(String id, String name) onOpenOrder;
  final void Function(String id, String name)? onOpenVehicle;

  /// Filtr kliknięty na karcie zlecenia – powrót do listy.
  final VoidCallback? onClearOrder;
  final String? orderId;
  final DateTime? today;

  @override
  State<RepairsScreen> createState() => _RepairsScreenState();
}

class _RepairsScreenState extends State<RepairsScreen> {
  FleetData? _data;
  Object? _error;
  _Filter _filter = _Filter.all;
  String _query = '';

  DateTime get _now => widget.today ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await FleetData.load(widget.api, widget.companyId);
      if (mounted) setState(() => _data = data);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  bool _match(Map<String, dynamic> o, _Filter f) => switch (f) {
        _Filter.all => true,
        _Filter.progress => o['status'] == 'accepted' || o['status'] == 'in_progress',
        _Filter.waiting => o['status'] == 'new',
        _Filter.done => o['status'] == 'done',
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final data = _data;
    if (data == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error'));
    }
    final selected = (data.orders ?? const []).where((o) => o['id'] == widget.orderId).firstOrNull;
    return LayoutBuilder(builder: (context, size) {
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final wide = size.maxWidth - 2 * pad >= 900;
      return ListView(padding: EdgeInsets.all(pad), children: [
        _header(context),
        const SizedBox(height: 20),
        _filters(context, data),
        const SizedBox(height: 20),
        if (data.orders == null)
          UiPanel(child: UiEmpty(l.vehNoServiceModule))
        else if (selected != null)
          _card(context, data, selected, wide)
        else
          _list(context, data),
      ]);
    });
  }

  Widget _header(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    Widget outlined(String label, IconData icon) => OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
              backgroundColor: colors.card,
              foregroundColor: scheme.onSurface,
              side: BorderSide(color: colors.surfaceHigh)),
          onPressed: () => widget.onOpen(label),
          icon: Icon(icon, size: 18),
          label: Text(label),
        );
    return Wrap(
      spacing: Gap.l,
      runSpacing: Gap.m,
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(l.rpTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
          outlined(l.rpBaysConfig, Icons.tune_outlined),
          outlined(l.rpPrint, Icons.print_outlined),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
            onPressed: () => widget.onOpen(l.wsNewOrder),
            icon: const Icon(Icons.add_circle_outline, size: 18),
            label: Text(l.wsNewOrder),
          ),
        ]),
      ],
    );
  }

  Widget _filters(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final orders = data.orders ?? const [];
    final today = [
      for (final o in orders)
        if (o['status'] == 'done' && DateUtils.isSameDay(day(o['completed_at']), _now)) o
    ];
    Widget chip(_Filter f, String label, int count, Color dot) {
      final selected = f == _filter && widget.orderId == null;
      return Material(
        color: selected ? scheme.primaryContainer : colors.surfaceLow,
        borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        child: InkWell(
          key: Key('rp-filter-${f.name}'),
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          onTap: () {
            setState(() => _filter = f);
            if (widget.orderId != null) widget.onClearOrder?.call();
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (f != _Filter.all) ...[
                Container(width: 7, height: 7, decoration: BoxDecoration(color: dot, shape: BoxShape.circle)),
                const SizedBox(width: 6),
              ],
              Text(label,
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: selected ? scheme.onPrimaryContainer : scheme.onSurface)),
              const SizedBox(width: Gap.s),
              Text('$count',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: selected ? scheme.onPrimaryContainer : scheme.primary)),
            ]),
          ),
        ),
      );
    }

    return UiPanel(
      child: Wrap(
        spacing: Gap.s,
        runSpacing: Gap.s,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            chip(_Filter.all, l.rpAll, orders.length, scheme.primary),
            chip(_Filter.progress, l.rpProgress, orders.where((o) => _match(o, _Filter.progress)).length,
                scheme.primary),
            chip(_Filter.waiting, l.rpWaiting, orders.where((o) => _match(o, _Filter.waiting)).length, colors.amber),
            chip(_Filter.done, l.rpDone(l.number(today.length)), orders.where((o) => _match(o, _Filter.done)).length,
                colors.success),
          ]),
          SizedBox(
            width: 280,
            child: TextField(
              key: const Key('rp-search'),
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                isDense: true,
                hintText: l.rpSearch,
                prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _list(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = _query.trim().toLowerCase();
    final rows = [
      for (final o in data.orders ?? const <Map<String, dynamic>>[])
        if (_match(o, _filter) &&
            (q.isEmpty ||
                [o['vehicle_plate'], o['vehicle_name'], o['description'], orderNo(o)]
                    .any((s) => '${s ?? ''}'.toLowerCase().contains(q))))
          o
    ];
    final date = DateFormat.yMd(l.localeName);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (rows.isEmpty) UiEmpty(l.wsNoOrders),
        for (final o in rows)
          UiBox(
            onTap: () => widget.onOpenOrder('${o['id']}', orderNo(o)),
            padding: const EdgeInsets.all(Gap.m),
            child: Row(children: [
              Expanded(
                flex: 2,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(orderNo(o),
                      key: Key('rp-row-${o['id']}'),
                      style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
                  if (day(o['created_at']) case final d?)
                    Text(date.format(d), style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                ]),
              ),
              Expanded(
                  flex: 2,
                  child: Text('${o['vehicle_plate'] ?? o['vehicle_name']}', style: theme.textTheme.labelLarge)),
              Expanded(flex: 5, child: Text('${o['description']}', style: theme.textTheme.bodySmall)),
              Expanded(
                flex: 2,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: UiTag(orderStatus(l, o['status']),
                      tone: o['status'] == 'done' ? 'ok' : (o['urgency'] == 'stopped' ? 'error' : 'info'),
                      uppercase: false),
                ),
              ),
              SizedBox(
                width: 110,
                child: Text('${l.number(orderTotal(o), decimals: 2)} ${o['currency'] ?? ''}',
                    textAlign: TextAlign.end, style: theme.textTheme.labelLarge),
              ),
            ]),
          ),
      ]),
    );
  }

  // ------------------------------------------------------------------ karta zlecenia

  Widget _card(BuildContext context, FleetData data, Map<String, dynamic> o, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final v = data.vehicle(o['vehicle_id']);
    final created = day(o['created_at']);
    final elapsed = created == null ? null : _now.difference(created);
    final vor = o['urgency'] == 'stopped';
    final time = DateFormat('dd.MM HH:mm', l.localeName);
    Widget box(Color bg, IconData icon, String title, Widget? badge, List<Widget> body) => Container(
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 18, color: scheme.primary),
              const SizedBox(width: Gap.s),
              Expanded(
                  child: Text(title.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary))),
              if (badge != null) badge,
            ]),
            const SizedBox(height: Gap.s),
            ...body,
          ]),
        );
    final small = theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final boxes = [
      box(
        vor ? scheme.errorContainer.withOpacity(0.35) : colors.surfaceLow,
        Icons.sensors_outlined,
        l.rpReport,
        vor ? UiTag(l.wsVor, tone: 'critical') : null,
        [
          Text('${o['reporter_name']} — ${o['description']}', style: theme.textTheme.bodySmall),
          const SizedBox(height: Gap.s),
          Text(created == null ? '' : l.rpReceived(time.format(created)), style: small),
        ],
      ),
      box(colors.surfaceLow, Icons.engineering_outlined, l.rpMechanic, null, [
        Row(children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: scheme.primaryContainer,
            child: Text(
                '${o['mechanic_name'] ?? '–'}'
                    .split(' ')
                    .take(2)
                    .map((p) => p.isEmpty ? '' : p[0])
                    .join()
                    .toUpperCase(),
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onPrimaryContainer)),
          ),
          const SizedBox(width: Gap.s),
          Expanded(child: Text('${o['mechanic_name'] ?? l.wsUnassigned}', style: theme.textTheme.labelLarge)),
        ]),
        const SizedBox(height: Gap.s),
        Text(
            o['labour_rate'] == null
                ? '–'
                : l.rpRate(l.number(o['labour_rate'] as num, decimals: 2), '${o['currency'] ?? ''}'),
            style: small),
      ]),
      box(colors.surfaceLow, Icons.local_shipping_outlined, l.rpPlanning,
          WipTag(what: l.rpPlanning, onOpen: widget.onOpen), [
        Text(o['odometer_km'] == null ? '–' : l.rpOdometer(l.number(o['odometer_km'] as num)), style: small),
        if (v?['inspection_until'] != null)
          Text(l.rpInspection(DateFormat.yMd(l.localeName).format(DateTime.parse('${v!['inspection_until']}'))),
              style: small),
      ]),
    ];
    final head = UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const IconSquare(icon: Icons.build_outlined, size: 44),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
                UiTag(orderNo(o), tone: 'info'),
                if (v != null) UiTag('${v['name']}', tone: 'info'),
                if (o['vehicle_plate'] != null)
                  InkWell(
                    onTap: widget.onOpenVehicle == null
                        ? null
                        : () => widget.onOpenVehicle!('${o['vehicle_id']}', '${o['vehicle_plate']}'),
                    child: UiTag('${o['vehicle_plate']}', tone: 'info', uppercase: false),
                  ),
              ]),
              const SizedBox(height: Gap.xs),
              Text(l.vehVin(v?['vin'] == null ? '–' : '${v!['vin']}'), style: small),
              Text('${o['description']}', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            ]),
          ),
          const SizedBox(width: Gap.m),
          Container(
            width: 300,
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.rpStatus.toUpperCase(), style: theme.textTheme.labelSmall),
                    Text(orderStatus(l, o['status']),
                        style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
                  ]),
                ),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.rpElapsed.toUpperCase(), style: theme.textTheme.labelSmall),
                    Text(
                        elapsed == null
                            ? '–'
                            : l.rpDuration(l.number(elapsed.inHours), l.number(elapsed.inMinutes % 60)),
                        style: theme.textTheme.labelLarge),
                  ]),
                ),
              ]),
              const SizedBox(height: Gap.s),
              Row(children: [
                Expanded(child: TruckProgressBar(value: orderProgress(o['status']), height: 6)),
                const SizedBox(width: Gap.s),
                Text('${(orderProgress(o['status']) * 100).round()}%', style: theme.textTheme.labelMedium),
              ]),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.l),
        if (wide)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, b) in boxes.indexed) ...[if (i > 0) const SizedBox(width: Gap.m), Expanded(child: b)],
            ]),
          )
        else
          for (final b in boxes) Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: b),
      ]),
    );
    final work = _work(context, o);
    final parts = _parts(context, o);
    final history = _history(context, data, o, wide);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      head,
      const SizedBox(height: 20),
      if (wide)
        IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: work),
            const SizedBox(width: 20),
            Expanded(child: parts),
          ]),
        )
      else ...[
        work,
        const SizedBox(height: 20),
        parts,
      ],
      const SizedBox(height: 20),
      history,
      const SizedBox(height: 20),
      _closing(context),
    ]);
  }

  Widget _work(BuildContext context, Map<String, dynamic> o) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final work = '${o['work_done'] ?? ''}';
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.checklist_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: Gap.s),
          Expanded(
              child: Text(l.rpWorkTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: Gap.l),
        Container(
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(work.isEmpty ? Icons.radio_button_unchecked : Icons.check_circle_outline,
                color: work.isEmpty ? scheme.outline : colors.success),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(l.rpWorkDone, style: theme.textTheme.labelLarge),
                const SizedBox(height: Gap.xs),
                Text(work.isEmpty ? l.rpWorkNone : work,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
          ]),
        ),
        const SizedBox(height: Gap.m),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Expanded(child: Text(l.rpChecklist, style: theme.textTheme.bodySmall)),
            WipTag(what: l.rpChecklist, onOpen: widget.onOpen),
          ]),
        ),
      ]),
    );
  }

  Widget _parts(BuildContext context, Map<String, dynamic> o) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final currency = '${o['currency'] ?? ''}';
    final head = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    String money(num v) => '${l.number(v, decimals: 2)} $currency';
    Widget row(String name, String qty, num? price, num sum, {String? sub}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.s),
          child: Row(children: [
            Expanded(
              flex: 5,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(name, style: theme.textTheme.labelLarge),
                if (sub != null) Text(sub, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
              ]),
            ),
            Expanded(flex: 2, child: Text(qty, textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
            Expanded(
                flex: 2,
                child: Text(price == null ? '–' : l.number(price, decimals: 2),
                    textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
            Expanded(flex: 3, child: Text(money(sum), textAlign: TextAlign.end, style: theme.textTheme.labelLarge)),
          ]),
        );
    final parts = uiMaps(o['parts']);
    final net = orderTotal(o);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.receipt_long_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: Gap.s),
          Expanded(
              child: Text(l.rpPartsTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
        ]),
        const SizedBox(height: Gap.l),
        Container(
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Column(children: [
            Row(children: [
              Expanded(flex: 5, child: Text(l.rpColItem.toUpperCase(), style: head)),
              Expanded(flex: 2, child: Text(l.rpColQty.toUpperCase(), textAlign: TextAlign.end, style: head)),
              Expanded(flex: 2, child: Text(l.rpColPrice.toUpperCase(), textAlign: TextAlign.end, style: head)),
              Expanded(flex: 3, child: Text(l.rpColSum.toUpperCase(), textAlign: TextAlign.end, style: head)),
            ]),
            const Divider(),
            if (parts.isEmpty && o['labour_hours'] == null) UiEmpty(l.rpNoParts),
            for (final p in parts)
              row('${p['name']}', l.number(p['quantity'] as num? ?? 1, decimals: 2), p['price'] as num?,
                  ((p['price'] as num?) ?? 0) * ((p['quantity'] as num?) ?? 1)),
            if (o['labour_hours'] != null)
              row(l.rpLabour, l.rpHours(l.number(o['labour_hours'] as num, decimals: 1)), o['labour_rate'] as num?,
                  labourTotal(o)),
            const Divider(),
            Row(children: [
              Expanded(child: Text(l.rpPartsSum, style: theme.textTheme.bodySmall)),
              Text(money(partsTotal(o)), style: theme.textTheme.bodySmall),
            ]),
            Row(children: [
              Expanded(child: Text(l.rpLabourSum, style: theme.textTheme.bodySmall)),
              Text(money(labourTotal(o)), style: theme.textTheme.bodySmall),
            ]),
            const SizedBox(height: Gap.s),
            Row(children: [
              Expanded(child: Text(l.rpNet, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
              Text(money(net),
                  style: theme.textTheme.titleLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
            ]),
            Align(
              alignment: Alignment.centerRight,
              child: Text(l.rpGross(money(net * 1.23)),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
            ),
          ]),
        ),
        const SizedBox(height: Gap.m),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: colors.surfaceLow, foregroundColor: scheme.primary),
          onPressed: () => widget.onOpen(l.rpRequest),
          icon: const Icon(Icons.add_shopping_cart_outlined, size: 18),
          label: Text(l.rpRequest),
        ),
      ]),
    );
  }

  Widget _history(BuildContext context, FleetData data, Map<String, dynamic> o, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final own = [
      for (final x in data.orders ?? const <Map<String, dynamic>>[])
        if (x['vehicle_id'] == o['vehicle_id']) x
    ];
    final months = [for (var i = 11; i >= 0; i--) DateTime(_now.year, _now.month - i)];
    double sum(DateTime m, bool urgent) => own
        .where((x) =>
            x['status'] == 'done' &&
            (x['urgency'] == 'stopped') == urgent &&
            day(x['completed_at']) != null &&
            day(x['completed_at'])!.year == m.year &&
            day(x['completed_at'])!.month == m.month)
        .fold(0.0, (a, x) => a + orderTotal(x));
    final total = own.where((x) => x['status'] == 'done').fold(0.0, (a, x) => a + orderTotal(x));
    final previous = [
      for (final x in own)
        if (x['status'] == 'done' && x['id'] != o['id']) x
    ];
    final label = DateFormat.MMM(l.localeName);
    final date = DateFormat.yMd(l.localeName);
    final chart = Container(
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text(l.rpChartTitle, style: theme.textTheme.labelLarge)),
          _legend(context, scheme.primaryContainer, l.rpPlanned),
          const SizedBox(width: Gap.m),
          _legend(context, scheme.error, l.rpUrgent),
        ]),
        const SizedBox(height: Gap.m),
        MiniBars(
          labels: [for (final m in months) label.format(m)],
          series: [
            (scheme.primaryContainer, [for (final m in months) sum(m, false)]),
            (scheme.error, [for (final m in months) sum(m, true)]),
          ],
        ),
        const SizedBox(height: Gap.s),
        Text(
            l.rpAvgCost(previous.isEmpty && own.where((x) => x['status'] == 'done').isEmpty
                ? '–'
                : l.number(total / own.where((x) => x['status'] == 'done').length, decimals: 0)),
            style: theme.textTheme.labelMedium),
      ]),
    );
    final list = Container(
      padding: const EdgeInsets.all(Gap.m),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.rpPrevious, style: theme.textTheme.labelLarge),
        const SizedBox(height: Gap.s),
        if (previous.isEmpty) UiEmpty(l.rpNoPrevious),
        for (final x in previous.take(3))
          Container(
            margin: const EdgeInsets.only(bottom: Gap.s),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(
                      '${orderNo(x)}  •  ${day(x['completed_at']) == null ? '' : date.format(day(x['completed_at'])!)}',
                      style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
                  Text('${x['description']}', style: theme.textTheme.labelLarge),
                  Text(
                      [
                        if (x['work_done'] != null) '${x['work_done']}',
                        '${l.number(orderTotal(x), decimals: 0)} ${x['currency'] ?? ''}'
                      ].join(' • '),
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              const UiTag('OK', tone: 'ok'),
            ]),
          ),
      ]),
    );
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.history_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(l.rpHistoryTitle('${o['vehicle_plate'] ?? o['vehicle_name']}'),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(l.rpHistoryTotal(l.number(total, decimals: 0)), style: theme.textTheme.labelMedium),
        ]),
        const SizedBox(height: Gap.l),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 3, child: chart),
            const SizedBox(width: Gap.l),
            Expanded(flex: 2, child: list),
          ])
        else ...[
          chart,
          const SizedBox(height: Gap.m),
          list,
        ],
      ]),
    );
  }

  Widget _legend(BuildContext context, Color color, String label) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.labelSmall),
      ]);

  Widget _closing(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: Gap.m,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Row(children: [
              Icon(Icons.assignment_turned_in_outlined, color: scheme.primary),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(l.rpProtocol, style: theme.textTheme.labelLarge),
                  Text(l.rpProtocolNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
            ]),
          ),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            OutlinedButton.icon(
              onPressed: () => widget.onOpen(l.rpAddItem),
              icon: const Icon(Icons.add_circle_outline, size: 18),
              label: Text(l.rpAddItem),
            ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.tertiaryContainer),
              onPressed: () => widget.onOpen(l.rpApprove),
              icon: const Icon(Icons.verified_outlined, size: 18),
              label: Text(l.rpApprove),
            ),
          ]),
        ],
      ),
    );
  }
}
