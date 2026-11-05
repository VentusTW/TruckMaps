import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';

/// Kolory oceny jak w planerze w przeglądarce (zielony → czerwony).
const levelColors = {
  'green': Color(0xFF3B6D11),
  'lime': Color(0xFF97C459),
  'yellow': Color(0xFFF5C518),
  'orange': Color(0xFFF08C00),
  'red': Color(0xFFD62828),
};
const unknownColor = Color(0xFF888780);

Color levelColor(String? level) => levelColors[level] ?? unknownColor;

List<LatLng> _points(dynamic geometry) => [
      for (final p in geometry as List<dynamic>)
        LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
    ];

double _d(dynamic value) => (value as num).toDouble();

/// Miejsce na trasie z komunikatem (ostrzeżenie oceny albo zakaz ruchu w czasie).
class RoutePlace {
  RoutePlace({
    required this.level,
    required this.message,
    required this.km,
    required this.point,
    this.limit,
    this.kind,
  });

  factory RoutePlace.fromJson(Map<String, dynamic> json, {String? level}) => RoutePlace(
        level: level ?? json['level'] as String,
        message: json['message'] as String,
        km: _d(json['km']),
        point: LatLng(_d(json['lat']), _d(json['lon'])),
        limit: json['limit'] as String?,
        kind: json['kind'] as String?,
      );

  final String level;
  final String message;
  final double km;
  final LatLng point;

  /// Wartość do znaku na mapie, np. "4,05 m".
  final String? limit;

  /// Rodzaj ostrzeżenia z oceny trasy, np. `reported` – ograniczenie zgłoszone przez kierowców.
  final String? kind;

  bool get reported => kind == 'reported';
}

/// Manewr z komunikatami w języku zapytania (Valhalla): napis, zapowiedź, tuż przed, po.
class Maneuver {
  const Maneuver({
    required this.type,
    required this.instruction,
    required this.km,
    required this.lengthKm,
    required this.point,
    this.alert,
    this.pre,
    this.post,
    this.streetNames = const [],
    this.exitNumber,
    this.toward = const [],
    this.branch = const [],
    this.roundaboutExit,
    this.lanes = const [],
  });

  factory Maneuver.fromJson(Map<String, dynamic> json) => Maneuver(
        type: json['type'] as int,
        instruction: json['instruction'] as String,
        alert: json['alert'] as String?,
        pre: json['pre'] as String?,
        post: json['post'] as String?,
        km: _d(json['km']),
        lengthKm: _d(json['length_km']),
        point: LatLng(_d(json['lat']), _d(json['lon'])),
        streetNames: _strings(json['street_names']),
        exitNumber: json['exit_number'] as String?,
        toward: _strings(json['toward']),
        branch: _strings(json['branch']),
        roundaboutExit: json['roundabout_exit'] as int?,
        lanes: [
          for (final lane in (json['lanes'] as List<dynamic>? ?? []))
            Lane(_strings((lane as Map)['directions']), active: lane['active'] == true),
        ],
      );

  /// Rodzaj manewru Valhalli (1–3 start, 4–6 cel, 9–16 skręty, 26–27 rondo…).
  final int type;
  final String instruction;
  final String? alert;
  final String? pre;
  final String? post;
  final double km;
  final double lengthKm;
  final LatLng point;

  /// Ulica / droga za manewrem, np. „DK94”, „ul. Krakowska”.
  final List<String> streetNames;

  /// Z tablicy: numer zjazdu, kierunki („Oświęcim”) i numery dróg („A4”).
  final String? exitNumber;
  final List<String> toward;
  final List<String> branch;

  /// Który zjazd z ronda.
  final int? roundaboutExit;
  final List<Lane> lanes;

  bool get arrival => type >= 4 && type <= 6;
}

List<String> _strings(dynamic value) => [for (final v in (value as List<dynamic>? ?? [])) '$v'];

/// Pas ruchu przed manewrem: strzałki (through, left, slight_right…) i czy to pas do jazdy.
class Lane {
  const Lane(this.directions, {this.active = false});

  final List<String> directions;
  final bool active;
}

/// Ograniczenie prędkości na kawałku trasy (indeksy punktów linii trasy).
class SpeedLimit {
  const SpeedLimit(this.start, this.end, this.kmh, {this.posted});

  final int start;
  final int end;
  final int kmh;

  /// Ze znaku; `null` – tylko limit krajowy dla ciężarówek.
  final int? posted;
}

