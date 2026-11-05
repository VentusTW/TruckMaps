/// Moduł Plan załadunku: LDM, rozmieszczenie palet, środek ciężkości, mocowanie (`/api/m/load/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/sections.dart';
import 'src/texts.dart';

export 'src/screens.dart';
export 'src/sections.dart';
export 'src/texts.dart';

class LoadModule extends TruckMapsModule {
  @override
  String get id => 'load';

  @override
  String name(Locale locale) => LoadTexts(locale).moduleName;

  @override
  String description(Locale locale) => LoadTexts(locale).moduleDescription;

  @override
  List<ModuleEntry> entries(ModuleContext context) => [
        ModuleEntry(
          title: LoadTexts(context.locale).menu,
          icon: Icons.view_module_outlined,
          builder: (_) => LoadPlanScreen(api: context.api),
        ),
      ];

  @override
  List<VehicleAction> vehicleActions(ModuleContext context) => [
        VehicleAction(
          id: 'load-plan',
          label: LoadTexts(context.locale).moduleName,
          icon: Icons.view_module_outlined,
          applies: (v) => cargoVehicleId(v) != null,
          run: (ctx, vehicle) => openLoadPlan(ctx, context.api, vehicle),
        ),
      ];

  @override
  List<VehicleSection> vehicleSections(ModuleContext context) => [
        VehicleSection(
          id: 'load',
          order: 60,
          applies: (v) => cargoVehicleId(v) != null,
          builder: (_, vehicle) => LoadVehicleSection(api: context.api, vehicle: vehicle),
        ),
      ];
}
