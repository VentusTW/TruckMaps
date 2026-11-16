import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import '../records/records.dart';
import 'fleet_export.dart';
import 'fuel_cards.dart';
import 'service_data.dart';

/// „Koszty i TCO” według projektu Stitch: koszt wozokilometra i jego struktura (trasy, serwis),
/// benchmark marek, spalanie pusty/pełny z kart pojazdów i ranking kierowców z przejazdów.
/// Wynagrodzenia, amortyzacja, myto, ceny paliw, anomalie CAN, akcyza i ERP – „W budowie”.
class TcoScreen extends StatefulWidget {
  const TcoScreen({
    super.key,
    required this.api,
    required this.companyId,
    required this.onOpen,
    this.onOpenDriver,
    this.months = 6,
  });

  final CoreApi api;
  final String? companyId;
  final ValueChanged<String> onOpen;
  final void Function(String id, String name)? onOpenDriver;
  final int months;

  @override
  State<TcoScreen> createState() => _TcoScreenState();
}

/// Ocena eco kierowcy (0–100) z przejazdów: kary za postój na pracującym silniku i puste km.
int? ecoScore(Map<String, dynamic>? s) {
  if (s == null) return null;
  final km = ((s['distance_km'] as num?) ?? 0).toDouble();
  if (km <= 0) return null;
  final hours = ((s['hours'] as num?) ?? 0).toDouble();
  final idle = ((s['idle_hours'] as num?) ?? 0).toDouble();
  final empty = ((s['empty_km'] as num?) ?? 0).toDouble();
  final idleShare = hours + idle > 0 ? idle / (hours + idle) : 0.0;
  return (100 - 60 * idleShare - 40 * (empty / km).clamp(0, 1)).round().clamp(0, 100);
}

/// Marka pojazdu (pierwsze słowo nazwy, np. „MAN”, „Volvo”).
String vehicleMake(Map<String, dynamic> v) => '${v['name'] ?? ''}'.trim().split(RegExp(r'\s+')).first;

class _TcoScreenState extends State<TcoScreen> {
  FleetData? _data;
  Object? _error;
  String _query = '';

  /// Filtr marki (OEM) i ceny paliwa z biuletynu KE.
  String? _make;
  Map<String, dynamic>? _fuel;
  Map<String, dynamic>? _cards;

  FleetData _filtered(FleetData d) {
    if (_make == null) return d;
    final vehicles = [
      for (final v in d.vehicles)
        if (vehicleMake(v) == _make || d.vehicles.any((p) => vehicleMake(p) == _make && p['trailer_id'] == v['id'])) v
    ];
    final ids = {for (final v in vehicles) '${v['id']}'};
    return FleetData(
      vehicles: vehicles,
      orders: d.orders,
      stats: {
        for (final e in d.stats.entries)
          if (ids.contains(e.key)) e.key: e.value
      },
      drivers: d.drivers,
    );
  }