/// Punkt z OSM na trasie: przejazd kolejowy, fotoradar, sygnalizacja, pomiar odcinkowy,
/// zakaz wyprzedzania (te dwa – odcinki z [endKm]).
class RoadEvent {
  const RoadEvent(this.kind, this.km, this.point, {this.endKm, this.speedKmh});

  factory RoadEvent.fromJson(Map<String, dynamic> json) => RoadEvent(
        json['kind'] as String,
        _d(json['km']),
        LatLng(_d(json['lat']), _d(json['lon'])),
        endKm: (json['end_km'] as num?)?.toDouble(),
        speedKmh: (json['speed_kmh'] as num?)?.toDouble(),
      );

  final String kind;
  final double km;
  final double? endKm;
  final LatLng point;
  final double? speedKmh;
}

/// Zgłoszenie kierowcy: punkt dostawy (brama, rampa…) albo problem na drodze.
class DriverReport {
  const DriverReport({
    required this.id,
    required this.kind,
    required this.label,
    required this.message,
    required this.point,
    this.score = 1,
    this.mine = false,
    this.distanceM,
    this.km,
  });

  factory DriverReport.fromJson(Map<String, dynamic> json) => DriverReport(
        id: json['id'] as String,
        kind: json['kind'] as String,
        label: json['label'] as String,
        message: json['message'] as String,
        point: LatLng(_d(json['lat']), _d(json['lon'])),
        score: json['score'] as int? ?? 1,
        mine: json['mine'] == true,
        distanceM: (json['distance_m'] as num?)?.toDouble(),
        km: (json['km'] as num?)?.toDouble(),
      );

  final String id;
  final String kind;
  final String label;
  final String message;
  final LatLng point;
  final int score;
  final bool mine;
  final double? distanceM;
  final double? km;
}

class Segment {
  const Segment(this.start, this.end, this.level);

  final int start;
  final int end;
  final String level;
}

/// Część kosztu z modułu kosztów: paliwo, AdBlue albo myto w jednym kraju.
class CostPart {
  const CostPart(this.kind, this.amount,
      {this.country = '', this.km, this.unknown = false, this.localAmount, this.localCurrency});

  final String kind;
  final double amount;
  final String country;
  final double? km;

  /// Myto: płatne drogi są, ale stawki dla pojazdu nie znamy.
  final bool unknown;

  /// Kwota w walucie kraju (np. myto w zł przy koszcie w euro) – pokazywana obok.
  final double? localAmount;
  final String? localCurrency;

  String money(AppLocalizations l, String currency) {
    final main = l.money(amount, currency);
    if (localAmount == null || localCurrency == null) return main;
    return l.costWithLocal(main, l.money(localAmount!, localCurrency!));
  }

  factory CostPart.fromJson(Map<String, dynamic> json) => CostPart(
        json['kind'] as String,
        _d(json['amount']),
        country: json['country'] as String? ?? '',
        km: (json['km'] as num?)?.toDouble(),
        unknown: json['unknown'] == true,
        localAmount: (json['local_amount'] as num?)?.toDouble(),
        localCurrency: json['local_currency'] as String?,
      );
}

class Cost {
  const Cost(this.amount, this.currency,
      {this.fuel, this.adblue, this.consumption, this.parts = const [], this.fuelPricesDay});

  final double amount;
  final String currency;

  /// Paliwo i AdBlue ze spalania pojazdu (części [amount]); `null` – nie liczone.
  final double? fuel;
  final double? adblue;
  final double? consumption;
  final List<CostPart> parts;

  /// Tydzień cen ON z Weekly Oil Bulletin KE, gdy z nich liczono paliwo.
  final DateTime? fuelPricesDay;

  static Cost? fromJson(dynamic json) => json == null
      ? null
      : Cost(
          _d(json['amount']),
          json['currency'] as String,
          fuel: (json['fuel'] as num?)?.toDouble(),
          adblue: (json['adblue'] as num?)?.toDouble(),
          consumption: (json['consumption'] as num?)?.toDouble(),
          parts: [
            for (final part in (json['parts'] as List<dynamic>? ?? [])) CostPart.fromJson(part as Map<String, dynamic>),
          ],
          fuelPricesDay: json['fuel_prices_day'] is String ? DateTime.tryParse(json['fuel_prices_day'] as String) : null,
        );

  /// „w tym paliwo ≈ 140 € (30/100 km), AdBlue ≈ 3 €” albo `null`, gdy paliwa nie liczono.
  String? summaryParts(AppLocalizations l) {
    if (fuel == null) return null;
    final volume = NumberFormat.decimalPattern(l.localeName).format(consumption ?? 0);
    return [
      l.costFuelPart(l.money(fuel!, currency), volume),
      if (adblue != null) l.costAdBluePart(l.money(adblue!, currency)),
    ].join(', ');
  }

