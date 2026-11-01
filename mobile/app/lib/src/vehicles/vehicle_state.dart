import 'package:flutter/material.dart';

import '../l10n.dart';

/// Stan pojazdu na liście – według ważności: naprawa, zgłoszona usterka, w użyciu.
enum VehicleState { repair, reported, inUse, free }

VehicleState vehicleState(Map<String, dynamic> v) => v['in_repair'] == true
    ? VehicleState.repair
    : v['repair_reported'] == true
        ? VehicleState.reported
        : v['in_use'] == true
            ? VehicleState.inUse
            : VehicleState.free;

/// Kolor stanu: czerwony – w naprawie, żółty – zgłoszona usterka, niebieski – w użyciu / podpięta.
Color? stateColor(BuildContext context, VehicleState state) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (state) {
    VehicleState.repair => Theme.of(context).colorScheme.error,
    VehicleState.reported => dark ? Colors.amber.shade300 : Colors.amber.shade800,
    VehicleState.inUse => dark ? Colors.lightBlue.shade300 : Colors.blue.shade700,
    VehicleState.free => null,
  };
}

/// Tło wiersza / kafelka w kolorze stanu; w naprawie – wyraźnie na czerwono (wyłączony z użytku).
Color? stateTint(BuildContext context, VehicleState state) {
  if (state == VehicleState.repair) return Theme.of(context).colorScheme.errorContainer;
  final color = stateColor(context, state);
  return color == null ? null : Color.alphaBlend(color.withOpacity(0.14), Theme.of(context).colorScheme.surface);
}

/// Opis stanu (`null` – wolny).
String? stateText(AppLocalizations l, Map<String, dynamic> v) => switch (vehicleState(v)) {
      VehicleState.repair => l.vehicleInRepair,
      VehicleState.reported => l.vehicleRepairReported,
      VehicleState.inUse =>
        v['coupled_to_name'] != null ? l.vehicleCoupledTo('${v['coupled_to_name']}') : l.vehicleInUse,
      VehicleState.free => null,
    };

/// Objaśnienie kolorów – tylko stany, które są na liście.
class StateLegend extends StatelessWidget {
  const StateLegend({super.key, required this.states});

  final Set<VehicleState> states;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final labels = {
      VehicleState.inUse: l.vehicleLegendInUse,
      VehicleState.reported: l.vehicleRepairReported,
      VehicleState.repair: l.vehicleInRepair,
    };
    return Wrap(spacing: 16, runSpacing: 4, children: [
      for (final MapEntry(key: state, value: label) in labels.entries)
        if (states.contains(state))
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.circle, size: 12, color: stateColor(context, state)),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ]),
    ]);
  }
}
