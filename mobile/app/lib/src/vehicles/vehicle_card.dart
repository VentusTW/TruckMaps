import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import 'permits_screen.dart';
import 'service_dates.dart';
import 'vehicle_actions.dart';
import 'vehicle_form.dart';
import 'vehicle_state.dart';
import 'vehicle_stats.dart';

/// Karta pojazdu w jednym miejscu: dane, terminy, kierowca, naczepa, zezwolenia, statystyki
/// i sekcje modułów (np. usterki i koszty napraw z Serwisu, kierowcy, plan załadunku).
/// Szybkie akcje na górze – bez szukania ich w menu.
class VehicleCardScreen extends StatefulWidget {
  const VehicleCardScreen({
    super.key,
    required this.api,
    required this.vehicle,
    this.sections = const [],
    this.actions = const [],
    this.onChanged,
    this.onPlanRoute,
  });

  final CoreApi api;

  /// Pojazd z listy – karta pokazuje go od razu i pobiera świeże dane.
  final Map<String, dynamic> vehicle;

  /// Sekcje i akcje modułów z dostępem.
  final List<VehicleSection> sections;
  final List<VehicleAction> actions;

  /// Po zmianie pojazdu (lista i planer odświeżają dane).
  final VoidCallback? onChanged;

  /// „Zaplanuj trasę” tym pojazdem (tylko pojazdy z napędem).
  final ValueChanged<Map<String, dynamic>>? onPlanRoute;

  @override
  State<VehicleCardScreen> createState() => _VehicleCardScreenState();
}

class _VehicleCardScreenState extends State<VehicleCardScreen> {
  late Map<String, dynamic> _vehicle = widget.vehicle;
  List<Map<String, dynamic>> _all = const [];

  /// Wersja danych – sekcje (też modułów) budują się od nowa i pobierają dane po zmianie.
  int _version = 0;

  String get _id => '${widget.vehicle['id']}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = (await widget.api.get('/api/vehicles') as List<dynamic>).cast<Map<String, dynamic>>();
      if (!mounted) return;
      final fresh = all.where((v) => '${v['id']}' == _id).firstOrNull;
      // Pojazd usunięty (np. na innym urządzeniu) – karta nie ma czego pokazać.
      if (fresh == null) return Navigator.of(context).pop();
      setState(() {
        _all = all;
        _vehicle = fresh;
      });
    } catch (_) {
      // Bez sieci karta zostaje z danymi z listy.
    }
  }

  Future<void> _after(Future<bool> action) async {
    if (!await action || !mounted) return;
    widget.onChanged?.call();
    setState(() => _version++);
    await _load();
  }

  Future<void> _delete() async {
    final navigator = Navigator.of(context);
    if (!await deleteVehicle(context, widget.api, _vehicle) || !mounted) return;
    widget.onChanged?.call();
    navigator.pop(true);
  }

  Future<bool> _addPermit() async {
    final saved = await Navigator.of(context).push<dynamic>(MaterialPageRoute(
      builder: (_) => PermitFormScreen(api: widget.api, vehicleIds: [_id]),
    ));
    return saved != null;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = _vehicle;
    final editable = v['can_edit'] != false;
    final service = v['can_service'] == true;
    final drivable = isDrivable(v);
    final moduleActions = [
      for (final a in widget.actions)
        if (a.applies?.call(v) ?? true) a
    ];
    final moduleSections = [
      for (final s in widget.sections)
        if (s.applies?.call(v) ?? true) s
    ]..sort((a, b) => a.order.compareTo(b.order));

    Widget action(IconData icon, String label, VoidCallback onPressed, {Key? key}) => ActionChip(
          key: key,
          avatar: Icon(icon, size: 18),
          label: Text(label),
          onPressed: onPressed,
        );

    final quick = [
      if (drivable && widget.onPlanRoute != null)
        action(Icons.route_outlined, l.planRoute, () {
          Navigator.of(context).pop();
          widget.onPlanRoute!(v);
        }, key: const Key('card-plan-route')),
      if (service)
        action(
            Icons.event_note_outlined, l.vehicleServiceAction, () => _after(openServiceDates(context, widget.api, v))),
      if (canAssignDriver(v))
        action(Icons.person_pin_outlined, l.vehicleDriverAction, () => _after(assignDriver(context, widget.api, v))),
      for (final a in moduleActions)
        action(a.icon, a.label, () => _after(a.run(context, v)), key: Key('card-action-${a.id}')),
      if (editable) action(Icons.verified_outlined, l.permitAdd, () => _after(_addPermit())),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(vehicleTitle(v)),
        actions: [
          if (editable)
            IconButton(
              tooltip: l.edit,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _after(openVehicleForm(context, widget.api, v)),
            ),
          if (editable)
            PopupMenuButton<String>(
              onSelected: (_) => _delete(),
              itemBuilder: (context) => [PopupMenuItem(value: 'delete', child: Text(l.delete))],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          setState(() => _version++);
          await _load();
        },
        child: LayoutBuilder(builder: (context, size) {
          final sections = <Widget>[
            _Header(vehicle: v),
            if (quick.isNotEmpty) Wrap(spacing: Gap.s, runSpacing: Gap.s, children: quick),
            _DatesSection(vehicle: v, onEdit: service ? () => _after(openServiceDates(context, widget.api, v)) : null),
            _CrewSection(
              api: widget.api,
              vehicle: v,
              all: _all,
              onChanged: (action) => _after(action),
            ),
            KeyedSubtree(key: ValueKey(('permits', _version)), child: _PermitsSection(api: widget.api, vehicle: v)),
            if (drivable || towedKinds.contains(v['kind']))
              KeyedSubtree(key: ValueKey(('stats', _version)), child: _StatsSection(api: widget.api, vehicle: v)),
            for (final s in moduleSections)
              KeyedSubtree(
                  key: ValueKey((s.id, _version)), child: Builder(builder: (context) => s.builder(context, v))),
          ];
          final padded = [for (final s in sections) Padding(padding: const EdgeInsets.only(bottom: Gap.m), child: s)];
          // Szeroki ekran: nagłówek i akcje na całą szerokość, sekcje w dwóch kolumnach.
          if (size.maxWidth >= 1000) {
            final rest = padded.sublist(2);
            return ListView(padding: const EdgeInsets.all(Gap.l), children: [
              ...padded.take(2),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(children: [for (var i = 0; i < rest.length; i += 2) rest[i]])),
                const SizedBox(width: Gap.m),
                Expanded(child: Column(children: [for (var i = 1; i < rest.length; i += 2) rest[i]])),
              ]),
            ]);
          }
          return ListView(padding: const EdgeInsets.all(Gap.l), children: padded);
        }),
      ),
    );
  }
}

