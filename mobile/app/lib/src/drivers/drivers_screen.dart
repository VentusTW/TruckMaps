import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'drivers_data.dart';

/// „Kierowcy i Czas Pracy”: lista kierowców firmy albo profil jednego ([driverId]) według projektu
/// Stitch. Dane z modułu Kierowcy (kartoteka, terminy, statystyki, historia) i z pojazdów rdzenia;
/// tachograf, telemetria CAN, zlecenia i lokalizacja – „W budowie”.
class DriversScreen extends StatefulWidget {
  const DriversScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.onOpen,
    required this.onOpenDriver,
    required this.onEdit,
    this.onOpenVehicle,
    this.driverId,
    this.driverName,
    this.today,
  });

  final CoreApi api;
  final String? companyId;
  final ValueChanged<String> onOpen;
  final void Function(String id, String name) onOpenDriver;
  final void Function(String id, String name) onEdit;

  /// Ciągnik / naczepa kierowcy – profil pojazdu.
  final void Function(String id, String name)? onOpenVehicle;

  /// Profil kierowcy; `null` – lista. [driverName] – gdy przyszliśmy z innego ekranu tylko z nazwiskiem.
  final String? driverId;
  final String? driverName;
  final DateTime? today;

  @override
  State<DriversScreen> createState() => _DriversScreenState();
}

class _DriversScreenState extends State<DriversScreen> {
  DriversData? _data;
  Object? _error;
  Map<String, dynamic>? _stats;
  List<Map<String, dynamic>> _history = const [];
  String? _statsFor;
  int _tab = 0;
  String _query = '';

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
  void didUpdateWidget(DriversScreen old) {
    super.didUpdateWidget(old);
    if (old.companyId != widget.companyId) {
      _load();
    } else if (old.driverId != widget.driverId || old.driverName != widget.driverName) {
      _tab = 0;
      _loadDetails();
    }
  }

