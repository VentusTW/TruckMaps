import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'texts.dart';

const _base = '/api/m/drivers';

/// „Przydziel kierowcę” przy pojeździe: kierowca z kartoteki (także bez konta), z uwagami
/// o uprawnieniach; „Bez kierowcy” zwalnia pojazd. `true` – przydział się zmienił.
Future<bool> assignDriverFromRegistry(BuildContext context, CoreApi api, Vehicle vehicle) async {
  final t = DriversTexts.of(context);
  final vehicleId = '${vehicle['id']}';
  void snack(String text) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  try {
    final drivers = [
      for (final d in (await api.get('$_base/drivers') as List<dynamic>).cast<Map<String, dynamic>>())
        if (d['company_id'] == vehicle['company_id'] && d['can_edit'] == true) d,
    ];
    bool drives(Map<String, dynamic> d) =>
        (d['vehicles'] as List<dynamic>? ?? const []).any((v) => '${(v as Map)['vehicle_id']}' == vehicleId);
    final current = drivers.where(drives).firstOrNull;
    if (!context.mounted) return false;
    final chosen = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(t.assignDriverTitle('${vehicle['name']}')),
        children: [
          if (drivers.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(t.noDriversToAssign)),
          for (final d in [
            {'id': '', 'name': t.noDriver},
            ...drivers,
          ])
            SimpleDialogOption(
              key: Key('assign-driver-${d['id']}'),
              onPressed: () => Navigator.pop(context, '${d['id']}'),
              child: Row(children: [
                Icon((d['id'] == (current?['id'] ?? '')) ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${d['name']}'),
                    if ((d['license_categories'] as List<dynamic>? ?? const []).isNotEmpty)
                      Text((d['license_categories'] as List<dynamic>).join(', '),
                          style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
              ]),
            ),
        ],
      ),
    );
    if (chosen == null || chosen == (current?['id'] ?? '') || !context.mounted) return false;
    if (chosen.isEmpty) {
      await api.post('$_base/drivers/${current!['id']}/release', {'vehicle_id': vehicleId});
      return true;
    }
    final check = await api.get('$_base/drivers/$chosen/check?vehicle_id=$vehicleId') as Map<String, dynamic>;
    final warnings = (check['warnings'] as List<dynamic>).cast<String>();
    if (warnings.isNotEmpty && context.mounted) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.warningsTitle),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (check['required_category'] != null) Text(t.needs('${check['required_category']}')),
            for (final w in warnings) Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $w')),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.assignAnyway)),
          ],
        ),
      );
      if (go != true) return false;
    }
    await api.post('$_base/drivers/$chosen/assign', {'vehicle_id': vehicleId});
    return true;
  } on ApiException catch (e) {
    if (context.mounted) snack(e.message);
    return false;
  }
}
