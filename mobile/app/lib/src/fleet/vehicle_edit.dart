import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import '../vehicles/body_types.dart';
import 'vehicle_screen.dart' show towedKinds;

/// Pola liczbowe karty pojazdu (klucz serwera → czy całkowite).
const _numbers = {
  'production_year': true,
  'tare_t': false,
  'gvw_t': false,
  'weight_t': false,
  'axle_load_t': false,
  'axle_count': true,
  'height_m': false,
  'width_m': false,
  'length_m': false,
  'fifth_wheel_m': false,
  'consumption_empty': false,
  'consumption_loaded': false,
  'adblue_percent': false,
  'odometer_km': true,
  'service_due_km': true,
  'cost_per_km': false,
  'cost_per_hour': false,
};
const _texts = ['name', 'plate', 'vin', 'cost_currency'];
const _dates = [
  'last_inspection',
  'inspection_until',
  'tachograph_until',
  'tachograph_download_until',
  'insurance_until',
  'ac_until',
  'ocp_until',
  'udt_until',
  'tdt_until',
  'adr_until',
  'atp_until',
  'leasing_until',
];

/// Edycja pojazdu według projektu Stitch. Karta pojazdu – `PUT /api/vehicles/{id}`, kierowca –
/// `PUT …/driver`, naczepa – `PUT …/trailer`; pól, których karta jeszcze nie ma (numer boczny,
/// telemetria, OBU, TPMS, polisy – numery), – „W budowie”.
class VehicleEditScreen extends StatefulWidget {
  const VehicleEditScreen({
    super.key,
    required this.api,
    required this.vehicleId,
    required this.onOpen,
    required this.onDone,
  });

  final CoreApi api;
  final String vehicleId;
  final ValueChanged<String> onOpen;
  final ValueChanged<bool> onDone;

  @override
  State<VehicleEditScreen> createState() => _VehicleEditScreenState();
}

class _VehicleEditScreenState extends State<VehicleEditScreen> {
  Map<String, dynamic>? _v;
  List<Map<String, dynamic>> _all = const [];
  List<Map<String, dynamic>> _drivers = const [];
  Object? _error;
  bool _saving = false;
  final _c = <String, TextEditingController>{};
  final _day = <String, DateTime?>{};
  final _pick = <String, dynamic>{};
  String? _driverId;
  String? _trailerId;
  final _sections = List.generate(5, (_) => GlobalKey());
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _ctl(String key) => _c.putIfAbsent(key, TextEditingController.new);