/// Nagłówek: rodzaj, stan, wymiary i masy.
class _Header extends StatelessWidget {
  const _Header({required this.vehicle});

  final Map<String, dynamic> vehicle;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = vehicle;
    final theme = Theme.of(context);
    final state = vehicleState(v);
    final color = stateColor(context, state) ?? theme.colorScheme.primary;
    final label = stateText(l, v);
    final kind = v['kind'] as String?;
    final facts = [
      kindLabel(l, kind),
      v['company_id'] != null ? l.vehicleOfCompany : l.vehiclePrivate,
      if (v['base_name'] != null) '${v['base_name']}',
      if (v['trailer_type'] != null && v['trailer_type'] != 'none') trailerLabel(l, '${v['trailer_type']}'),
      if (v['hazmat'] == true) 'ADR',
    ];
    final dims = [
      (l.vehicleHeight, v['height_m'], 'm', Icons.height),
      (l.vehicleWidth, v['width_m'], 'm', Icons.width_normal_outlined),
      (l.vehicleLength, v['length_m'], 'm', Icons.straighten),
      (l.vehicleGvw, v['gvw_t'], 't', Icons.scale_outlined),
      (l.vehicleAxleLoad, v['axle_load_t'], 't', Icons.fitness_center),
    ].where((d) => d.$2 is num).toList();
    final chip = switch (state) {
      VehicleState.inUse => StatusChip(label: label!),
      VehicleState.reported => StatusChip(label: label!, tone: StatusTone.warning),
      _ => null,
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (state == VehicleState.repair) ...[
        AlertBanner(title: l.cardRepairBanner, icon: Icons.car_repair),
        const SizedBox(height: Gap.m),
      ],
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (chip != null) ...[chip, const SizedBox(height: Gap.m)],
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              IconSquare(icon: kindIcon(kind), color: color, size: 64),
              const SizedBox(width: Gap.l),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(vehicleTitle(v), style: theme.textTheme.titleLarge),
                  const SizedBox(height: Gap.xs),
                  Text(facts.join(' · '),
                      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
                ]),
              ),
            ]),
          ]),
        ),
      ),
      if (dims.isNotEmpty) ...[
        const SizedBox(height: Gap.m),
        LayoutBuilder(builder: (context, size) {
          final columns = size.maxWidth >= 700 ? dims.length : (size.maxWidth >= 400 ? 3 : 2);
          final width = (size.maxWidth - Gap.m * (columns - 1)) / columns;
          return Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
            for (final (name, value, unit, icon) in dims)
              SizedBox(
                width: width,
                child: ValueTile(label: name, value: l.number(value as num), unit: unit, icon: icon),
              ),
          ]);
        }),
      ],
    ]);
  }
}