  Future<void> _load() async {
    final company = widget.companyId;
    if (company == null) {
      setState(() => _data = DriversData(drivers: const [], vehicles: const [], module: false));
      return;
    }
    try {
      final data = await DriversData.load(widget.api, company);
      if (!mounted) return;
      setState(() {
        _data = data;
        _error = null;
      });
      _loadDetails();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Map<String, dynamic>? get _driver {
    final data = _data;
    if (data == null) return null;
    final id = widget.driverId;
    if (id != null) return data.byId(id);
    final name = widget.driverName;
    return name == null ? null : data.byName(name);
  }

  /// Statystyki i historia profilu (tylko z modułem Kierowcy).
  Future<void> _loadDetails() async {
    final d = _driver;
    if (d == null || _data?.module != true || _statsFor == d['id']) return;
    _statsFor = '${d['id']}';
    final id = Uri.encodeComponent('${d['id']}');
    Future<dynamic> get(String path) async {
      try {
        return await widget.api.get(path);
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait([
      get('/api/m/drivers/drivers/$id/stats?months=3'),
      get('/api/m/drivers/drivers/$id/history'),
    ]);
    if (!mounted) return;
    setState(() {
      _stats = results[0] is Map<String, dynamic> ? results[0] as Map<String, dynamic> : null;
      _history = uiMaps(results[1]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final data = _data;
    if (data == null) {
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
    final driver = _driver;
    if (widget.driverId != null || widget.driverName != null) {
      if (driver == null) return Center(child: UiEmpty(l.drvNotFound));
      return _profile(context, data, driver);
    }
    return _list(context, data);
  }

  // ------------------------------------------------------------------ lista

  Widget _list(BuildContext context, DriversData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final d in data.drivers)
        if (q.isEmpty || '${d['name']}'.toLowerCase().contains(q)) d
    ];
    return LayoutBuilder(builder: (context, size) {
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final columns = inner >= 1100 ? 3 : (inner >= 700 ? 2 : 1);
      final width = (inner - 20.0 * (columns - 1)) / columns;
      return ListView(padding: EdgeInsets.all(pad), children: [
        Wrap(
          spacing: Gap.l,
          runSpacing: Gap.m,
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Wrap(spacing: Gap.m, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(l.mainMenuDrivers, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              UiTag(l.drvCount(l.number(data.drivers.length)), tone: 'info', uppercase: false),
            ]),
            Wrap(spacing: Gap.s, children: [
              SizedBox(
                width: 240,
                child: TextField(
                  key: const Key('drv-search'),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l.drvSearch,
                    prefixIcon: Icon(Icons.search, size: 20, color: scheme.outline),
                  ),
                ),
              ),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
                onPressed: () => widget.onOpen(l.drvAdd),
                icon: const Icon(Icons.person_add_alt_outlined, size: 18),
                label: Text(l.drvAdd),
              ),
            ]),
          ],
        ),
        if (!data.module) ...[
          const SizedBox(height: Gap.l),
          UiPanel(
            child: Row(children: [
              Icon(Icons.info_outline, color: scheme.primary),
              const SizedBox(width: Gap.m),
              Expanded(child: Text(l.drvNoModule, style: theme.textTheme.bodyMedium)),
              WipTag(what: l.drvRegister, onOpen: widget.onOpen),
            ]),
          ),
        ],
        const SizedBox(height: 20),
        if (shown.isEmpty) UiPanel(child: UiEmpty(l.drvEmpty)),
        Wrap(spacing: 20, runSpacing: 20, children: [
          for (final d in shown) SizedBox(width: width, child: _card(context, data, d)),
        ]),
      ]);
    });
  }

  Widget _card(BuildContext context, DriversData data, Map<String, dynamic> d) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final vehicle = data.vehicleOf(d);
    final dues = uiMaps(d['dues']);
    final format = DateFormat.yMd(l.localeName);
    return Card(
      child: InkWell(
        key: Key('drv-card-${d['id']}'),
        onTap: () => widget.onOpenDriver('${d['id']}', '${d['name']}'),
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _Avatar(name: '${d['name']}', size: 48),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name']}', style: theme.textTheme.titleSmall?.copyWith(fontSize: 15)),
                const SizedBox(height: Gap.xs),
                _statusChip(context, data, d),
                const SizedBox(height: Gap.s),
                Text(
                    vehicle == null
                        ? l.drvNoVehicle
                        : l.drvTractor('${vehicle['name']}${vehicle['plate'] == null ? '' : ' (${vehicle['plate']})'}'),
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                if (dues.isNotEmpty) ...[
                  const SizedBox(height: Gap.xs),
                  Text(
                      l.drvNextDue(_fieldLabel(l, '${dues.first['field']}'),
                          format.format(parseDay(dues.first['day']) ?? _today)),
                      style: theme.textTheme.labelMedium?.copyWith(
                          color: dues.first['state'] == 'overdue' ? scheme.error : TruckColors.of(context).warning)),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _statusChip(BuildContext context, DriversData data, Map<String, dynamic> d) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final vehicle = data.vehicleOf(d);
    final (String label, Color bg, Color fg) = data.driving(d)
        ? (l.drvDriving, const Color(0xFF85F8C4), const Color(0xFF00563A))
        : vehicle != null
            ? (l.drvAssigned, scheme.secondaryContainer, scheme.onSecondaryContainer)
            : (l.drvFree, TruckColors.of(context).surfaceHigh, scheme.onSurfaceVariant);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: fg, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall?.copyWith(color: fg))),
      ]),
    );
  }

  String _fieldLabel(AppLocalizations l, String field) => switch (field) {
        'license_until' => l.driverFieldLicense,
        'code95_until' => l.driverFieldCode95,
        'medical_until' => l.driverFieldMedical,
        'psych_until' => l.driverFieldPsych,
        'card_until' => l.driverFieldCard,
        'card_download_until' => l.driverFieldCardDownload,
        'adr_until' => l.driverFieldAdr,
        _ => l.driverFieldAttestation,
      };

  // ------------------------------------------------------------------ profil

