import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'screens.dart';
import 'texts.dart';

/// Przestrzeń ładunkowa pojazdu: on sam albo podpięta naczepa / przyczepa (ciągnik nie ma swojej).
String? cargoVehicleId(Vehicle vehicle) {
  if (cargoKinds.contains(vehicle['kind'])) return '${vehicle['id']}';
  return vehicle['trailer_id'] == null ? null : '${vehicle['trailer_id']}';
}

/// Plan załadunku dla pojazdu z karty – pojazd wybrany z góry.
Future<bool> openLoadPlan(BuildContext context, CoreApi api, Vehicle vehicle) async {
  final t = LoadTexts.of(context);
  await Navigator.of(context).push<void>(MaterialPageRoute(
    builder: (_) => Scaffold(
      appBar: AppBar(title: Text('${t.moduleName}: ${vehicle['name']}')),
      body: LoadPlanScreen(api: api, vehicleId: cargoVehicleId(vehicle)),
    ),
  ));
  return false;
}

/// Sekcja karty pojazdu: plan załadunku jednym kliknięciem.
class LoadVehicleSection extends StatelessWidget {
  const LoadVehicleSection({super.key, required this.api, required this.vehicle});

  final CoreApi api;
  final Vehicle vehicle;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    return SectionCard(
      title: t.moduleName,
      icon: Icons.view_module_outlined,
      action: TextButton(onPressed: () => openLoadPlan(context, api, vehicle), child: Text(t.openPlan)),
      child: Text(t.sectionHint, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}
