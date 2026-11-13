import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import '../vehicles/body_types.dart';
import 'fleet_screen.dart' show FleetStatus, fleetStatus;

const towedKinds = {'semitrailer', 'trailer'};

DateTime? _day(dynamic s) => s == null ? null : DateTime.tryParse('$s');

/// Profil pojazdu według projektu Stitch: dane z `/api/vehicles` (karta pojazdu, naczepa, kierowca,
/// terminy, masy i osie), statystyki przejazdów i zlecenia modułu Serwis; telemetria CAN, TPMS,
/// paliwo, pozycja GNSS – „W budowie”.
class VehicleScreen extends StatefulWidget {
  const VehicleScreen({
    super.key,
    required this.api,
    required this.vehicleId,
    required this.onOpen,
    required this.onEdit,
    required this.onOpenVehicle,
    this.onOpenDriver,
    this.onSection,
    this.today,
  });

  final CoreApi api;
  final String vehicleId;
  final ValueChanged<String> onOpen;

  /// Inny ekran aplikacji: `repairs` (zlecenie serwisowe, historia), `live` (pozycja pojazdu).
  final ValueChanged<String>? onSection;
  final void Function(String id, String name) onEdit;
  final void Function(String id, String name) onOpenVehicle;
  final ValueChanged<String>? onOpenDriver;
  final DateTime? today;

  @override
  State<VehicleScreen> createState() => _VehicleScreenState();
}

class _VehicleScreenState extends State<VehicleScreen> {
  List<Map<String, dynamic>>? _all;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>>? _orders;
  Object? _error;

  /// Ostatnia pozycja z Centrali & Live Map (tylko dla właściciela i dyspozytorów).
  Map<String, dynamic>? _live;

