import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../planner/place_field.dart' show Place;
import '../planner/route.dart' show PlannedRoute;
import '../service/revenue.dart';

/// „Wyślij kierowcy” z planera: wybór kierowcy firmy i uwagi, potem trasa trafia do jego
/// skrzynki (`POST /api/companies/{id}/route-assignments`). Opcjonalnie przychód zlecenia (kwota albo
/// stawka za km i waluta) – zapisany zaraz po wysłaniu. Zwraca imię kierowcy albo `null`.
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
  final amount = TextEditingController(), rate = TextEditingController();
  var currency = 'PLN';
  final send = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(l.livePlanSend),
        content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
          const SizedBox(height: 4),
          RevenueFields(
              amount: amount, rate: rate, currency: currency, onCurrency: (c) => setState(() => currency = c)),
        ])),
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
  final value = parseAmount(amount.text), perKm = parseAmount(rate.text);
  note.dispose();
  amount.dispose();
  rate.dispose();
  if (send != true) return null;
  Map<String, dynamic> stop(Place p) => {'lat': p.point.latitude, 'lon': p.point.longitude, 'label': p.label};
  try {
    final sent = await api.post('/api/companies/$companyId/route-assignments', {
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
    if ((value != null || perKm != null) && sent is Map) {
      try {
        await saveRevenue(api, companyId, '${sent['id']}',
            amount: value, ratePerKm: value == null ? perKm : null, currency: currency);
      } catch (error) {
        messenger?.showSnackBar(SnackBar(content: Text(l.revSaveFailed('$error'))));
        return name;
      }
    }
    messenger?.showSnackBar(SnackBar(content: Text(l.livePlanSent(name))));
    return name;
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
    return null;
  }
}
