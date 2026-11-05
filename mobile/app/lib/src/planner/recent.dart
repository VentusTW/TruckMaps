import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:latlong2/latlong.dart';

import 'place_field.dart';

/// Ostatnio planowana trasa: skąd, dokąd i jakim pojazdem.
class RecentRoute {
  const RecentRoute({required this.from, required this.to, this.vehicleId, this.vehicleName});

  factory RecentRoute.fromJson(Map<String, dynamic> json) => RecentRoute(
        from: _place(json['from'] as Map<String, dynamic>),
        to: _place(json['to'] as Map<String, dynamic>),
        vehicleId: json['vehicle_id'] as String?,
        vehicleName: json['vehicle_name'] as String?,
      );

  final Place from;
  final Place to;
  final String? vehicleId;
  final String? vehicleName;

  Map<String, dynamic> toJson() => {
        'from': _json(from),
        'to': _json(to),
        if (vehicleId != null) 'vehicle_id': vehicleId,
        if (vehicleName != null) 'vehicle_name': vehicleName,
      };

  bool same(RecentRoute other) => other.from.label == from.label && other.to.label == to.label;

  static Place _place(Map<String, dynamic> j) =>
      Place('${j['label']}', LatLng((j['lat'] as num).toDouble(), (j['lon'] as num).toDouble()));

  static Map<String, dynamic> _json(Place p) => {'label': p.label, 'lat': p.point.latitude, 'lon': p.point.longitude};
}

/// Ostatnie wybory planera na urządzeniu: trasy i pojazd. Zapamiętane – mniej klikania przy następnej trasie.
class PlannerMemory extends ChangeNotifier {
  PlannerMemory([this._storage]);

  static const _routesKey = 'truckmaps.planner.recent';
  static const _vehicleKey = 'truckmaps.planner.vehicle';
  static const limit = 8;

  /// `null` – tylko w pamięci (testy).
  final FlutterSecureStorage? _storage;

  List<RecentRoute> _routes = const [];
  String? _vehicleId;
  bool _loaded = false;

  List<RecentRoute> get routes => _routes;
  String? get vehicleId => _vehicleId;

  /// Ostatnie miejsca (cele i starty) bez powtórzeń – do szybkiego wyboru w polach adresu.
  List<Place> get places {
    final seen = <String>{};
    return [
      for (final r in _routes)
        for (final p in [r.to, r.from])
          if (seen.add(p.label)) p,
    ];
  }

  Future<void> load() async {
    final storage = _storage;
    if (_loaded || storage == null) return;
    _loaded = true;
    try {
      final routes = await storage.read(key: _routesKey);
      final vehicle = await storage.read(key: _vehicleKey);
      _routes = routes == null
          ? const []
          : [for (final r in jsonDecode(routes) as List<dynamic>) RecentRoute.fromJson(r as Map<String, dynamic>)];
      _vehicleId = vehicle;
      notifyListeners();
    } catch (_) {
      // Bez magazynu (np. testy, brak uprawnień) – bez ostatnich wyborów.
    }
  }

  Future<void> addRoute(RecentRoute route) async {
    _routes = [
      route,
      for (final r in _routes)
        if (!r.same(route)) r
    ].take(limit).toList();
    if (route.vehicleId != null) _vehicleId = route.vehicleId;
    notifyListeners();
    await _save();
  }

  Future<void> setVehicle(String? id) async {
    if (id == _vehicleId) return;
    _vehicleId = id;
    await _save();
  }

  Future<void> _save() async {
    try {
      await _storage?.write(key: _routesKey, value: jsonEncode([for (final r in _routes) r.toJson()]));
      if (_vehicleId != null) await _storage?.write(key: _vehicleKey, value: _vehicleId);
    } catch (_) {}
  }
}