  Future<void> _load() async {
    try {
      final all = uiMaps(await widget.api.get('/api/vehicles'));
      final v = all.where((x) => x['id'] == widget.vehicleId).firstOrNull;
      var drivers = const <Map<String, dynamic>>[];
      if (v?['company_id'] case final String company) {
        try {
          final c = await widget.api.get('/api/companies/${Uri.encodeComponent(company)}');
          drivers = [
            for (final m in uiMaps(c is Map ? c['members'] : null))
              if (m['role'] == 'driver') m
          ];
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _all = all;
        _v = v;
        _drivers = drivers;
        if (v != null) _fill(v);
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _fill(Map<String, dynamic> v) {
    for (final k in [..._texts, ..._numbers.keys]) {
      final value = v[k];
      _ctl(k).text =
          value == null ? '' : (value is num && value == value.roundToDouble() ? '${value.toInt()}' : '$value');
    }
    for (final k in _dates) {
      _day[k] = v[k] == null ? null : DateTime.tryParse('${v[k]}');
    }
    for (final k in ['kind', 'trailer_type', 'emission_class', 'fuel_type', 'hazmat']) {
      _pick[k] = v[k];
    }
    _driverId = v['assigned_member_id'] as String?;
    _trailerId = v['trailer_id'] as String?;
  }

  bool get _towed => towedKinds.contains(_pick['kind']);

  Future<void> _save() async {
    final l = context.l;
    final v = _v;
    if (v == null) return;
    final body = Map<String, dynamic>.of(v);
    for (final k in _texts) {
      final t = _ctl(k).text.trim();
      body[k] = t.isEmpty ? (k == 'cost_currency' ? v[k] : null) : (k == 'plate' || k == 'vin' ? t.toUpperCase() : t);
    }
    for (final MapEntry(key: k, value: whole) in _numbers.entries) {
      final t = _ctl(k).text.trim().replaceAll(' ', '').replaceAll(',', '.');
      body[k] = t.isEmpty ? null : (whole ? int.tryParse(t) : double.tryParse(t));
    }
    for (final k in _dates) {
      body[k] = _day[k] == null ? null : DateFormat('yyyy-MM-dd').format(_day[k]!);
    }
    body.addAll(_pick);
    final id = Uri.encodeComponent(widget.vehicleId);
    setState(() => _saving = true);
    try {
      await widget.api.put('/api/vehicles/$id', body);
      if (!_towed && _driverId != v['assigned_member_id']) {
        await widget.api.put('/api/vehicles/$id/driver', {'member_id': _driverId});
      }
      if (!_towed && _trailerId != v['trailer_id']) {
        await widget.api.put('/api/vehicles/$id/trailer', {'trailer_id': _trailerId});
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(l.vehSaved)));
      widget.onDone(true);
    } on ApiException catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = _v;
    if (v == null) {
      if (_error != null) return Center(child: Text('$_error'));
      if (_all.isNotEmpty) return Center(child: UiEmpty(l.vehNotFound));
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(builder: (context, size) {
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final wide = size.maxWidth - 2 * pad >= 900;
      return Column(children: [
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(pad, pad, pad, Gap.l),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _head(context, v),
              const SizedBox(height: Gap.m),
              _tabs(context),
              const SizedBox(height: 20),
              _tiles(context, v, wide),
              const SizedBox(height: 20),
              KeyedSubtree(key: _sections[0], child: _basic(context, wide)),
              const SizedBox(height: 20),
              KeyedSubtree(key: _sections[1], child: _technical(context, wide)),
              const SizedBox(height: 20),
              KeyedSubtree(key: _sections[2], child: _telemetry(context, wide)),
              const SizedBox(height: 20),
              KeyedSubtree(key: _sections[3], child: _deadlines(context, wide)),
              const SizedBox(height: 20),
              KeyedSubtree(key: _sections[4], child: _assignment(context, wide)),
            ]),
          ),
        ),
        _footer(context, v, pad),
      ]);
    });
  }