  /// Wiersze per kraj: „DE: paliwo ≈ 138 €, myto ≈ 70 € (200 km)”; na końcu data cen ON.
  List<String> countryLines(AppLocalizations l) {
    final countries = <String>[];
    for (final part in parts) {
      if (part.country.isNotEmpty && !countries.contains(part.country)) countries.add(part.country);
    }
    String km(double? value) => NumberFormat.decimalPattern(l.localeName).format((value ?? 0).round());
    return [
      for (final country in countries)
        l.costCountryLine(country, [
          for (final part in parts.where((p) => p.country == country))
            switch (part.kind) {
              'fuel' => l.costFuelItem(part.money(l, currency)),
              'adblue' => l.costAdBluePart(part.money(l, currency)),
              'toll' when part.unknown => l.costTollUnknown(km(part.km)),
              'toll' => l.costTollItem(part.money(l, currency), km(part.km)),
              _ => '',
            },
        ].where((text) => text.isNotEmpty).join(', ')),
      if (fuelPricesDay != null) l.costFuelPricesDay(DateFormat.yMd(l.localeName).format(fuelPricesDay!)),
    ];
  }
}

/// Trasa (wybrana albo alternatywa) z oceną dla pojazdu.
class PlannedRoute {
  PlannedRoute({
    required this.distanceKm,
    required this.durationMin,
    required this.points,
    required this.level,
    required this.segments,
    required this.warnings,
    this.maneuvers = const [],
    this.cost,
    this.speedLimits = const [],
    this.roadEvents = const [],
  });

  factory PlannedRoute.fromJson(Map<String, dynamic> json) {
    final analysis = json['analysis'] as Map<String, dynamic>?;
    return PlannedRoute(
      distanceKm: _d(json['distance_km']),
      durationMin: _d(json['duration_min']),
      points: _points(json['geometry']),
      level: analysis?['level'] as String?,
      segments: [
        for (final s in (analysis?['segments'] as List<dynamic>? ?? []))
          Segment(s['start_index'] as int, s['end_index'] as int, s['level'] as String),
      ],
      warnings: [
        for (final w in (analysis?['warnings'] as List<dynamic>? ?? []))
          RoutePlace.fromJson(w as Map<String, dynamic>),
      ],
      maneuvers: [
        for (final m in (json['maneuvers'] as List<dynamic>? ?? [])) Maneuver.fromJson(m as Map<String, dynamic>),
      ],
      cost: Cost.fromJson(json['cost']),
      speedLimits: [
        for (final s in (json['speed_limits'] as List<dynamic>? ?? []))
          SpeedLimit(s['start_index'] as int, s['end_index'] as int, s['kmh'] as int, posted: s['posted'] as int?),
      ],
      roadEvents: [
        for (final e in (json['road_events'] as List<dynamic>? ?? [])) RoadEvent.fromJson(e as Map<String, dynamic>),
      ],
    );
  }

  final double distanceKm;
  final double durationMin;
  final List<LatLng> points;
  final String? level;
  final List<Segment> segments;
  final List<RoutePlace> warnings;
  final List<Maneuver> maneuvers;
  final Cost? cost;

  /// Ograniczenia prędkości i punkty z OSM – tylko w trasie wybranej (nie w alternatywach).
  final List<SpeedLimit> speedLimits;
  final List<RoadEvent> roadEvents;

  /// Kawałki linii trasy w kolorach oceny (bez oceny – jedna szara linia) – liczone raz (mapa rysuje je przy każdej pozycji GPS).
  late final List<(List<LatLng>, String)> coloredParts = segments.isEmpty
      ? [(points, 'unknown')]
      : [
          for (final s in segments)
            if (s.end < points.length) (points.sublist(s.start, s.end + 1), s.level),
        ];

  String summary(AppLocalizations l) {
    final hours = durationMin ~/ 60, minutes = (durationMin % 60).round();
    final text = l.routeSummary(distanceKm.round(), hours, minutes);
    return cost == null ? text : '$text · ${l.money(cost!.amount, cost!.currency)}';
  }
}

/// Kraj na trasie z wjazdem (przejście graniczne) i zakazami ruchu w czasie przejazdu.
class CountryOnRoute {
  CountryOnRoute({
    required this.country,
    required this.name,
    required this.km,
    required this.point,
    required this.border,
    required this.bans,
    required this.summary,
    this.enterAt,
  });

