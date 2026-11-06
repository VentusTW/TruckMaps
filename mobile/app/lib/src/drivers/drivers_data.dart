import 'package:core_sdk/core_sdk.dart';

import '../dashboard/main_dashboard.dart' show uiMaps;

/// Dane ekranów kierowców: kartoteka modułu Kierowcy (`/api/m/drivers`), a bez modułu – członkowie
/// firmy z rolą kierowcy (rdzeń). Do tego pojazdy firmy (kto jedzie, przydział, naczepa).
class DriversData {
  DriversData({required this.drivers, required this.vehicles, required this.module});

  /// Karty kierowców (pola jak `DriverOut` modułu; bez modułu – tylko `id`, `name`, `member_id`).
  final List<Map<String, dynamic>> drivers;
  final List<Map<String, dynamic>> vehicles;

  /// Kartoteka z modułu Kierowcy (terminy, kontakt, kategorie) – inaczej tylko rdzeń.
  final bool module;

  static Future<DriversData> load(CoreApi api, String companyId) async {
    final q = Uri.encodeQueryComponent(companyId);
    final vehicles = [
      for (final v in uiMaps(await api.get('/api/vehicles')))
        if (v['company_id'] == companyId) v
    ];
    try {
      final drivers = uiMaps(await api.get('/api/m/drivers/drivers?company_id=$q'));
      return DriversData(drivers: drivers, vehicles: vehicles, module: true);
    } on ApiException {
      // Moduł Kierowcy nieaktywny – lista z członków firmy.
    }
    final company = await api.get('/api/companies/$q');
    final members = uiMaps(company is Map ? company['members'] : null);
    return DriversData(
      drivers: [
        for (final m in members)
          if (m['role'] == 'driver') {'id': 'member:${m['id']}', 'name': m['display_name'], 'member_id': m['id']}
      ],
      vehicles: vehicles,
      module: false,
    );
  }

  Map<String, dynamic>? byId(String id) => drivers.where((d) => d['id'] == id).firstOrNull;

  Map<String, dynamic>? byName(String name) => drivers.where((d) => d['name'] == name).firstOrNull;

  /// Pojazd, którym kierowca jedzie albo który ma przydzielony.
  Map<String, dynamic>? vehicleOf(Map<String, dynamic> d) {
    final refs = uiMaps(d['vehicles']);
    final name = d['member_name'] ?? d['name'];
    return vehicles.where((v) => refs.any((r) => r['vehicle_id'] == v['id'])).firstOrNull ??
        vehicles.where((v) => v['driver_name'] == name || v['assigned_driver_name'] == name).firstOrNull;
  }

  Map<String, dynamic>? trailerOf(Map<String, dynamic>? v) =>
      v == null ? null : vehicles.where((t) => t['id'] == v['trailer_id']).firstOrNull;

  /// Jedzie teraz (nawigacja TruckMaps w pojeździe firmy).
  bool driving(Map<String, dynamic> d) {
    final v = vehicleOf(d);
    final name = d['member_name'] ?? d['name'];
    return v != null && v['in_use'] == true && v['driver_name'] == name;
  }
}

DateTime? parseDay(dynamic s) => s == null ? null : DateTime.tryParse('$s');

/// Inicjały do awatara (bez zdjęć w kartotece).
String initials(String name) =>
    name.trim().split(RegExp(r'\s+')).take(2).map((p) => p.isEmpty ? '' : p[0]).join().toUpperCase();