  Future<void> _pickMake() async {
    final l = context.l;
    final data = _data;
    if (data == null) return;
    final makes = {for (final v in data.power) vehicleMake(v)}..removeWhere((m) => m.isEmpty);
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(title: Text(l.tcoMake), children: [
        RadioListTile<String>(
            value: '', groupValue: _make ?? '', title: Text(l.anAll), onChanged: (v) => Navigator.pop(context, v)),
        for (final m in makes)
          RadioListTile<String>(
              value: m, groupValue: _make ?? '', title: Text(m), onChanged: (v) => Navigator.pop(context, v)),
      ]),
    );
    if (chosen != null) setState(() => _make = chosen.isEmpty ? null : chosen);
  }

  /// Zatwierdzenie premii: kierowcy z oceną eco, kwota do wpisania; zapis jako wpisy `bonus`.
  Future<void> _bonuses(FleetData data) async {
    final l = context.l;
    final company = widget.companyId;
    if (company == null) return;
    final drivers = [
      for (final d in data.drivers ?? const <Map<String, dynamic>>[]) (d, ecoScore(d['stats'] as Map<String, dynamic>?))
    ];
    final controllers = {
      for (final (d, score) in drivers) '${d['id']}': TextEditingController(text: (score ?? 0) >= 80 ? '300' : '0'),
    };
    final month = DateFormat('yyyy-MM').format(DateTime.now());
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${l.tcoBonuses} – $month'),
        content: SizedBox(
          width: 460,
          child: drivers.isEmpty
              ? Text(l.mainNoData)
              : ListView(shrinkWrap: true, children: [
                  for (final (d, score) in drivers)
                    ListTile(
                      dense: true,
                      title: Text('${d['name']}'),
                      subtitle: Text(l.tcoScoreValue(score == null ? '–' : '$score')),
                      trailing: SizedBox(
                        width: 110,
                        child: TextField(
                          controller: controllers['${d['id']}'],
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(suffixText: 'PLN', isDense: true),
                        ),
                      ),
                    ),
                ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.tcoBonuses)),
        ],
      ),
    );
    final amounts = {for (final e in controllers.entries) e.key: num.tryParse(e.value.text.replaceAll(',', '.')) ?? 0};
    for (final c in controllers.values) {
      c.dispose();
    }
    if (ok != true) return;
    final records = RecordsApi(widget.api, company);
    for (final (d, score) in drivers) {
      final amount = amounts['${d['id']}'] ?? 0;
      if (amount > 0) {
        await records.add(
            'driver', '${d['id']}', 'bonus', {'month': month, 'score': score, 'amount': amount, 'currency': 'PLN'});
      }
    }
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.tcoBonusesSaved)));
  }

  /// Ceny oleju napędowego w krajach UE (biuletyn KE, aktualizowany co tydzień).
  Widget _fuelCard(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final prices = ((_fuel?['diesel_eur'] as Map?) ?? const {}).cast<String, dynamic>();
    final sorted = prices.entries.toList()..sort((a, b) => (a.value as num).compareTo(b.value as num));
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.tcoFuelPrices, icon: Icons.local_gas_station_outlined),
        const SizedBox(height: Gap.m),
        if (sorted.isEmpty)
          Text(l.tcoFuelNone, style: theme.textTheme.bodySmall)
        else ...[
          for (final e in sorted.take(8))
            Row(children: [
              Expanded(child: Text(e.key)),
              Text('${l.number(e.value as num, decimals: 3)} €/l', style: theme.textTheme.labelLarge),
            ]),
          const SizedBox(height: Gap.s),
          Text(l.tcoFuelDay('${_fuel?['day'] ?? ''}'), style: theme.textTheme.bodySmall),
        ],
      ]),
    );
  }

  /// Anomalie: pojazdy z kosztem na km wyraźnie (ponad 30%) wyższym od średniej floty.
  Widget _anomaliesCard(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final rows = [
      for (final v in data.power)
        if (data.stats['${v['id']}'] case final s?)
          if (((s['distance_km'] as num?) ?? 0) > 0) (v, tripCosts(s) / (s['distance_km'] as num))
    ];
    final avg = rows.isEmpty ? 0.0 : rows.fold(0.0, (a, r) => a + r.$2) / rows.length;
    final high = [
      for (final r in rows)
        if (avg > 0 && r.$2 > avg * 1.3) r
    ];
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.tcoAnomalies, icon: Icons.shield_outlined),
        const SizedBox(height: Gap.m),
        if (high.isEmpty)
          Text(rows.isEmpty ? l.mainNoData : l.tcoNoAnomalies, style: theme.textTheme.bodySmall)
        else
          for (final (v, perKm) in high)
            Text(l.tcoAnomaly('${v['plate'] ?? v['name']}', l.number(perKm, decimals: 2),
                l.number((perKm / avg - 1) * 100, decimals: 0))),
      ]),
    );
  }

  /// Eksport do ERP / SAP: ten sam plik CSV co raport TCO.
  Widget _erpCard(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.tcoErp, icon: Icons.sync_alt_outlined),
        const SizedBox(height: Gap.m),
        Text(l.tcoErpCsvNote, style: theme.textTheme.bodySmall),
        const SizedBox(height: Gap.s),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
              onPressed: _export, icon: const Icon(Icons.download_outlined, size: 18), label: Text(l.tcoReport)),
        ),
      ]),
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data =
          await FleetData.load(widget.api, widget.companyId, withStats: true, withDrivers: true, months: widget.months);
      if (mounted) setState(() => _data = data);
      await _loadCards();
      final fuel = await widget.api.get('/api/fuel-prices');
      if (mounted && fuel is Map<String, dynamic>) setState(() => _fuel = fuel);
    } catch (e) {
      if (mounted && _data == null) setState(() => _error = e);
    }
  }

  /// Raport TCO: koszty przejazdów i serwisu każdego pojazdu w CSV (Excel).
  Future<void> _export() async {
    final data = _data;
    if (data == null) return;
    double service(String id) => data.done
        .where((o) => o['vehicle_id'] == id || data.vehicle(id)?['trailer_id'] == o['vehicle_id'])
        .fold(0.0, (a, o) => a + orderTotal(o));
    final opened = await openCsv(toCsv(fleetReportRows(context.l, data, service)), 'raport-tco');
    if (!opened && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.exportFailed)));
    }
  }

  /// Tankowania z kart paliwowych w okresie (rzeczywisty koszt paliwa zamiast szacunku tras).
  Future<void> _loadCards() async {
    final company = widget.companyId;
    if (company == null) return;
    try {
      final cards = await FuelCardsApi(widget.api, company).summary(months: widget.months);
      if (mounted) setState(() => _cards = cards);
    } catch (_) {}
  }

  /// Kwota tankowań w PLN pojazdów z widoku (bez filtra marki – także bez pojazdu) i kwoty
  /// w innych walutach (nie przeliczamy kursów).
  (double, Map<String, double>) _cardFuel(FleetData data) {
    final ids = {for (final v in data.vehicles) '${v['id']}'};
    var pln = 0.0;
    final other = <String, double>{};
    for (final v in uiMaps(_cards?['vehicles'])) {
      final id = v['vehicle_id'];
      if (id == null ? _make != null : !ids.contains('$id')) continue;
      for (final e in ((v['amount'] as Map?) ?? const {}).entries) {
        final value = (e.value as num).toDouble();
        if (e.key == 'PLN') {
          pln += value;
        } else {
          other.update('${e.key}', (a) => a + value, ifAbsent: () => value);
        }
      }
    }
    return (pln, other);
  }

  @override
  Widget build(BuildContext context) {
    final data = _data == null ? null : _filtered(_data!);
    if (data == null) {
      return Center(child: _error == null ? const CircularProgressIndicator() : Text('$_error'));
    }
    final l = context.l;
    final km = data.stats.values.fold(0.0, (a, s) => a + ((s['distance_km'] as num?) ?? 0));
    final (cardFuel, otherFuel) = _cardFuel(data);
    final cards = cardFuel > 0;
    final routes = cards ? cardFuel : data.stats.values.fold(0.0, (a, s) => a + tripCosts(s));
    final note = otherFuel.isEmpty ? null : fuelAmounts(l, otherFuel);
    final service = data.done.fold(0.0, (a, o) => a + orderTotal(o));
    return LayoutBuilder(builder: (context, size) {
      const gap = 20.0;
      final pad = size.maxWidth >= 600 ? Gap.xl : Gap.l;
      final inner = size.maxWidth - 2 * pad;
      final wide = inner >= 900;
      final third = wide ? (inner - 2 * gap) / 3 : inner;
      return ListView(padding: EdgeInsets.all(pad), children: [
        _header(context),
        const SizedBox(height: gap),
        _filters(context, data, km, routes, service),
        const SizedBox(height: gap),
        if (wide)
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(flex: 7, child: _structure(context, km, routes, service, cards: cards, other: note)),
              const SizedBox(width: gap),
              Expanded(flex: 5, child: _benchmark(context, data)),
            ]),
          )
        else ...[
          _structure(context, km, routes, service, cards: cards, other: note),
          const SizedBox(height: gap),
          _benchmark(context, data),
        ],
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          SizedBox(width: third, child: _tonnage(context, data)),
          SizedBox(width: third, child: _fuelCard(context)),
          SizedBox(width: third, child: _anomaliesCard(context, data)),
        ]),
        const SizedBox(height: gap),
        _drivers(context, data),
        const SizedBox(height: gap),
        Wrap(spacing: gap, runSpacing: gap, children: [
          SizedBox(
              width: wide ? (inner - gap) / 2 : inner,
              child: _wipCard(context, l.tcoExcise, l.tcoExciseNote, Icons.receipt_outlined)),
          SizedBox(width: wide ? (inner - gap) / 2 : inner, child: _erpCard(context)),
        ]),
      ]);
    });
  }

  Widget _header(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    return UiPanel(
      child: Wrap(
        spacing: Gap.l,
        runSpacing: Gap.m,
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(spacing: 0, runSpacing: Gap.xs, crossAxisAlignment: WrapCrossAlignment.center, children: [
                UiTag(l.tcoBadge, tone: 'critical'),
                const SizedBox(width: Gap.s),
                Text(l.tcoSource, style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant)),
              ]),
              const SizedBox(height: Gap.s),
              Text(l.tcoTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
              Text(l.tcoSubtitle, style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
            for (final (label, icon) in [
              (l.tcoExciseShort, Icons.euro_outlined),
              (l.tcoErpShort, Icons.storage_outlined)
            ])
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(side: BorderSide(color: colors.surfaceHigh)),
                onPressed: () => label == l.tcoErpShort ? _export() : widget.onOpen(label),
                icon: Icon(icon, size: 18),
                label: Text(label),
              ),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
              onPressed: _export,
              icon: const Icon(Icons.download_outlined, size: 18),
              label: Text(l.tcoReport),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context, FleetData data, double km, double routes, double service) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final perKm = km == 0 ? null : (routes + service) / km;
    Widget box(String label, Widget child, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 200),
            padding: const EdgeInsets.all(Gap.m),
            decoration:
                BoxDecoration(color: colors.surfaceLow, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(label.toUpperCase(), style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              const SizedBox(height: Gap.xs),
              child,
            ]),
          ),
        );
    return UiPanel(
      child: Wrap(spacing: Gap.m, runSpacing: Gap.m, crossAxisAlignment: WrapCrossAlignment.center, children: [
        box(l.tcoPeriod, Text(l.anLastMonths(l.number(widget.months)), style: theme.textTheme.labelLarge)),
        box(l.tcoMake, Text(_make ?? l.anAll, style: theme.textTheme.labelLarge), onTap: _pickMake),
        box(
            l.tcoCards,
            FuelCardsSummary(
                api: widget.api,
                companyId: widget.companyId,
                months: widget.months,
                stats: data.stats,
                onChanged: _loadCards)),
        box(
          l.tcoAvgKm,
          Text.rich(TextSpan(children: [
            TextSpan(
                text: perKm == null ? '–' : l.number(perKm, decimals: 2),
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            TextSpan(text: ' PLN / km', style: theme.textTheme.bodySmall),
          ])),
        ),
      ]),
    );
  }

  /// [cards] – koszt paliwa z kart zamiast szacunku tras; [other] – tankowania w innych walutach.
  Widget _structure(BuildContext context, double km, double routes, double service,
      {bool cards = false, String? other}) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final total = routes + service;
    final parts = [
      cards
          ? (
              l.tcoFuelCards,
              other == null ? l.tcoFuelCardsNote : l.tcoFuelCardsOther(other),
              routes,
              scheme.primary,
              true
            )
          : (l.tcoRoutes, l.tcoRoutesNote, routes, scheme.primary, true),
      (l.tcoService, l.tcoServiceNote, service, scheme.primaryContainer, true),
      (l.tcoWages, l.tcoWagesNote, 0.0, scheme.outline, false),
      (l.tcoDepreciation, l.tcoDepreciationNote, 0.0, scheme.outlineVariant, false),
      (l.tcoTolls, l.tcoTollsNote, 0.0, colors.surfaceHigh, false),
    ];
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(l.tcoStructure, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              Text(l.tcoStructureNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(km == 0 ? '–' : '${l.number(total / km, decimals: 2)} PLN',
                style: theme.textTheme.titleLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
            Text(l.tcoBase(l.number(km, decimals: 0)), style: theme.textTheme.labelSmall),
          ]),
        ]),
        const SizedBox(height: Gap.l),
        ClipRRect(
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          child: SizedBox(
            height: 22,
            child: Row(children: [
              for (final (_, _, value, color, _) in parts)
                if (value > 0)
                  Expanded(
                    flex: (value / (total == 0 ? 1 : total) * 1000).round().clamp(1, 1000),
                    child: Container(
                      color: color,
                      alignment: Alignment.center,
                      child: Text('${(100 * value / total).round()}%',
                          style: theme.textTheme.labelSmall?.copyWith(color: Colors.white)),
                    ),
                  ),
              if (total == 0) Expanded(child: Container(color: colors.surfaceHigh)),
            ]),
          ),
        ),
        const SizedBox(height: Gap.l),
        for (final (name, note, value, color, real) in parts)
          UiBox(
            padding: const EdgeInsets.all(Gap.m),
            child: Row(children: [
              Container(width: 12, height: 12, color: color),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name, style: theme.textTheme.labelLarge),
                  Text(note, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ]),
              ),
              if (real)
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(km == 0 ? '–' : '${l.number(value / km, decimals: 2)} PLN/km',
                      style: theme.textTheme.labelLarge),
                  Text(total == 0 ? '' : '${l.number(100 * value / total, decimals: 1)}%',
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.primary)),
                ])
              else
                WipTag(what: name, onOpen: widget.onOpen),
            ]),
          ),
      ]),
    );
  }

  Widget _benchmark(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final groups = <String, List<Map<String, dynamic>>>{};
    for (final v in data.power) {
      groups.putIfAbsent('${v['name']}'.split(' ').first, () => []).add(v);
    }
    final rows = [
      for (final MapEntry(key: make, value: list) in groups.entries)
        () {
          final km = list.fold(0.0, (a, v) => a + ((data.stats['${v['id']}']?['distance_km'] as num?) ?? 0));
          final cost = list.fold(0.0, (a, v) => a + tripCosts(data.stats['${v['id']}']));
          final burns = [
            for (final v in list)
              if (v['consumption_loaded'] is num) (v['consumption_loaded'] as num).toDouble()
          ];
          return (
            make,
            list.length,
            burns.isEmpty ? null : burns.reduce((a, b) => a + b) / burns.length,
            km == 0 ? null : cost / km,
            list.first['adblue_percent'] as num?,
          );
        }(),
    ]..sort((a, b) => (a.$4 ?? 99).compareTo(b.$4 ?? 99));
    final best = rows.where((r) => r.$4 != null).firstOrNull;
    final worst = rows.where((r) => r.$4 != null).lastOrNull;
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(l.tcoBenchmark, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        Text(l.tcoBenchmarkNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: Gap.l),
        if (rows.isEmpty) UiEmpty(l.anNoData),
        for (final (make, count, burn, perKm, _) in rows)
          UiBox(
            padding: const EdgeInsets.all(Gap.m),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(make, style: theme.textTheme.labelLarge)),
                UiTag(l.tcoUnits(l.number(count)), tone: 'info', uppercase: false),
                const SizedBox(width: Gap.s),
                Text(perKm == null ? '–' : '${l.number(perKm, decimals: 2)} PLN/km',
                    style: theme.textTheme.labelLarge?.copyWith(color: scheme.primary)),
              ]),
              const SizedBox(height: Gap.xs),
              Text(burn == null ? l.tcoBurnUnknown : l.tcoBurn(l.number(burn, decimals: 1)),
                  style: theme.textTheme.bodySmall),
              const SizedBox(height: Gap.xs),
              TruckProgressBar(value: perKm == null || worst?.$4 == null ? 0 : perKm / worst!.$4!, height: 5),
            ]),
          ),
        if (best != null && worst != null && best != worst)
          Container(
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Row(children: [
              Icon(Icons.insights_outlined, color: scheme.primary),
              const SizedBox(width: Gap.s),
              Expanded(
                child: Text(l.tcoInsight(best.$1, l.number(100 * (1 - best.$4! / worst.$4!), decimals: 1), worst.$1),
                    style: theme.textTheme.bodySmall),
              ),
            ]),
          ),
      ]),
    );
  }

  Widget _tonnage(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    double avg(String key) {
      final list = [
        for (final v in data.power)
          if (v[key] is num) (v[key] as num).toDouble()
      ];
      return list.isEmpty ? 0 : list.reduce((a, b) => a + b) / list.length;
    }

    final empty = avg('consumption_empty');
    final full = avg('consumption_loaded');
    return UiPanel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        UiSectionHeader(title: l.tcoTonnage, subtitle: l.tcoTonnageNote, icon: Icons.scale_outlined),
        const SizedBox(height: Gap.l),
        MiniBars(
          height: 120,
          labels: [l.tcoEmpty, l.tcoFull],
          series: [
            (scheme.primaryContainer, [empty, full]),
          ],
        ),
        const SizedBox(height: Gap.s),
        Row(children: [
          Expanded(
              child: Text('${l.tcoEmpty}: ${empty == 0 ? '–' : l.number(empty, decimals: 1)} l/100 km',
                  style: theme.textTheme.bodySmall)),
          Text('${l.tcoFull}: ${full == 0 ? '–' : l.number(full, decimals: 1)} l/100 km',
              style: theme.textTheme.bodySmall),
        ]),
        const SizedBox(height: Gap.xs),
        Text(empty == 0 || full == 0 ? '' : l.tcoDelta(l.number(full - empty, decimals: 1)),
            style: theme.textTheme.labelMedium?.copyWith(color: scheme.primary)),
      ]),
    );
  }

  Widget _drivers(BuildContext context, FleetData data) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = TruckColors.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant);
    final q = _query.trim().toLowerCase();
    final drivers = [
      for (final d in data.drivers ?? const <Map<String, dynamic>>[])
        if (q.isEmpty || '${d['name']}'.toLowerCase().contains(q)) d
    ]..sort((a, b) => ((b['stats']?['distance_km'] as num?) ?? 0).compareTo((a['stats']?['distance_km'] as num?) ?? 0));
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
                UiTag(l.tcoEcoBadge, tone: 'tertiary'),
                const SizedBox(width: Gap.s),
                Text(l.tcoDriversTitle, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
              ]),
              Text(l.tcoDriversNote, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            Wrap(spacing: Gap.s, children: [
              SizedBox(
                width: 220,
                child: TextField(
                  key: const Key('tco-search'),
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l.tcoSearchDriver,
                    prefixIcon: Icon(Icons.search, size: 18, color: scheme.outline),
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: scheme.primaryContainer),
                onPressed: () => _bonuses(data),
                child: Text(l.tcoBonuses),
              ),
            ]),
          ],
        ),
        const SizedBox(height: Gap.l),
        Container(
          color: colors.surfaceLow,
          padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.s),
          child: Row(children: [
            Expanded(flex: 4, child: Text(l.tcoColDriver.toUpperCase(), style: head)),
            Expanded(flex: 2, child: Text(l.tcoColKm.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColTrips.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColHours.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColEmpty.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColIdle.toUpperCase(), textAlign: TextAlign.end, style: head)),
            Expanded(flex: 2, child: Text(l.tcoColScore.toUpperCase(), textAlign: TextAlign.end, style: head)),
          ]),
        ),
        if (data.drivers == null) Padding(padding: const EdgeInsets.all(Gap.m), child: UiEmpty(l.drvNoModule)),
        for (final d in drivers.take(6))
          InkWell(
            onTap: widget.onOpenDriver == null ? null : () => widget.onOpenDriver!('${d['id']}', '${d['name']}'),
            child: Container(
              decoration: BoxDecoration(border: Border(top: BorderSide(color: colors.surfaceHigh))),
              padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.m),
              child: Builder(builder: (context) {
                final s = (d['stats'] as Map?) ?? const {};
                final km = ((s['distance_km'] as num?) ?? 0).toDouble();
                final empty = ((s['empty_km'] as num?) ?? 0).toDouble();
                final name = '${d['name']}';
                return Row(children: [
                  Expanded(
                    flex: 4,
                    child: Row(children: [
                      CircleAvatar(
                        radius: 14,
                        backgroundColor: scheme.secondaryContainer,
                        child: Text(name.split(' ').take(2).map((p) => p.isEmpty ? '' : p[0]).join(),
                            style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSecondaryContainer)),
                      ),
                      const SizedBox(width: Gap.s),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(name, style: theme.textTheme.labelLarge),
                          Text([for (final v in uiMaps(d['vehicles'])) '${v['plate'] ?? v['name']}'].join(', '),
                              style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                        ]),
                      ),
                    ]),
                  ),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number(km, decimals: 0)} km',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text(l.number((s['trips'] as num?) ?? 0),
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number((s['hours'] as num?) ?? 0, decimals: 0)} h',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text(km == 0 ? '–' : '${l.number(100 * empty / km, decimals: 1)}%',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Text('${l.number((s['idle_hours'] as num?) ?? 0, decimals: 1)} h',
                          textAlign: TextAlign.end, style: theme.textTheme.bodySmall)),
                  Expanded(
                      flex: 2,
                      child: Align(
                          alignment: Alignment.centerRight,
                          child: Builder(builder: (context) {
                            final score = ecoScore(s.cast<String, dynamic>());
                            return Text(score == null ? '–' : '$score',
                                style: theme.textTheme.labelLarge?.copyWith(
                                    color: score == null
                                        ? null
                                        : (score >= 80 ? colors.success : (score < 50 ? scheme.error : null))));
                          }))),
                ]);
              }),
            ),
          ),
      ]),
    );
  }

  Widget _wipCard(BuildContext context, String title, String note, IconData icon) {
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
