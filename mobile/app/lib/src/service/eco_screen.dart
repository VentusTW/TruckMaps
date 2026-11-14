import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../dashboard/main_dashboard.dart';
import '../l10n.dart';
import 'service_data.dart';

/// kg CO₂ na litr spalonego paliwa (olej napędowy, wskaźnik KOBiZE / UE).
const co2PerLitre = 2.64;

/// Spalanie na postoju z pracującym silnikiem (l/h) – szacunek dla ciężarówki.
const idleLitresPerHour = 2.5;

/// Szacunek dla pojazdu z przejazdów (GPS) i spalania z profilu pojazdu: litry w jeździe,
/// na postoju, CO₂ i udział pustych km. `null` – profil bez spalania.
class EcoEstimate {
  const EcoEstimate({required this.km, required this.emptyKm, required this.litres, required this.idleLitres});

  final double km;
  final double emptyKm;
  final double litres;
  final double idleLitres;

  double get co2Kg => (litres + idleLitres) * co2PerLitre;
  double? get emptyShare => km > 0 ? emptyKm / km : null;
  double? get per100 => km > 0 ? (litres + idleLitres) / km * 100 : null;

  static EcoEstimate? of(Map<String, dynamic> vehicle, Map<String, dynamic>? stats) {
    final loaded = (vehicle['consumption_loaded'] as num?)?.toDouble();
    final empty = (vehicle['consumption_empty'] as num?)?.toDouble() ?? loaded;
    if (loaded == null || stats == null) return null;
    final km = ((stats['distance_km'] as num?) ?? 0).toDouble();
    final emptyKm = ((stats['empty_km'] as num?) ?? 0).toDouble().clamp(0, km).toDouble();
    final litres = (km - emptyKm) * loaded / 100 + emptyKm * (empty ?? loaded) / 100;
    final idle = ((stats['idle_hours'] as num?) ?? 0).toDouble() * idleLitresPerHour;
    return EcoEstimate(km: km, emptyKm: emptyKm, litres: litres, idleLitres: idle);
  }
}

/// Eko: spalanie, CO₂, puste kilometry i postój na pracującym silniku – z przejazdów GPS
/// i spalania wpisanego w profilu pojazdu (bez telematyki to szacunek, nie odczyt z CAN).
class EcoScreen extends StatefulWidget {
  const EcoScreen({super.key, required this.api, required this.companyId, this.months = 3});

  final CoreApi api;
  final String? companyId;
  final int months;

  @override
  State<EcoScreen> createState() => _EcoScreenState();
}

class _EcoScreenState extends State<EcoScreen> {
  FleetData? _data;
  Object? _error;

  @override
  void initState() {
    super.initState();
    FleetData.load(widget.api, widget.companyId, withStats: true, months: widget.months).then((d) {
      if (mounted) setState(() => _data = d);
    }, onError: (Object e) {
      if (mounted) setState(() => _error = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final data = _data;
    if (_error != null) return Center(child: Text('$_error'));
    if (data == null) return const Center(child: CircularProgressIndicator());
    final rows = [
      for (final v in data.power) (v, EcoEstimate.of(v, data.stats['${v['id']}'])),
    ];
    final known = [
      for (final (_, e) in rows)
        if (e != null) e
    ];
    final km = known.fold<double>(0, (a, e) => a + e.km);
    final litres = known.fold<double>(0, (a, e) => a + e.litres + e.idleLitres);
    final idle = known.fold<double>(0, (a, e) => a + e.idleLitres);
    final co2 = known.fold<double>(0, (a, e) => a + e.co2Kg);
    final empty = known.fold<double>(0, (a, e) => a + e.emptyKm);
    String n(num v, [int d = 0]) => l.number(v, decimals: d);
    Widget kpi(String label, String value) => SizedBox(
          width: 220,
          child: UiPanel(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label.toUpperCase(), style: theme.textTheme.labelSmall),
              Text(value, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
        );
    return ListView(padding: const EdgeInsets.all(Gap.l), children: [
      Text(l.ecoTitle, style: theme.textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700)),
      Text(l.ecoSubtitle(widget.months), style: theme.textTheme.bodyMedium),
      const SizedBox(height: Gap.l),
      Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
        kpi(l.ecoKm, '${n(km)} km'),
        kpi(l.ecoFuel, '${n(litres)} l'),
        kpi(l.ecoCo2, '${n(co2 / 1000, 1)} t'),
        kpi(l.ecoPer100, km > 0 ? '${n(litres / km * 100, 1)} l' : '–'),
        kpi(l.ecoEmpty, km > 0 ? '${n(empty / km * 100, 1)} %' : '–'),
        kpi(l.ecoIdle, '${n(idle)} l'),
      ]),
      const SizedBox(height: Gap.l),
      UiPanel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(l.ecoByVehicle, style: theme.textTheme.titleMedium),
          const SizedBox(height: Gap.s),
          if (rows.isEmpty) UiEmpty(l.mainNoData),
          for (final (v, e) in rows)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.local_shipping_outlined),
              title: Text('${v['plate'] ?? v['name']}'),
              subtitle: Text(e == null
                  ? l.ecoNoConsumption
                  : [
                      '${n(e.km)} km',
                      '${n(e.litres + e.idleLitres)} l',
                      '${n(e.co2Kg)} kg CO₂',
                      if (e.per100 != null) '${n(e.per100!, 1)} l/100 km',
                      if (e.emptyShare != null) l.ecoEmptyShare(n(e.emptyShare! * 100, 1)),
                    ].join(' · ')),
            ),
          const SizedBox(height: Gap.s),
          Text(l.ecoNote, style: theme.textTheme.bodySmall),
        ]),
      ),
    ]);
  }
}
