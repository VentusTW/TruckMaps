import 'package:flutter/material.dart';
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
  RoutePlace({required this.level, required this.message, required this.km, required this.point, this.limit});

  factory RoutePlace.fromJson(Map<String, dynamic> json, {String? level}) => RoutePlace(
        level: level ?? json['level'] as String,
        message: json['message'] as String,
        km: _d(json['km']),
        point: LatLng(_d(json['lat']), _d(json['lon'])),
        limit: json['limit'] as String?,
      );

  final String level;
  final String message;
  final double km;
  final LatLng point;

  /// Wartość do znaku na mapie, np. "4,05 m".
  final String? limit;
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

  bool get arrival => type >= 4 && type <= 6;
}

class Segment {
  const Segment(this.start, this.end, this.level);

  final int start;
  final int end;
  final String level;
}

class Cost {
  const Cost(this.amount, this.currency);

  final double amount;
  final String currency;

  static Cost? fromJson(dynamic json) =>
      json == null ? null : Cost(_d(json['amount']), json['currency'] as String);
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

  /// Kawałki linii trasy w kolorach oceny (bez oceny – jedna szara linia).
  List<(List<LatLng>, String)> get coloredParts {
    if (segments.isEmpty) return [(points, 'unknown')];
    return [
      for (final s in segments)
        if (s.end < points.length) (points.sublist(s.start, s.end + 1), s.level),
    ];
  }

  String summary(AppLocalizations l) {
    final hours = durationMin ~/ 60, minutes = (durationMin % 60).round();
    final text = l.routeSummary(distanceKm.round(), hours, minutes);
    return cost == null ? text : '$text · ${l.money(cost!.amount, cost!.currency)}';
  }
}

/// Odpowiedź planera (`POST /api/routes`).
class RouteResult {
  RouteResult({
    required this.route,
    required this.alternatives,
    required this.issues,
    required this.timeBans,
    this.arrival,
    this.waitMin = 0,
    this.freeDeparture,
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
      arrival: bans?['arrival'] == null ? null : DateTime.parse(bans!['arrival'] as String).toLocal(),
      waitMin: bans?['wait_min'] as int? ?? 0,
      freeDeparture:
          bans?['free_departure'] == null ? null : DateTime.parse(bans!['free_departure'] as String).toLocal(),
    );
  }

  final PlannedRoute route;
  final List<PlannedRoute> alternatives;
  final List<String> issues;
  final List<RoutePlace> timeBans;
  final DateTime? arrival;
  final int waitMin;

  /// Najbliższy wyjazd bez postoju w czasie zakazów ruchu.
  final DateTime? freeDeparture;
}