  Widget _head(BuildContext context, Map<String, dynamic> v) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(children: [
      IconSquare(icon: _towed ? Icons.rv_hookup_outlined : Icons.local_shipping_outlined, size: 44),
      const SizedBox(width: Gap.m),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: Gap.s, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${v['name']}', style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            if (v['plate'] != null) UiTag('${v['plate']}', tone: 'info', uppercase: false),
            if (v['in_use'] == true) UiTag(l.fleetStatusDriving, tone: 'ok'),
          ]),
          Text(l.vehVin(v['vin'] == null ? '–' : '${v['vin']}'),
              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ]),
      ),
      OutlinedButton(onPressed: () => widget.onOpen(l.vehNewTemplate), child: Text(l.vehNewTemplate)),
    ]);
  }

  Widget _tabs(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final tabs = [l.vehTab1, l.vehTab2, l.vehTab3, l.vehTab4, l.vehTab5];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final (i, t) in tabs.indexed)
          InkWell(
            key: Key('veh-tab-$i'),
            onTap: () {
              setState(() => _tab = i);
              final ctx = _sections[i].currentContext;
              if (ctx != null) Scrollable.ensureVisible(ctx, duration: const Duration(milliseconds: 300));
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: Gap.l, vertical: Gap.m),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: i == _tab ? scheme.primary : Colors.transparent, width: 2)),
              ),
              child: Text('${i + 1}. $t',
                  style: theme.textTheme.labelLarge
                      ?.copyWith(color: i == _tab ? scheme.primary : scheme.onSurfaceVariant)),
            ),
          ),
      ]),
    );
  }

  Widget _tiles(BuildContext context, Map<String, dynamic> v, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final format = DateFormat.yMd(l.localeName);
    final trailer = _all.where((t) => t['id'] == v['trailer_id']).firstOrNull;
    Widget tile(String label, IconData icon, String value, String note) => UiPanel(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(
                  child: Text(label.toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant, letterSpacing: 0.4))),
              Icon(icon, size: 16, color: scheme.onSurfaceVariant),
            ]),
            const SizedBox(height: Gap.s),
            Text(value, style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        );
    String day(String k) => v[k] == null ? '–' : format.format(DateTime.parse('${v[k]}'));
    final tiles = [
      tile(l.vehOdometer, Icons.speed_outlined,
          v['odometer_km'] == null ? '–' : '${l.number(v['odometer_km'] as num)} km', l.vehOdometerNote),
      tile(
          l.vehSkp, Icons.verified_user_outlined, day('inspection_until'), l.vehLastInspection(day('last_inspection'))),
      tile(l.vehPolicy, Icons.shield_outlined, day('insurance_until'), l.vehOcpUntil(day('ocp_until'))),
      tile(l.vehSet, Icons.link_outlined, trailer == null ? '–' : '${trailer['plate'] ?? trailer['name']}',
          trailer == null ? '' : '${trailer['name']}'),
    ];
    if (!wide) {
      return Column(children: [for (final t in tiles) Padding(padding: const EdgeInsets.only(bottom: 12), child: t)]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (i, t) in tiles.indexed) ...[if (i > 0) const SizedBox(width: 20), Expanded(child: t)],
    ]);
  }

  // ------------------------------------------------------------------ pola

  Widget _section(BuildContext context, int n, String title, String subtitle, List<Widget> children, {Widget? badge}) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
                color: scheme.primaryContainer, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Text('$n', style: theme.textTheme.titleSmall?.copyWith(color: scheme.onPrimaryContainer)),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          if (badge != null) badge,
        ]),
        const SizedBox(height: 20),
        ...children,
      ]),
    );
  }

  Widget _grid(bool wide, List<Widget> fields, {int columns = 4}) {
    final n = wide ? columns : 1;
    final rows = <Widget>[];
    for (var i = 0; i < fields.length; i += n) {
      final chunk = fields.sublist(i, (i + n).clamp(0, fields.length));
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: Gap.m),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (final (j, f) in chunk.indexed) ...[if (j > 0) const SizedBox(width: Gap.l), Expanded(child: f)],
          for (var k = chunk.length; k < n; k++) ...[const SizedBox(width: Gap.l), const Expanded(child: SizedBox())],
        ]),
      ));
    }
    return Column(children: rows);
  }

  Widget _label(BuildContext context, String text, {bool required = false}) => Padding(
        padding: const EdgeInsets.only(bottom: Gap.xs),
        child: Text('$text${required ? ' *' : ''}',
            style: Theme.of(context)
                .textTheme
                .labelMedium
                ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );

  Widget _text(BuildContext context, String label, String key, {String? unit, bool required = false}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(context, label, required: required),
        TextField(
          key: Key('veh-$key'),
          controller: _ctl(key),
          style: Theme.of(context).textTheme.bodyMedium,
          keyboardType: _numbers.containsKey(key) ? const TextInputType.numberWithOptions(decimal: true) : null,
          decoration: InputDecoration(
            isDense: true,
            suffixText: unit,
            suffixStyle: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).colorScheme.outline),
          ),
        ),
      ]);

  Widget _wip(BuildContext context, String label) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(context, label),
        InputDecorator(
          isEmpty: true,
          decoration: const InputDecoration(isDense: true, enabled: false),
          child: Align(alignment: Alignment.centerLeft, child: WipTag(what: label, onOpen: widget.onOpen)),
        ),
      ]);

  Widget _date(BuildContext context, String label, String key) {
    final value = _day[key];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _label(context, label),
      InkWell(
        key: Key('veh-date-$key'),
        onTap: () async {
          final picked = await showDatePicker(
            context: context,
            initialDate: value ?? DateTime.now(),
            firstDate: DateTime(1950),
            lastDate: DateTime(2100),
          );
          if (picked != null) setState(() => _day[key] = picked);
        },
        child: InputDecorator(
          isEmpty: value == null,
          decoration: const InputDecoration(isDense: true, suffixIcon: Icon(Icons.calendar_today_outlined, size: 18)),
          child: Text(value == null ? '' : DateFormat.yMd(context.l.localeName).format(value),
              style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    ]);
  }

  Widget _drop<T>(BuildContext context, String label, String key, List<(T?, String)> items,
          {T? value, ValueChanged<T?>? onChanged}) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _label(context, label),
        DropdownButtonFormField<T?>(
          key: Key('veh-$key'),
          value: value ?? _pick[key] as T?,
          isExpanded: true,
          isDense: true,
          style: Theme.of(context).textTheme.bodyMedium,
          decoration: const InputDecoration(isDense: true),
          items: [
            for (final (v, t) in items) DropdownMenuItem<T?>(value: v, child: Text(t, overflow: TextOverflow.ellipsis))
          ],
          onChanged: onChanged ?? (v) => setState(() => _pick[key] = v),
        ),
      ]);

  // ------------------------------------------------------------------ sekcje

  Widget _basic(BuildContext context, bool wide) {
    final l = context.l;
    return _section(context, 1, l.vehSec1, l.vehSec1Sub, badge: UiTag(l.vehCategory, tone: 'info'), [
      _grid(wide, [
        _drop<String>(context, l.vehKind, 'kind', [
          ('tractor', l.vehKindTractor),
          ('rigid', l.vehKindRigid),
          ('combination', l.vehKindCombination),
          ('van', l.vehKindVan),
          ('bus', l.vehKindBus),
          ('semitrailer', l.vehKindSemitrailer),
          ('trailer', l.vehKindTrailer),
        ]),
        _wip(context, l.vehSideNo),
        _text(context, l.vehPlateLabel, 'plate', required: true),
        _text(context, l.vehNameLabel, 'name', required: true),
        _text(context, l.vehVinLabel, 'vin'),
        _text(context, l.vehYearLabel, 'production_year'),
        _wip(context, l.vehFirstReg),
        _wip(context, l.vehColor),
      ]),
    ]);
  }

  Widget _technical(BuildContext context, bool wide) {
    final l = context.l;
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    Widget cert(String title, Widget body) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.radius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: theme.textTheme.labelLarge),
              const SizedBox(height: Gap.xs),
              body,
            ]),
          ),
        );
    return _section(context, 2, l.vehSec2, l.vehSec2Sub, [
      _grid(wide, [
        _drop<String>(context, l.vehEmission, 'emission_class', [
          (null, '–'),
          ('euro6', 'Euro 6'),
          ('euro5', 'Euro 5'),
          ('euro4', 'Euro 4'),
          ('euro3', 'Euro 3'),
          ('electric', l.vehFuelElectric),
        ]),
        _text(context, l.vehTare, 'tare_t', unit: 't'),
        _text(context, l.vehGvw, 'gvw_t', unit: 't'),
        _text(context, l.vehWeight, 'weight_t', unit: 't'),
        _text(context, l.vehAxleLoad, 'axle_load_t', unit: 't'),
        _text(context, l.vehAxles, 'axle_count'),
        _text(context, l.vehFifthWheel, 'fifth_wheel_m', unit: 'm'),
        _drop<String>(context, l.vehFuelLabel, 'fuel_type', [
          (null, '–'),
          ('diesel', l.vehFuelDiesel),
          ('lng', 'LNG'),
          ('cng', 'CNG'),
          ('electric', l.vehFuelElectric),
        ]),
        _text(context, l.vehHeight, 'height_m', unit: 'm'),
        _text(context, l.vehWidth, 'width_m', unit: 'm'),
        _text(context, l.vehLength, 'length_m', unit: 'm'),
        _text(context, l.vehAdbluePct, 'adblue_percent', unit: '%'),
        _text(context, l.vehBurnEmpty, 'consumption_empty', unit: 'l/100 km'),
        _text(context, l.vehBurnLoaded, 'consumption_loaded', unit: 'l/100 km'),
        _wip(context, l.vehTanks),
        if (_towed)
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _label(context, l.vehTrailerType),
            BodyField(
              key: const Key('veh-trailer_type'),
              label: '',
              value: '${_pick['trailer_type'] ?? 'curtain'}',
              none: true,
              onChanged: (v) => setState(() => _pick['trailer_type'] = v),
            ),
          ])
        else
          const SizedBox(),
      ]),
      Text(l.vehCerts.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 0.5)),
      const SizedBox(height: Gap.s),
      Flex(
        direction: wide ? Axis.horizontal : Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          cert(
              l.vehAdr,
              Row(children: [
                Checkbox(
                  key: const Key('veh-hazmat'),
                  value: _pick['hazmat'] == true,
                  onChanged: (v) => setState(() => _pick['hazmat'] = v ?? false),
                ),
                Expanded(child: Text(l.vehHazmat, style: theme.textTheme.bodySmall)),
              ])),
          SizedBox(width: wide ? Gap.m : 0, height: wide ? 0 : Gap.m),
          cert(l.vehAtp, _date(context, l.vehValidTo, 'atp_until')),
          SizedBox(width: wide ? Gap.m : 0, height: wide ? 0 : Gap.m),
          cert(l.vehXl, WipTag(what: l.vehXl, onOpen: widget.onOpen)),
          SizedBox(width: wide ? Gap.m : 0, height: wide ? 0 : Gap.m),
          cert(l.vehGdp, WipTag(what: l.vehGdp, onOpen: widget.onOpen)),
        ],
      ),
    ]);
  }

  Widget _telemetry(BuildContext context, bool wide) {
    final l = context.l;
    return _section(context, 3, l.vehSec3, l.vehSec3Sub, badge: WipTag(what: l.vehSec3, onOpen: widget.onOpen), [
      _grid(wide, [
        _wip(context, l.vehFmsModem),
        _wip(context, l.vehTachoDevice),
        _wip(context, l.vehGps),
        _date(context, l.vehTachoDownload, 'tachograph_download_until'),
        _wip(context, l.vehEtoll),
        _wip(context, l.vehTollCollect),
        _wip(context, l.vehEets),
        _wip(context, l.vehTpms),
      ]),
    ]);
  }

  Widget _deadlines(BuildContext context, bool wide) {
    final l = context.l;
    return _section(context, 4, l.vehSec4, l.vehSec4Sub, [
      _grid(wide, [
        _date(context, l.vehLastSkp, 'last_inspection'),
        _date(context, l.vehSkpUntil, 'inspection_until'),
        _date(context, l.vehTachoUntil, 'tachograph_until'),
        _wip(context, l.vehInsurer),
        _date(context, l.vehOcUntil, 'insurance_until'),
        _date(context, l.vehAcUntilLabel, 'ac_until'),
        _date(context, l.vehOcpUntilLabel, 'ocp_until'),
        _wip(context, l.vehPolicyNo),
        _date(context, l.vehUdtUntil, 'udt_until'),
        _date(context, l.vehTdtUntil, 'tdt_until'),
        _date(context, l.vehAdrUntil, 'adr_until'),
        _date(context, l.vehLeasingUntil, 'leasing_until'),
        _text(context, l.vehOdometer, 'odometer_km', unit: 'km'),
        _text(context, l.vehServiceDue, 'service_due_km', unit: 'km'),
      ]),
    ]);
  }

  Widget _assignment(BuildContext context, bool wide) {
    final l = context.l;
    final v = _v!;
    final trailers = [
      for (final t in _all)
        if (towedKinds.contains(t['kind']) && t['company_id'] == v['company_id']) t
    ];
    return _section(context, 5, l.vehSec5, l.vehSec5Sub, [
      _grid(wide, [
        _wip(context, l.drvBase),
        if (_towed)
          _wip(context, l.vehDriver)
        else
          _drop<String>(
              context,
              l.vehDriver,
              'driver',
              [
                (null, l.fleetNoDriver),
                for (final m in _drivers) ('${m['id']}', '${m['display_name']}'),
              ],
              value: _driverId,
              onChanged: (v) => setState(() => _driverId = v)),
        if (_towed)
          _wip(context, l.vehTrailer)
        else
          _drop<String>(
              context,
              l.vehTrailer,
              'trailer',
              [
                (null, '–'),
                for (final t in trailers) ('${t['id']}', '${t['plate'] ?? ''} ${t['name']}'.trim()),
              ],
              value: _trailerId,
              onChanged: (v) => setState(() => _trailerId = v)),
        _wip(context, l.vehOpStatus),
        _text(context, l.vehCostKm, 'cost_per_km'),
        _text(context, l.vehCostHour, 'cost_per_hour'),
        _text(context, l.vehCurrency, 'cost_currency'),
        _wip(context, l.vehNotes),
      ]),
    ]);
  }

  Widget _footer(BuildContext context, Map<String, dynamic> v, double pad) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: pad, vertical: Gap.m),
      decoration: BoxDecoration(color: colors.card, boxShadow: TruckTheme.softShadow),
      child: Wrap(
        spacing: Gap.m,
        runSpacing: Gap.s,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: scheme.tertiaryContainer, shape: BoxShape.circle)),
            const SizedBox(width: Gap.s),
            Text(l.vehFooter('${v['plate'] ?? v['name']}'), style: theme.textTheme.bodySmall),
          ]),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            OutlinedButton.icon(
              key: const Key('veh-cancel'),
              style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
              onPressed: () => widget.onDone(false),
              icon: const Icon(Icons.close, size: 18),
              label: Text(l.vehCancel),
            ),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
              onPressed: () => widget.onOpen(l.drvDraft),
              icon: const Icon(Icons.drafts_outlined, size: 18),
              label: Text(l.drvDraft),
            ),
            FilledButton.icon(
              key: const Key('veh-save'),
              style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 18),
              label: Text(l.vehSave),
            ),
          ]),
        ],
      ),
    );
  }
}