/// Terminy przeglądów i badań, które dotyczą pojazdu; po terminie i bliskie – wyróżnione.
class _DatesSection extends StatelessWidget {
  const _DatesSection({required this.vehicle, this.onEdit});

  final Map<String, dynamic> vehicle;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = vehicle;
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final rows = <Widget>[];
    for (final key in serviceDateKeys) {
      final applies =
          serviceDateApplies(key, kind: '${v['kind']}', body: '${v['trailer_type']}', hazmat: v['hazmat'] == true);
      final day = parseDate(v[key]);
      if (!applies || day == null) continue;
      final left = day.difference(today).inDays;
      final due = key != 'last_inspection' && left <= dueSoonDays;
      final color = !due ? null : (left < 0 ? theme.colorScheme.error : colors.warning);
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(due ? (left < 0 ? Icons.error_outline : Icons.schedule) : Icons.check_circle_outline,
              size: 18, color: color ?? colors.success),
          const SizedBox(width: Gap.s),
          Expanded(child: Text(serviceDateLabel(l, key))),
          Text(DateFormat.yMd(l.localeName).format(day),
              style: TextStyle(color: color, fontWeight: due ? FontWeight.w600 : null)),
        ]),
      ));
    }
    final kmLeft = serviceKmLeft(v);
    if (kmLeft != null) {
      final color = kmLeft < 0 ? theme.colorScheme.error : colors.warning;
      rows.add(Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(Icons.build_circle_outlined, size: 18, color: color),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(
              kmLeft < 0 ? l.vehicleServiceKmOverdue(l.number(-kmLeft)) : l.vehicleServiceKmSoon(l.number(kmLeft)),
              style: TextStyle(color: color),
            ),
          ),
        ]),
      ));
    }
    return SectionCard(
      title: l.cardDatesTitle,
      icon: Icons.event_note_outlined,
      accent: mostUrgent(v) != null || kmLeft != null ? colors.warning : null,
      action: onEdit == null ? null : TextButton(onPressed: onEdit, child: Text(l.edit)),
      child: rows.isEmpty
          ? Text(l.cardDatesEmpty, style: theme.textTheme.bodySmall)
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }
}

/// Kierowca (przydzielony i jadący teraz) oraz naczepa / pojazd ciągnący.
class _CrewSection extends StatelessWidget {
  const _CrewSection({required this.api, required this.vehicle, required this.all, required this.onChanged});

  final CoreApi api;
  final Map<String, dynamic> vehicle;
  final List<Map<String, dynamic>> all;
  final ValueChanged<Future<bool>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = vehicle;
    final theme = Theme.of(context);
    final towed = towedKinds.contains(v['kind']);
    final trailers = [
      for (final t in all)
        if (!isDrivable(t)) t
    ];
    final trailer = all.where((t) => t['id'] == v['trailer_id'] && v['trailer_id'] != null).firstOrNull;
    final editable = v['can_edit'] != false;
    final rows = <Widget>[
      if (!towed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_outline),
          title: Text(v['assigned_driver_name'] != null
              ? l.vehicleAssignedDriver('${v['assigned_driver_name']}')
              : l.cardDriverNone),
          subtitle: v['driver_name'] != null ? Text(l.cardDrivingNow('${v['driver_name']}')) : null,
          trailing: canAssignDriver(v)
              ? TextButton(onPressed: () => onChanged(assignDriver(context, api, v)), child: Text(l.edit))
              : null,
        ),
      if (towed)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.link),
          title: Text(v['coupled_to_name'] != null ? l.vehicleCoupledTo('${v['coupled_to_name']}') : l.cardNotCoupled),
        ),
      if (couples.containsKey(v['kind'])) ...[
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading:
              Icon(Icons.rv_hookup, color: trailer == null ? theme.colorScheme.outline : theme.colorScheme.primary),
          title: Text(trailer == null
              ? l.couplingNone(kindLabel(l, couples[v['kind']]))
              : l.couplingWith(vehicleTitle(trailer))),
          trailing: !editable
              ? null
              : trailer != null
                  ? IconButton(
                      tooltip: l.couplingRemove,
                      icon: const Icon(Icons.link_off),
                      onPressed: () => onChanged(coupleTrailer(context, api, v, null)),
                    )
                  : TextButton(
                      onPressed: () => onChanged(chooseTrailer(context, api, v, trailers)),
                      child: Text(l.couplingAdd),
                    ),
        ),
        // Wolne pasujące naczepy – podpięcie jednym kliknięciem.
        if (editable && trailer == null)
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final t in freeTrailers(v, trailers).take(3))
              ActionChip(
                avatar: const Icon(Icons.link, size: 18),
                label: Text(l.cardCoupleQuick(vehicleTitle(t))),
                onPressed: () => onChanged(coupleTrailer(context, api, v, t)),
              ),
          ]),
      ],
    ];
    return SectionCard(
      title: towed ? l.cardCouplingTitle : l.cardCrewTitle,
      icon: towed ? Icons.rv_hookup : Icons.people_alt_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }
}