  factory CountryOnRoute.fromJson(Map<String, dynamic> json) => CountryOnRoute(
        country: json['country'] as String,
        name: json['name'] as String,
        km: (json['km'] as num).toDouble(),
        point: LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
        border: json['border'] as bool? ?? false,
        bans: json['bans'] as String? ?? 'no_data',
        summary: json['summary'] as String? ?? '',
        enterAt: json['enter_at'] == null ? null : DateTime.parse(json['enter_at'] as String).toLocal(),
      );

  final String country;
  final String name;
  final double km;
  final LatLng point;

  /// Wjazd przez granicę (`false` – kraj startu).
  final bool border;

  /// `ban`, `free`, `not_applicable`, `no_ban` albo `no_data` (kraj bez kalendarza zakazów).
  final String bans;

  /// Np. „zakaz do 22:00”, „brak danych” – w języku zapytania.
  final String summary;
  final DateTime? enterAt;
}

/// Odpowiedź planera (`POST /api/routes`).
class RouteResult {
  RouteResult({
    required this.route,
    required this.alternatives,
    required this.issues,
    required this.timeBans,
    this.destinationPoints = const [],
    this.driverReports = const [],
    this.arrival,
    this.waitMin = 0,
    this.freeDeparture,
    this.banCountries = const [],
    this.departure,
    this.countries = const [],
    this.avoidedWarnings = const [],
  });

  factory RouteResult.fromJson(Map<String, dynamic> json) {
    final bans = json['time_bans'] as Map<String, dynamic>?;
    return RouteResult(
      route: PlannedRoute.fromJson(json),
      alternatives: [
        for (final a in (json['alternatives'] as List<dynamic>? ?? []))
          PlannedRoute.fromJson(a as Map<String, dynamic>),
      ],
      issues: [
        for (final i in (json['stop_issues'] as List<dynamic>? ?? [])) '${(i as Map)['message']}',
      ],
      timeBans: [
        for (final b in (bans?['bans'] as List<dynamic>? ?? []))
          RoutePlace.fromJson(b as Map<String, dynamic>, level: 'ban'),
      ],
      destinationPoints: [
        for (final p in (json['destination_points'] as List<dynamic>? ?? []))
          DriverReport.fromJson(p as Map<String, dynamic>),
      ],
      driverReports: [
        for (final r in (json['driver_reports'] as List<dynamic>? ?? []))
          DriverReport.fromJson(r as Map<String, dynamic>),
      ],
      arrival: bans?['arrival'] == null ? null : DateTime.parse(bans!['arrival'] as String).toLocal(),
      waitMin: bans?['wait_min'] as int? ?? 0,
      freeDeparture:
          bans?['free_departure'] == null ? null : DateTime.parse(bans!['free_departure'] as String).toLocal(),
      banCountries: {for (final b in (bans?['bans'] as List<dynamic>? ?? [])) '${(b as Map)['country']}'}.toList(),
      departure: json['departure'] == null ? null : DateTime.parse(json['departure'] as String).toLocal(),
      countries: [
        for (final c in (json['countries'] as List<dynamic>? ?? []))
          CountryOnRoute.fromJson(c as Map<String, dynamic>),
      ],
      avoidedWarnings: [
        for (final w in (json['avoided_warnings'] as List<dynamic>? ?? []))
          RoutePlace.fromJson(w as Map<String, dynamic>),
      ],
    );
  }

  final PlannedRoute route;
  final List<PlannedRoute> alternatives;
  final List<String> issues;
  final List<RoutePlace> timeBans;

  /// Punkty dostawy zgłoszone przez kierowców przy celu (brama, rampa, godziny przyjęć).
  final List<DriverReport> destinationPoints;

  /// Problemy na drodze zgłoszone przez kierowców na linii trasy (bez wpływu na ocenę).
  final List<DriverReport> driverReports;
  final DateTime? arrival;
  final int waitMin;

  /// Najbliższy wyjazd bez postoju w czasie zakazów ruchu.
  final DateTime? freeDeparture;

  /// Kraje, w których trasa trafia na zakaz ruchu (do ekranu zakazów kraju).
  final List<String> banCountries;

  /// Wyjazd, dla którego liczono trasę i zakazy.
  final DateTime? departure;

  /// Kraje trasy proponowanej, po kolei, z przejściami granicznymi i zakazami.
  final List<CountryOnRoute> countries;

  /// Trudne miejsca ominięte objazdem (np. ograniczenie zgłoszone przez kierowców) – znaki na mapie.
  final List<RoutePlace> avoidedWarnings;
}
