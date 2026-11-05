import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import 'service_dates.dart';
import 'vehicle_form.dart';
import 'vehicle_state.dart';

/// Akcje pojazdu wspólne dla listy i karty pojazdu. Każda zwraca `true`, gdy coś zmieniła.

String vehicleTitle(Map<String, dynamic> v) {
  final plate = '${v['plate'] ?? ''}';
  return plate.isEmpty ? '${v['name']}' : '${v['name']} · $plate';
}

void _snack(BuildContext context, Object error) =>
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));

/// Kierowcę przydziela się pojazdom firmy, które jeżdżą same; zmieniają zarządzający.
bool canAssignDriver(Map<String, dynamic> v) =>
    v['can_edit'] != false && v['company_id'] != null && !towedKinds.contains(v['kind']);

/// W użyciu dla [vehicle]: podpięta gdzie indziej (do tego pojazdu – nie przeszkadza).
bool trailerBusy(Map<String, dynamic> trailer, Map<String, dynamic> vehicle) =>
    trailer['in_use'] == true && trailer['coupled_to_id'] != vehicle['id'];

/// Wolne naczepy / przyczepy pasujące do [vehicle] – do podpięcia jednym kliknięciem.
List<Map<String, dynamic>> freeTrailers(Map<String, dynamic> vehicle, Iterable<Map<String, dynamic>> all) => [
      for (final t in all)
        if (t['kind'] == couples[vehicle['kind']] && !trailerBusy(t, vehicle) && t['id'] != vehicle['trailer_id']) t,
    ];

Future<bool> openVehicleForm(BuildContext context, CoreApi api, [Map<String, dynamic>? vehicle]) async {
  final saved = await Navigator.of(context)
      .push<dynamic>(MaterialPageRoute(builder: (_) => VehicleFormScreen(api: api, vehicle: vehicle)));
  return saved != null;
}

Future<bool> openServiceDates(BuildContext context, CoreApi api, Map<String, dynamic> vehicle) async {
  final saved = await Navigator.of(context)
      .push<dynamic>(MaterialPageRoute(builder: (_) => ServiceDatesScreen(api: api, vehicle: vehicle)));
  return saved != null;
}

/// Przydział kierowcy: członek firmy albo bez przydziału.
Future<bool> assignDriver(BuildContext context, CoreApi api, Map<String, dynamic> vehicle) async {
  final l = context.l;
  final Map<String, dynamic> company;
  try {
    company = await api.get('/api/companies/${vehicle['company_id']}') as Map<String, dynamic>;
  } catch (error) {
    if (context.mounted) _snack(context, error);
    return false;
  }
  if (!context.mounted) return false;
  final members = (company['members'] as List<dynamic>).cast<Map<String, dynamic>>();
  final chosen = await showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l.vehicleDriverTitle('${vehicle['name']}')),
      children: [
        for (final m in [
          {'id': '', 'display_name': l.vehicleNoDriver},
          ...members,
        ])
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, '${m['id']}'),
            child: Row(children: [
              Icon((m['id'] == (vehicle['assigned_member_id'] ?? ''))
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked),
              const SizedBox(width: 12),
              Expanded(child: Text('${m['display_name']}')),
            ]),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return false;
  try {
    await api.put('/api/vehicles/${vehicle['id']}/driver', {'member_id': chosen.isEmpty ? null : chosen});
    return true;
  } catch (error) {
    if (context.mounted) _snack(context, error);
    return false;
  }
}

Future<bool> deleteVehicle(BuildContext context, CoreApi api, Map<String, dynamic> vehicle) async {
  final l = context.l;
  final sure = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.vehicleDeleteTitle),
      content: Text(l.vehicleDeleteQuestion('${vehicle['name']}')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
      ],
    ),
  );
  if (sure != true || !context.mounted) return false;
  try {
    await api.delete('/api/vehicles/${vehicle['id']}');
    return true;
  } catch (error) {
    if (context.mounted) _snack(context, error);
    return false;
  }
}

/// Podpięcie naczepy / przyczepy do pojazdu ([trailer] `null` – odpięcie).
Future<bool> coupleTrailer(
    BuildContext context, CoreApi api, Map<String, dynamic> vehicle, Map<String, dynamic>? trailer) async {
  try {
    await api.put('/api/vehicles/${vehicle['id']}/trailer', {'trailer_id': trailer?['id']});
    return true;
  } catch (error) {
    if (context.mounted) _snack(context, error);
    return false;
  }
}

/// „Podepnij”: lista pasujących naczep / przyczep; te w użyciu – w kolorze stanu i nie do wybrania.
Future<bool> chooseTrailer(
    BuildContext context, CoreApi api, Map<String, dynamic> vehicle, List<Map<String, dynamic>> trailers) async {
  final l = context.l;
  final fitting = [
    for (final t in trailers)
      if (t['kind'] == couples[vehicle['kind']]) t
  ];
  final chosen = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => SimpleDialog(
      title: Text(l.couplingChoose('${vehicle['name']}')),
      children: [
        if (fitting.isEmpty)
          Padding(
              padding: const EdgeInsets.all(24), child: Text(l.couplingNone(kindLabel(l, couples[vehicle['kind']])))),
        for (final t in fitting)
          ColoredBox(
            color: (trailerBusy(t, vehicle) ? stateTint(context, vehicleState(t)) : null) ?? Colors.transparent,
            child: SimpleDialogOption(
              onPressed: trailerBusy(t, vehicle) ? null : () => Navigator.pop(context, t),
              child: ListTile(
                leading: Icon(kindIcon(t['kind'] as String?)),
                title: Text(vehicleTitle(t)),
                subtitle:
                    Text(trailerBusy(t, vehicle) ? stateText(l, t) ?? '' : trailerLabel(l, '${t['trailer_type']}')),
              ),
            ),
          ),
      ],
    ),
  );
  if (chosen == null || !context.mounted) return false;
  return coupleTrailer(context, api, vehicle, chosen);
}