  DateTime get _today {
    final t = widget.today ?? DateTime.now();
    return DateTime(t.year, t.month, t.day);
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(VehicleScreen old) {
    super.didUpdateWidget(old);
    if (old.vehicleId != widget.vehicleId) _load();
  }

  Future<void> _load() async {
    final id = Uri.encodeComponent(widget.vehicleId);
    Future<dynamic> optional(String path) async {
      try {
        return await widget.api.get(path);
      } catch (_) {
        return null;
      }
    }

    try {
      final results = await Future.wait([
        widget.api.get('/api/vehicles'),
        optional('/api/vehicles/$id/stats?months=12'),
        optional('/api/m/service/orders?vehicle_id=$id'),
      ]);
      if (!mounted) return;
      setState(() {
        _all = uiMaps(results[0]);
        _stats = results[1] is Map<String, dynamic> ? results[1] as Map<String, dynamic> : null;
        _orders = results[2] is List ? uiMaps(results[2]) : null;
        _error = null;
      });
      final company = _all?.where((v) => v['id'] == widget.vehicleId).firstOrNull?['company_id'];
      if (company != null) {
        final live = await optional('/api/companies/${Uri.encodeComponent('$company')}/live');
        if (mounted && live is List) {
          setState(() => _live = uiMaps(live).where((p) => p['vehicle_id'] == widget.vehicleId).firstOrNull);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic>? get _v => _all?.where((v) => v['id'] == widget.vehicleId).firstOrNull;

  Map<String, dynamic>? get _trailer {
    final v = _v;
    if (v == null) return null;
    if (towedKinds.contains(v['kind'])) {
      return _all!.where((t) => t['id'] == v['coupled_to_id']).firstOrNull;
    }
    return _all!.where((t) => t['id'] == v['trailer_id']).firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (_all == null) {
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
    final v = _v;
    if (v == null) return Center(child: UiEmpty(l.vehNotFound));
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final wide = size.maxWidth - 2 * pad >= 900;
      final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _axles(context, v),
        const SizedBox(height: gap),
        _service(context, v, wide),
      ]);
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _compliance(context, v),
        const SizedBox(height: gap),
        _position(context),
      ]);
      return ListView(padding: EdgeInsets.all(pad), children: [
        _head(context, v, wide),
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

  // ------------------------------------------------------------------ nagłówek

  Widget _head(BuildContext context, Map<String, dynamic> v, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final status = fleetStatus(v);
    final trailer = _trailer;
    final towed = towedKinds.contains(v['kind']);
    final (String statusText, Color bg, Color fg) = switch (status) {
      FleetStatus.driving => (l.vehStatusDriving, const Color(0xFF85F8C4), const Color(0xFF00563A)),
      FleetStatus.ready => (l.fleetStatusReady, scheme.secondaryContainer, scheme.onSecondaryContainer),
      FleetStatus.service => (l.fleetStatusService, scheme.errorContainer, scheme.onErrorContainer),
      FleetStatus.reported => (l.fleetStatusReported, scheme.errorContainer, scheme.onErrorContainer),
    };
    final euro = switch (v['emission_class']) {
      'euro6' => 'Euro 6',
      'euro5' => 'Euro 5',
      'euro4' => 'Euro 4',
      'euro3' => 'Euro 3',
      'electric' => 'EV',
      _ => null,
    };
    final driver = (v['driver_name'] ?? v['assigned_driver_name']) as String?;
    Widget button(String label, IconData icon, {bool primary = false, VoidCallback? onTap}) => primary
        ? FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
            onPressed: onTap ?? () => widget.onOpen(label),
            icon: Icon(icon, size: 18),
            label: Text(label),
          )
        : OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
                backgroundColor: colors.card,
                foregroundColor: scheme.onSurface,
                side: BorderSide(color: colors.surfaceHigh)),
            onPressed: onTap ?? () => widget.onOpen(label),
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
    final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Gap.m, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text('${v['plate'] ?? v['name']}',
            style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
          child: Text(statusText.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: fg)),
        ),
      ]),
      if (euro != null) ...[const SizedBox(height: Gap.xs), UiTag(euro, tone: 'info', uppercase: false)],
      const SizedBox(height: Gap.xs),
      Text(
          [
            '${v['name']}',
            if (v['production_year'] != null) l.vehYear('${v['production_year']}'),
          ].join(' '),
          style: theme.textTheme.bodyMedium),
      Text(l.vehVin(v['vin'] == null ? '–' : '${v['vin']}'),
          style: theme.textTheme.labelLarge?.copyWith(letterSpacing: 0.5)),
      const SizedBox(height: Gap.xs),
      Row(children: [
        Icon(Icons.navigation_outlined, size: 14, color: scheme.primary),
        const SizedBox(width: 4),
        if (_live case final live? when live['lat'] != null)
          InkWell(
            key: const Key('vehicle-position'),
            onTap: widget.onSection == null ? null : () => widget.onSection!('live'),
            child: Text(
                [
                  switch (live['state']) {
                    'driving' => l.liveStateDriving,
                    'stopped' => l.liveStateStopped,
                    _ => l.liveStateNoSignal,
                  },
                  if (live['speed_kmh'] is num) '${(live['speed_kmh'] as num).round()} km/h',
                  '${(live['lat'] as num).toStringAsFixed(4)}, ${(live['lon'] as num).toStringAsFixed(4)}',
                ].join(' · '),
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
          )
        else
          Text(l.vehNoPosition, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
      ]),
    ]);
    final buttons = Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
      button(l.drvEditShort, Icons.edit_outlined,
          onTap: () => widget.onEdit('${v['id']}', '${v['plate'] ?? v['name']}')),
      button(l.vehOrderService, Icons.car_repair_outlined,
          onTap: widget.onSection == null ? null : () => widget.onSection!('repairs')),
      button(l.vehDtc, Icons.sensors_outlined),
      button(l.vehFms, Icons.download_outlined, primary: true),
    ]);
    final photo = Container(
      width: 120,
      height: 88,
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Stack(children: [
        Center(
            child: Icon(towed ? Icons.rv_hookup_outlined : Icons.local_shipping_outlined,
                size: 44, color: scheme.primary.withOpacity(0.6))),
        Positioned(right: 6, bottom: 6, child: WipTag(what: l.drvPhoto, onOpen: widget.onOpen)),
      ]),
    );
    Widget person(IconData icon, String label, Widget main, String sub, Widget? chip) => Expanded(
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration:
                  BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
              child: Icon(icon, size: 18, color: scheme.primary),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4)),
                main,
                if (sub.isNotEmpty)
                  Text(sub, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
            ),
            if (chip != null) chip,
          ]),
        );
    final link = theme.textTheme.titleSmall?.copyWith(color: scheme.primary);
    final people = UiBox(
      padding: const EdgeInsets.all(Gap.m),
      child: Flex(direction: wide ? Axis.horizontal : Axis.vertical, children: [
        if (!towed)
          person(
            Icons.person_outline,
            l.vehDriver,
            driver == null
                ? Text(l.fleetNoDriver, style: theme.textTheme.titleSmall)
                : InkWell(
                    key: const Key('veh-driver'),
                    onTap: widget.onOpenDriver == null ? null : () => widget.onOpenDriver!(driver),
                    child: Text(driver, style: link)),
            '',
            status == FleetStatus.driving
                ? UiTag(l.vehDriving, tone: 'ok', uppercase: false)
                : WipTag(what: l.vehTacho, onOpen: widget.onOpen),
          ),
        if (wide) const SizedBox(width: Gap.l) else const SizedBox(height: Gap.m),
        person(
          towed ? Icons.local_shipping_outlined : Icons.rv_hookup_outlined,
          towed ? l.vehCoupledTo : l.vehTrailer,
          trailer == null
              ? Text('–', style: theme.textTheme.titleSmall)
              : InkWell(
                  key: const Key('veh-trailer'),
                  onTap: () => widget.onOpenVehicle('${trailer['id']}', '${trailer['plate'] ?? trailer['name']}'),
                  child: Text('${trailer['name']}', style: link)),
          trailer == null
              ? ''
              : [
                  if (trailer['plate'] != null) l.vehPlate('${trailer['plate']}'),
                  if (_trailerType(l, trailer['trailer_type']) case final t?) t,
                ].join(' • '),
          null,
        ),
      ]),
    );
    final odometer = v['odometer_km'] as num?;
    final km = _stats?['distance_km'] as num?;
    Widget tile(String label, IconData icon, Widget value, Widget foot, {double? bar, Color? barColor}) => Expanded(
          child: Container(
            margin: const EdgeInsets.only(bottom: Gap.s),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                    child: Text(label.toUpperCase(),
                        style:
                            theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4))),
                Icon(icon, size: 16, color: scheme.onSurfaceVariant),
              ]),
              const SizedBox(height: Gap.s),
              value,
              const SizedBox(height: Gap.xs),
              if (bar != null) ...[
                TruckProgressBar(value: bar, height: 6, color: barColor),
                const SizedBox(height: Gap.xs),
              ],
              DefaultTextStyle.merge(
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                  child: Align(alignment: Alignment.centerLeft, child: foot)),
            ]),
          ),
        );
    final big = theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700);
    final service = status == FleetStatus.service || status == FleetStatus.reported;
    final tiles = [
      tile(
        l.vehOdometer,
        Icons.speed_outlined,
        Text.rich(TextSpan(children: [
          TextSpan(text: odometer == null ? '–' : l.number(odometer), style: big),
          TextSpan(text: ' km', style: theme.textTheme.bodySmall),
        ])),
        Text(km == null ? '–' : l.vehAvgDay(l.number(km / 365, decimals: 0))),
      ),
      tile(l.vehFuel, Icons.local_gas_station_outlined, Text('–', style: big),
          WipTag(what: l.vehFuel, onOpen: widget.onOpen)),
      tile(l.vehAdblue, Icons.water_drop_outlined, Text('–', style: big),
          WipTag(what: l.vehAdblue, onOpen: widget.onOpen)),
      tile(
        l.vehTechStatus,
        Icons.verified_outlined,
        Text(service ? l.fleetStatusService : l.vehOk,
            style: big?.copyWith(color: service ? scheme.error : colors.success)),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text('${l.vehDtcCodes} '),
          WipTag(what: l.vehDtcCodes, onOpen: widget.onOpen),
        ]),
      ),
    ];
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          photo,
          const SizedBox(width: 20),
          Expanded(
            child: wide
                ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: title),
                    const SizedBox(width: Gap.l),
                    Flexible(child: buttons),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    title,
                    const SizedBox(height: Gap.m),
                    buttons,
                  ]),
          ),
        ]),
        const SizedBox(height: Gap.l),
        people,
        const SizedBox(height: Gap.s),
        if (wide)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, t) in tiles.indexed) ...[if (i > 0) const SizedBox(width: Gap.m), t],
          ])
        else
          for (final t in tiles) Row(children: [t]),
      ]),
    );
  }

  String? _trailerType(AppLocalizations l, dynamic type) =>
      type == null || type == 'none' ? null : bodyLabel(l, '$type');

  // ------------------------------------------------------------------ układ jezdny

  Widget _axles(BuildContext context, Map<String, dynamic> v) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final trailer = _trailer;
    final towed = towedKinds.contains(v['kind']);
    final tractor = towed ? trailer : v;
    final semi = towed ? v : trailer;
    Widget unit(String tag, Map<String, dynamic>? u, {bool dark = false}) {
      if (u == null) return const SizedBox();
      final axles = (u['axle_count'] as num?)?.toInt() ?? 0;
      final load = u['axle_load_t'] as num?;
      return Container(
        margin: const EdgeInsets.only(bottom: Gap.m),
        padding: const EdgeInsets.all(Gap.m),
        decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(TruckTheme.radius)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
              decoration: BoxDecoration(
                  color: dark ? scheme.onSurfaceVariant : scheme.primary,
                  borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
              child: Text(tag.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: Colors.white)),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
                child: Text('${u['name']}${u['plate'] == null ? '' : ' (${u['plate']})'}',
                    style: theme.textTheme.labelLarge)),
            Text(
                l.vehAxleSummary(l.number(axles), load == null ? '–' : l.number(load, decimals: 1),
                    l.number(u['gvw_t'] as num? ?? 0, decimals: 1)),
                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: Gap.s),
          for (var i = 1; i <= axles; i++)
            Container(
              margin: const EdgeInsets.only(top: Gap.xs),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
              decoration:
                  BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
              child: Row(children: [
                Text(l.vehAxle(l.number(i)), style: theme.textTheme.labelMedium),
                const SizedBox(width: Gap.l),
                Expanded(
                  child: Text(load == null ? '' : l.vehAxleLimit(l.number(load, decimals: 1)),
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ),
                Text(l.vehTpms, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                const SizedBox(width: Gap.xs),
                WipTag(what: l.vehTpms, onOpen: widget.onOpen),
              ]),
            ),
        ]),
      );
    }

    final tare = [(tractor?['tare_t'] as num?), (semi?['tare_t'] as num?)].whereType<num>();
    final tareSum = tare.isEmpty ? null : tare.reduce((a, b) => a + b);
    final limit = (tractor?['weight_t'] as num?) ?? (tractor?['gvw_t'] as num?);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.vehAxlesTitle,
          subtitle: l.vehAxlesSubtitle,
          icon: Icons.tire_repair_outlined,
          trailing: WipTag(what: l.vehTpms, onOpen: widget.onOpen),
        ),
        const SizedBox(height: Gap.l),
        Container(
          padding: const EdgeInsets.all(Gap.m),
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            unit(l.vehUnitTractor, tractor),
            unit(l.vehUnitTrailer, semi, dark: true),
            if (tractor == null && semi == null) UiEmpty(l.vehNoUnits),
            Container(
              padding: const EdgeInsets.all(Gap.m),
              decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(TruckTheme.radius)),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(l.vehMassTitle.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                    Text.rich(TextSpan(children: [
                      TextSpan(
                          text: tareSum == null ? '–' : '${l.number(tareSum, decimals: 2)} t',
                          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      TextSpan(
                          text: limit == null ? '' : ' ${l.vehMassLimit(l.number(limit, decimals: 1))}',
                          style: theme.textTheme.bodySmall),
                    ])),
                  ]),
                ),
                const SizedBox(width: Gap.l),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Text(l.vehMassUse, style: theme.textTheme.bodySmall),
                    const SizedBox(height: Gap.xs),
                    TruckProgressBar(
                        value: tareSum == null || limit == null || limit == 0 ? 0 : tareSum / limit, height: 6),
                    const SizedBox(height: Gap.xs),
                    Text(l.vehMassNote, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ]),
    );
  }

  // ------------------------------------------------------------------ eksploatacja i serwis

  Widget _service(BuildContext context, Map<String, dynamic> v, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final odometer = v['odometer_km'] as num?;
    final due = v['service_due_km'] as num?;
    final left = odometer == null || due == null ? null : due - odometer;
    final orders = _orders;
    final next = Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(l.vehNextService.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.m),
        Row(children: [
          SizedBox(
            width: 72,
            height: 72,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(
                value: left == null ? 0 : (left <= 0 ? 1 : 0.5),
                strokeWidth: 7,
                color: left != null && left <= 0 ? scheme.error : scheme.primaryContainer,
                backgroundColor: colors.surfaceHigh,
              ),
              Icon(Icons.oil_barrel_outlined, color: scheme.primary),
            ]),
          ),
          const SizedBox(width: Gap.l),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                  left == null ? '–' : (left <= 0 ? l.vehServiceOver(l.number(-left)) : l.vehServiceIn(l.number(left))),
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w700, color: left != null && left <= 0 ? scheme.error : null)),
              Text(due == null ? l.vehServiceNone : l.vehServiceAt(l.number(due)),
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
        const SizedBox(height: Gap.l),
        Row(children: [
          Expanded(child: Text(l.vehBrakes, style: theme.textTheme.labelMedium)),
          WipTag(what: l.vehBrakes, onOpen: widget.onOpen),
        ]),
      ]),
    );
    final format = DateFormat.yMd(l.localeName);
    final book = Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
              child: Text(l.vehServiceBook.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant))),
          TextButton(
              onPressed: () =>
                  widget.onSection != null ? widget.onSection!('repairs') : widget.onOpen(l.vehServiceHistory),
              child: Text(l.vehServiceHistory)),
        ]),
        if (orders == null)
          Row(children: [
            Expanded(child: Text(l.vehNoServiceModule, style: theme.textTheme.bodySmall)),
            WipTag(what: l.vehServiceBook, onOpen: widget.onOpen)
          ]),
        if (orders != null && orders.isEmpty) UiEmpty(l.vehNoOrders),
        for (final o in (orders ?? const <Map<String, dynamic>>[]).take(3))
          Container(
            margin: const EdgeInsets.only(top: Gap.s),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: colors.card, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(o['status'] == 'done' ? Icons.check_circle_outline : Icons.build_circle_outlined,
                  size: 20, color: o['status'] == 'done' ? colors.success : colors.warning),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${o['description']}', style: theme.textTheme.labelLarge),
                  if ('${o['work_done'] ?? ''}'.isNotEmpty)
                    Text('${o['work_done']}',
                        style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  if (o['mechanic_name'] != null)
                    Text('${o['mechanic_name']}', style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                ]),
              ),
              if (_day(o['created_at']) case final d?)
                Text(format.format(d.toLocal()), style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
            ]),
          ),
      ]),
    );
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.vehServiceTitle,
          subtitle: [
            if (v['fuel_type'] != null) l.vehFuelType(_fuel(l, v['fuel_type'])),
            if (v['consumption_loaded'] != null)
              l.fleetConsumption(l.number(v['consumption_loaded'] as num, decimals: 1)),
          ].join(' • '),
          icon: Icons.engineering_outlined,
        ),
        const SizedBox(height: Gap.l),
        if (wide)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: next),
              const SizedBox(width: Gap.l),
              Expanded(child: book),
            ]),
          )
        else ...[
          next,
          const SizedBox(height: Gap.l),
          book,
        ],
      ]),
    );
  }

  String _fuel(AppLocalizations l, dynamic fuel) => switch (fuel) {
        'diesel' => l.vehFuelDiesel,
        'lng' => 'LNG',
        'cng' => 'CNG',
        'electric' => l.vehFuelElectric,
        _ => '$fuel',
      };

  // ------------------------------------------------------------------ prawa kolumna

  Widget _compliance(BuildContext context, Map<String, dynamic> v) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final format = DateFormat.yMd(l.localeName);
    Widget item(String title, String field, String note) {
      final day = _day(v[field]);
      final days = day?.difference(_today).inDays;
      final late = days != null && days < 0;
      final soon = days != null && !late && days <= 30;
      return UiBox(
        padding: const EdgeInsets.all(Gap.m),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
                child: Text(title.toUpperCase(),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4))),
            if (days != null)
              UiTag(late ? l.vehOverdue : l.vehDaysLeft(l.number(days)),
                  tone: late ? 'critical' : (soon ? 'error' : 'ok'), uppercase: false),
          ]),
          const SizedBox(height: Gap.xs),
          Text(day == null ? '–' : l.vehValidUntil(format.format(day)),
              style: theme.textTheme.titleSmall?.copyWith(fontSize: 15, color: late ? scheme.error : null)),
          if (note.isNotEmpty) Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      );
    }

    final towed = towedKinds.contains(v['kind']);
    final euro = v['emission_class'] == null ? '–' : '${v['emission_class']}'.replaceAll('euro', 'Euro ');
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.verified_user_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: Gap.s),
          Expanded(
              child: Text(l.vehComplianceTitle,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          Container(
              width: 8, height: 8, decoration: BoxDecoration(color: scheme.tertiaryContainer, shape: BoxShape.circle)),
        ]),
        const SizedBox(height: Gap.l),
        item(l.vehSkp, 'inspection_until',
            v['last_inspection'] == null ? '' : l.vehLastInspection(format.format(_day(v['last_inspection'])!))),
        item(l.vehPolicy, 'insurance_until',
            _day(v['ac_until']) == null ? '' : l.vehAcUntil(format.format(_day(v['ac_until'])!))),
        if (!towed) item(l.vehTachograph, 'tachograph_until', ''),
        if (v['atp_until'] != null) item(l.vehAtp, 'atp_until', ''),
        if (v['adr_until'] != null) item(l.vehAdr, 'adr_until', ''),
        if (v['udt_until'] != null) item(l.vehUdt, 'udt_until', ''),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.vehEco.toUpperCase(),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4)),
            const SizedBox(height: Gap.xs),
            Text([euro, if (v['co2_class'] != null) l.vehCo2('${v['co2_class']}')].join(' • '),
                style: theme.textTheme.titleSmall?.copyWith(fontSize: 15)),
          ]),
        ),
      ]),
    );
  }

  Widget _position(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.location_on_outlined, size: 20, color: scheme.primary),
          const SizedBox(width: Gap.s),
          Expanded(
              child:
                  Text(l.vehPositionTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
          WipTag(what: l.vehPositionTitle, onOpen: widget.onOpen),
        ]),
        const SizedBox(height: Gap.m),
        Container(
          height: 150,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
          child: Icon(Icons.satellite_alt_outlined, size: 40, color: scheme.outline),
        ),
        const SizedBox(height: Gap.m),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Expanded(child: Text(l.vehCurrentOrder, style: theme.textTheme.labelLarge)),
            WipTag(what: l.vehCurrentOrder, onOpen: widget.onOpen),
          ]),
        ),
      ]),
    );
  }
}
