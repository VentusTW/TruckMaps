import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../planner/place_field.dart' show Place;
import '../planner/route.dart' show PlannedRoute;

/// „Wyślij kierowcy” z planera: wybór kierowcy firmy i uwagi, potem trasa trafia do jego
/// skrzynki (`POST /api/companies/{id}/route-assignments`). Zwraca imię kierowcy albo `null`.
Future<String?> sendRouteToDriver(
  BuildContext context, {
  required CoreApi api,
  required String companyId,
  required String vehicleId,
  required Place start,
  required Place end,
  required List<Place> via,
  required PlannedRoute route,
  required bool avoidDifficult,
}) async {
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final List<(String, String)> drivers;
  try {
    final company = await api.get('/api/companies/$companyId') as Map<String, dynamic>;
    drivers = [
      for (final m in (company['members'] as List<dynamic>).cast<Map<String, dynamic>>())
        if (m['role'] == 'driver') ('${m['id']}', '${m['display_name']}'),
    ];
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
    return null;
  }
  if (!context.mounted) return null;
  if (drivers.isEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text(l.livePlanNoDrivers)));
    return null;
  }
  var driver = drivers.first.$1;
  final note = TextEditingController();
  final send = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l.livePlanSend),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('${start.label} → ${end.label}'),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: driver,
            decoration: InputDecoration(labelText: l.livePlanDriver, border: const OutlineInputBorder()),
            items: [for (final (id, name) in drivers) DropdownMenuItem(value: id, child: Text(name))],
            onChanged: (id) => setState(() => driver = id ?? driver),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: note,
            maxLength: 500,
            maxLines: 2,
            decoration: InputDecoration(labelText: l.livePlanNote, border: const OutlineInputBorder()),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton.icon(
            key: const Key('send-route-confirm'),
            onPressed: () => Navigator.pop(context, true),
            icon: const Icon(Icons.send),
            label: Text(l.livePlanSend),
          ),
        ],
      ),
    ),
  );
  final text = note.text.trim();
  note.dispose();
  if (send != true) return null;
  Map<String, dynamic> stop(Place p) => {'lat': p.point.latitude, 'lon': p.point.longitude, 'label': p.label};
  try {
    await api.post('/api/companies/$companyId/route-assignments', {
      'vehicle_id': vehicleId,
      'driver_member_id': driver,
      'origin': stop(start),
      'destination': stop(end),
      'via': [for (final v in via) stop(v)],
      'avoid_difficult': avoidDifficult,
      'note': text,
      'distance_km': route.distanceKm,
      'duration_min': route.durationMin,
    });
    final name = drivers.firstWhere((d) => d.$1 == driver).$2;
    messenger?.showSnackBar(SnackBar(content: Text(l.livePlanSent(name))));
    return name;
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
    return null;
  }
}