  Widget _profile(BuildContext context, DriversData data, Map<String, dynamic> d) {
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final wide = size.maxWidth - 2 * pad >= 900;
      final left = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _tabs(context),
        const SizedBox(height: gap),
        ..._tabContent(context, data, d),
      ]);
      final right = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _calendar(context),
        const SizedBox(height: gap),
        _contact(context, d),
      ]);
      return ListView(padding: EdgeInsets.all(pad), children: [
        _head(context, data, d),
        const SizedBox(height: gap),
        _tacho(context, wide),
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

  Widget _head(BuildContext context, DriversData data, Map<String, dynamic> d) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final vehicle = data.vehicleOf(d);
    final trailer = data.trailerOf(vehicle);
    final format = DateFormat.yMd(l.localeName);
    String name(Map<String, dynamic>? v) =>
        v == null ? '–' : '${v['name']}${v['plate'] == null ? '' : ' (${v['plate']})'}';
    Widget line(IconData icon, String label, Widget value) => Padding(
          padding: const EdgeInsets.only(top: Gap.xs),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Text('$label: ', style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            Flexible(child: DefaultTextStyle.merge(style: theme.textTheme.bodyMedium, child: value)),
          ]),
        );
    final medical = parseDay(d['medical_until']);
    final code95 = parseDay(d['code95_until']);
    final card = parseDay(d['card_until']);
    final downloaded = parseDay(d['card_downloaded_on']);
    final chips = <Widget>[
      if (medical != null)
        _InfoChip(
          icon: Icons.health_and_safety_outlined,
          label: medical.isBefore(_today) ? l.drvMedicalExpired : l.drvMedicalOk,
          alarm: medical.isBefore(_today),
        ),
      if (code95 != null) _InfoChip(icon: Icons.verified_outlined, label: l.drvCode95Until(format.format(code95))),
      if (card != null)
        _InfoChip(
          icon: Icons.credit_card_outlined,
          label: downloaded == null
              ? l.drvCardUntil(format.format(card))
              : l.drvCardRead(l.number(_today.difference(downloaded).inDays)),
        ),
      if (d['adr_until'] != null)
        _InfoChip(icon: Icons.warning_amber_outlined, label: d['adr_tank'] == true ? l.drvAdrTank : l.drvAdrBasic),
    ];
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
              side: BorderSide(color: colors.surfaceHigh),
            ),
            onPressed: onTap ?? () => widget.onOpen(label),
            icon: Icon(icon, size: 18),
            label: Text(label),
          );
    final info = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${d['name']}', style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
      const SizedBox(height: Gap.xs),
      _statusChip(context, data, d),
      const SizedBox(height: Gap.s),
      line(Icons.local_shipping_outlined, l.drvTractorLabel, _vehicleLink(context, vehicle, name(vehicle))),
      line(Icons.rv_hookup_outlined, l.drvTrailerLabel, _vehicleLink(context, trailer, name(trailer))),
      line(Icons.speed_outlined, l.drvCan, WipTag(what: l.drvCan, onOpen: widget.onOpen)),
      if (chips.isNotEmpty) ...[
        const SizedBox(height: Gap.s),
        Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: chips),
      ],
    ]);
    final buttons = Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
      button(l.drvEdit, Icons.edit_note_outlined, onTap: () => widget.onEdit('${d['id']}', '${d['name']}')),
      button(l.drvMessage, Icons.chat_outlined, primary: true),
      button(l.drvDdd, Icons.download_for_offline_outlined),
      button(l.drvItd, Icons.description_outlined),
    ]);
    return UiPanel(
      child: LayoutBuilder(
        builder: (context, size) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _Avatar(name: '${d['name']}', size: 96, online: data.driving(d)),
          const SizedBox(width: 20),
          Expanded(
            child: size.maxWidth >= 900
                ? Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Expanded(child: info),
                    const SizedBox(width: Gap.l),
                    Flexible(child: buttons),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    info,
                    const SizedBox(height: Gap.l),
                    buttons,
                  ]),
          ),
        ]),
      ),
    );
  }

  Widget _vehicleLink(BuildContext context, Map<String, dynamic>? v, String text) {
    final open = widget.onOpenVehicle;
    if (v == null || open == null) return Text(text);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: Key('drv-vehicle-${v['id']}'),
      onTap: () => open('${v['id']}', '${v['plate'] ?? v['name']}'),
      child: Text(text,
          style: TextStyle(
              color: scheme.primary,
              decoration: TextDecoration.underline,
              decorationColor: scheme.primary.withOpacity(0.4))),
    );
  }

  Widget _tacho(BuildContext context, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final tiles = [
      l.drvTachoContinuous,
      l.drvTachoDaily,
      l.drvTachoRest,
      l.drvTachoWeek,
      l.drvTachoTwoWeeks,
      l.drvTachoHome,
    ];
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(
          title: l.drvTachoTitle,
          subtitle: l.drvTachoSubtitle,
          icon: Icons.av_timer_outlined,
          trailing: WipTag(what: l.drvTachoTitle, onOpen: widget.onOpen),
        ),
        const SizedBox(height: Gap.l),
        LayoutBuilder(builder: (context, size) {
          final columns = wide ? 6 : (size.maxWidth >= 500 ? 3 : 2);
          final width = (size.maxWidth - Gap.m * (columns - 1)) / columns;
          return Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
            for (final (i, label) in tiles.indexed)
              Container(
                width: width,
                padding: const EdgeInsets.all(Gap.m),
                decoration: BoxDecoration(
                  color: i == 0 ? scheme.errorContainer.withOpacity(0.35) : colors.surfaceLow,
                  borderRadius: BorderRadius.circular(TruckTheme.radius),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label.toUpperCase(),
                      maxLines: 2,
                      style: theme.textTheme.labelSmall
                          ?.copyWith(color: i == 0 ? scheme.error : scheme.onSurfaceVariant, letterSpacing: 0.4)),
                  const SizedBox(height: Gap.s),
                  Text('–', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: Gap.s),
                  TruckProgressBar(value: 0, height: 5, color: i == 0 ? scheme.error : scheme.primary),
                ]),
              ),
          ]);
        }),
      ]),
    );
  }

  Widget _tabs(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final tabs = [
      (l.drvTabRoute, Icons.route_outlined),
      (l.drvTabDocs, Icons.folder_open_outlined),
      (l.drvTabHistory, Icons.gavel_outlined),
    ];
    return Container(
      padding: const EdgeInsets.all(Gap.xs),
      decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Row(children: [
        for (final (i, (label, icon)) in tabs.indexed)
          Expanded(
            child: Material(
              color: i == _tab ? colors.card : Colors.transparent,
              borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
              child: InkWell(
                key: Key('drv-tab-$i'),
                borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                onTap: () => setState(() => _tab = i),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: Gap.m),
                  child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(icon, size: 18, color: i == _tab ? scheme.primary : scheme.onSurfaceVariant),
                    const SizedBox(width: Gap.s),
                    Flexible(
                      child: Text(label,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.labelLarge
                              ?.copyWith(color: i == _tab ? scheme.primary : scheme.onSurfaceVariant)),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  List<Widget> _tabContent(BuildContext context, DriversData data, Map<String, dynamic> d) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final format = DateFormat.yMd(l.localeName);
    switch (_tab) {
      case 1:
        final rows = [
          ('license_until', l.driverFieldLicense, (d['license_categories'] as List? ?? const []).join(', ')),
          ('code95_until', l.driverFieldCode95, ''),
          ('medical_until', l.driverFieldMedical, ''),
          ('psych_until', l.driverFieldPsych, ''),
          ('card_until', l.driverFieldCard, ''),
          ('card_download_until', l.driverFieldCardDownload, ''),
          ('adr_until', l.driverFieldAdr, d['adr_tank'] == true ? l.drvAdrTank : ''),
          ('attestation_until', l.driverFieldAttestation, ''),
        ];
        return [
          UiPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              UiSectionHeader(title: l.drvTabDocs, icon: Icons.folder_open_outlined),
              const SizedBox(height: Gap.l),
              if (!data.module) UiEmpty(l.drvNoModule),
              if (data.module)
                for (final (field, label, extra) in rows)
                  UiBox(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(label, style: theme.textTheme.labelLarge),
                          if (extra.isNotEmpty)
                            Text(extra, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                      Builder(builder: (context) {
                        final day = parseDay(d[field]);
                        final late = day != null && day.isBefore(_today);
                        final soon = day != null && !late && day.isBefore(_today.add(const Duration(days: 30)));
                        return Text(day == null ? '–' : format.format(day),
                            style: theme.textTheme.labelLarge
                                ?.copyWith(color: late ? scheme.error : (soon ? colors.warning : colors.success)));
                      }),
                    ]),
                  ),
              const SizedBox(height: Gap.s),
              Row(children: [
                Expanded(child: Text(l.drvFiles, style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline))),
                WipTag(what: l.drvFiles, onOpen: widget.onOpen),
              ]),
            ]),
          ),
        ];
      case 2:
        return [
          UiPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              UiSectionHeader(
                title: l.drvTabHistory,
                subtitle: l.drvHistorySubtitle,
                icon: Icons.history_outlined,
                trailing: WipTag(what: l.drvViolations, onOpen: widget.onOpen),
              ),
              const SizedBox(height: Gap.l),
              if (_history.isEmpty) UiEmpty(l.drvHistoryEmpty),
              for (final h in _history.take(20))
                UiBox(
                  padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
                  child: Row(children: [
                    Icon(Icons.edit_outlined, size: 18, color: scheme.primary),
                    const SizedBox(width: Gap.m),
                    Expanded(
                      child: Text(
                          [
                            '${h['by_name']}',
                            ...((h['changes'] as Map?)?.keys.map((k) => _fieldLabel(l, '$k')) ?? const <String>[]),
                          ].join(' • '),
                          style: theme.textTheme.bodySmall),
                    ),
                    Text(DateTime.tryParse('${h['at']}') == null ? '' : l.when(DateTime.parse('${h['at']}').toLocal()),
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                  ]),
                ),
            ]),
          ),
        ];
      default:
        final stats = _stats;
        Widget tile(String label, String value, String unit) => Expanded(
              child: Container(
                padding: const EdgeInsets.all(Gap.m),
                decoration:
                    BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(height: Gap.s),
                  Text.rich(TextSpan(children: [
                    TextSpan(text: value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    TextSpan(text: ' $unit', style: theme.textTheme.bodySmall?.copyWith(color: scheme.outline)),
                  ])),
                ]),
              ),
            );
        num v(String key) => stats?[key] as num? ?? 0;
        return [
          UiPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(
                  child: Text(l.drvOrderTitle.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary, letterSpacing: 0.6)),
                ),
                WipTag(what: l.drvOrderTitle, onOpen: widget.onOpen),
              ]),
              const SizedBox(height: Gap.s),
              UiEmpty(l.drvOrderNone),
            ]),
          ),
          const SizedBox(height: 20),
          UiPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              UiSectionHeader(
                title: l.drvStatsTitle,
                subtitle: l.drvStatsSubtitle,
                icon: Icons.eco_outlined,
                iconColor: scheme.tertiaryContainer,
                trailing: WipTag(what: l.drvEcoScore, onOpen: widget.onOpen),
              ),
              const SizedBox(height: Gap.l),
              if (stats == null)
                UiEmpty(data.module ? l.drvStatsNone : l.drvNoModule)
              else ...[
                Row(children: [
                  tile(l.drvStatTrips, l.number(v('trips')), ''),
                  const SizedBox(width: Gap.m),
                  tile(l.drvStatKm, l.number(v('distance_km'), decimals: 0), 'km'),
                  const SizedBox(width: Gap.m),
                  tile(l.drvStatHours, l.number(v('hours'), decimals: 1), 'h'),
                ]),
                const SizedBox(height: Gap.m),
                Row(children: [
                  tile(l.drvStatEmpty, l.number(v('empty_km'), decimals: 0), 'km'),
                  const SizedBox(width: Gap.m),
                  tile(l.drvStatIdle, l.number(v('idle_hours'), decimals: 1), 'h'),
                  const SizedBox(width: Gap.m),
                  tile(l.drvStatVehicles, l.number(v('vehicles')), ''),
                ]),
              ],
            ]),
          ),
          const SizedBox(height: 20),
          UiPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              UiSectionHeader(
                title: l.drvLocationTitle,
                icon: Icons.map_outlined,
                trailing: WipTag(what: l.drvLocationTitle, onOpen: widget.onOpen),
              ),
              const SizedBox(height: Gap.m),
              Container(
                height: 160,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
                child: Icon(Icons.location_off_outlined, size: 40, color: scheme.outline),
              ),
            ]),
          ),
        ];
    }
  }

  Widget _calendar(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final today = _today;
    final first = DateTime(today.year, today.month);
    final days = DateTime(today.year, today.month + 1, 0).day;
    final offset = first.weekday - 1;
    final tripDays = {
      for (final t in uiMaps(_stats?['recent']))
        if (DateTime.tryParse('${t['ended_at']}')?.toLocal() case final d?)
          if (d.year == today.year && d.month == today.month) d.day
    };
    final week = DateFormat.E(l.localeName);
    final monday = DateTime(2024, 1, 1); // poniedziałek
    final weekNo = ((today.difference(DateTime(today.year)).inDays + DateTime(today.year).weekday - 1) ~/ 7) + 1;
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(Icons.calendar_month_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Text(l.drvSchedule(DateFormat.yMMMM(l.localeName).format(today)),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(l.drvWeek(l.number(weekNo)), style: theme.textTheme.labelMedium?.copyWith(color: scheme.outline)),
        ]),
        const SizedBox(height: Gap.m),
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
          childAspectRatio: 1.25,
          children: [
            for (var i = 0; i < 7; i++)
              Center(
                child: Text(week.format(monday.add(Duration(days: i))),
                    style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            for (var i = 0; i < offset; i++) const SizedBox(),
            for (var day = 1; day <= days; day++)
              Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: day == today.day
                      ? scheme.tertiaryContainer
                      : (tripDays.contains(day) ? scheme.primaryContainer : colors.surfaceLow),
                  borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                ),
                child: Text('$day',
                    style: theme.textTheme.labelMedium?.copyWith(
                        color: day == today.day || tripDays.contains(day) ? Colors.white : scheme.onSurface)),
              ),
          ],
        ),
        const SizedBox(height: Gap.m),
        Row(children: [
          Container(width: 10, height: 10, color: scheme.tertiaryContainer),
          const SizedBox(width: 6),
          Expanded(child: Text(l.drvToday, style: theme.textTheme.bodySmall)),
          Container(width: 10, height: 10, color: scheme.primaryContainer),
          const SizedBox(width: 6),
          Text(l.drvTripDays(l.number(tripDays.length)), style: theme.textTheme.bodySmall),
        ]),
        const SizedBox(height: Gap.m),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Expanded(child: Text(l.drvLeave, style: theme.textTheme.labelLarge)),
            WipTag(what: l.drvLeave, onOpen: widget.onOpen),
          ]),
        ),
      ]),
    );
  }

  Widget _contact(BuildContext context, Map<String, dynamic> d) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    Widget row(IconData icon, String title, Widget body, {Widget? trailing, bool alarm = false}) => UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                  color: alarm ? scheme.errorContainer : colors.card,
                  borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
              child: Icon(icon, size: 18, color: alarm ? scheme.error : scheme.onSurfaceVariant),
            ),
            const SizedBox(width: Gap.m),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title.toUpperCase(),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: alarm ? scheme.error : scheme.onSurfaceVariant, letterSpacing: 0.4)),
                const SizedBox(height: 2),
                body,
              ]),
            ),
            if (trailing != null) trailing,
          ]),
        );
    final phone = '${d['phone'] ?? ''}';
    final notes = '${d['notes'] ?? ''}';
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.contact_phone_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: Gap.s),
          Text(l.drvContactTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        ]),
        const SizedBox(height: Gap.l),
        row(
          Icons.phone_outlined,
          l.drvPhone,
          Text(phone.isEmpty ? '–' : phone, style: theme.textTheme.titleSmall),
          trailing: phone.isEmpty
              ? null
              : IconButton.filled(
                  style: IconButton.styleFrom(backgroundColor: scheme.primaryContainer),
                  tooltip: l.drvCall,
                  onPressed: () => widget.onOpen(l.drvCall),
                  icon: const Icon(Icons.call, size: 18),
                ),
        ),
        row(Icons.router_outlined, l.drvGarmin, WipTag(what: l.drvGarmin, onOpen: widget.onOpen)),
        row(Icons.emergency_outlined, l.drvIce, WipTag(what: l.drvIce, onOpen: widget.onOpen), alarm: true),
        UiBox(
          padding: const EdgeInsets.all(Gap.m),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: Text(l.drvNotes, style: theme.textTheme.labelLarge)),
              TextButton(
                onPressed: () => widget.onEdit('${d['id']}', '${d['name']}'),
                child: Text(l.drvEditShort),
              ),
            ]),
            Text(notes.isEmpty ? '–' : '„$notes”',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]),
    );
  }
}

/// Zdjęcie kierowcy – w kartotece nie ma zdjęć, więc inicjały na kolorze marki.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name, required this.size, this.online = false});

  final String name;
  final double size;
  final bool online;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Stack(clipBehavior: Clip.none, children: [
      Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration:
            BoxDecoration(color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TruckTheme.radius)),
        child: Text(initials(name),
            style: Theme.of(context)
                .textTheme
                .headlineSmall
                ?.copyWith(color: scheme.onPrimaryContainer, fontSize: size * 0.32, fontWeight: FontWeight.w700)),
      ),
      if (online)
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: scheme.tertiaryContainer,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2),
            ),
            child: Icon(Icons.check, size: 12, color: scheme.onTertiaryContainer),
          ),
        ),
    ]);
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, this.alarm = false});

  final IconData icon;
  final String label;
  final bool alarm;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = alarm ? scheme.onErrorContainer : scheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Gap.s, vertical: 3),
      decoration: BoxDecoration(
        color: alarm ? scheme.errorContainer : TruckColors.of(context).surfaceLow,
        borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: fg),
        const SizedBox(width: 4),
        Flexible(child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: fg))),
      ]),
    );
  }
}