/// Zezwolenia na przejazd ważne dziś dla tego pojazdu.
class _PermitsSection extends StatefulWidget {
  const _PermitsSection({required this.api, required this.vehicle});

  final CoreApi api;
  final Map<String, dynamic> vehicle;

  @override
  State<_PermitsSection> createState() => _PermitsSectionState();
}

class _PermitsSectionState extends State<_PermitsSection> {
  late final Future<dynamic> _permits = widget.api
      .get('/api/permits?vehicle_id=${widget.vehicle['id']}&day=${DateFormat('yyyy-MM-dd').format(DateTime.now())}')
      .catchError(_hideIfMissing);
  bool _missing = false;

  /// Funkcji nie ma na serwerze (404 – starsza wersja) – sekcja znika zamiast pokazywać błąd.
  Never _hideIfMissing(Object error) {
    if (error is ApiException && error.status == 404 && mounted) setState(() => _missing = true);
    throw error;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (_missing) return const SizedBox.shrink();
    return SectionCard(
      title: l.permitsTitle,
      icon: Icons.verified_outlined,
      action: TextButton(
        onPressed: () =>
            Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PermitsScreen(api: widget.api))),
        child: Text(l.dashShowAll),
      ),
      child: FutureBuilder<dynamic>(
        future: _permits,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final permits = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
          if (permits.isEmpty) return Text(l.cardPermitsEmpty, style: Theme.of(context).textTheme.bodySmall);
          return Column(children: [
            for (final p in permits)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.verified_outlined, color: TruckPalette.permitted),
                title: Text([p['number'], if ('${p['issuer'] ?? ''}'.isNotEmpty) p['issuer']].join(' · ')),
                subtitle: Text(permitSummary(l, p)),
              ),
          ]);
        },
      ),
    );
  }
}

/// Skrót statystyk z 12 miesięcy; szczegóły na osobnym ekranie.
class _StatsSection extends StatefulWidget {
  const _StatsSection({required this.api, required this.vehicle});

  final CoreApi api;
  final Map<String, dynamic> vehicle;

  @override
  State<_StatsSection> createState() => _StatsSectionState();
}

class _StatsSectionState extends State<_StatsSection> {
  late final Future<dynamic> _stats =
      widget.api.get('/api/vehicles/${widget.vehicle['id']}/stats?months=12').catchError(_hideIfMissing);
  bool _missing = false;

  /// Funkcji nie ma na serwerze (404 – starsza wersja) – sekcja znika zamiast pokazywać błąd.
  Never _hideIfMissing(Object error) {
    if (error is ApiException && error.status == 404 && mounted) setState(() => _missing = true);
    throw error;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    if (_missing) return const SizedBox.shrink();
    return SectionCard(
      title: l.cardStatsTitle,
      icon: Icons.insights_outlined,
      action: TextButton(
        onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => VehicleStatsScreen(api: widget.api, vehicle: widget.vehicle))),
        child: Text(l.cardMore),
      ),
      child: FutureBuilder<dynamic>(
        future: _stats,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}', style: theme.textTheme.bodySmall);
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final s = snapshot.data as Map<String, dynamic>;
          if (s['trips'] == 0) return Text(l.vehicleStatsEmpty, style: theme.textTheme.bodySmall);
          final km = NumberFormat.decimalPattern(l.localeName).format((s['distance_km'] as num).round());
          Widget figure(String value, String label) => Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(value, style: theme.textTheme.titleMedium),
                  Text(label, style: theme.textTheme.bodySmall),
                ]),
              );
          return Row(children: [
            figure('$km km', l.vehicleStatsKm),
            figure('${s['trips']}', l.vehicleStatsTrips),
            figure(l.number(s['hours'] as num, decimals: 1), l.vehicleStatsHours),
          ]);
        },
      ),
    );
  }
}
