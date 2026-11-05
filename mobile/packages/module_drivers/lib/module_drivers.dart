/// Moduł Kierowcy: kartoteka, kwalifikacje z terminami, przydział do pojazdów, przejazdy
/// (`/api/m/drivers/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/sections.dart';
import 'src/texts.dart';

export 'src/screens.dart';
export 'src/sections.dart';
export 'src/texts.dart';

class DriversModule extends TruckMapsModule {
  @override
  String get id => 'drivers';

  @override
  String name(Locale locale) => DriversTexts(locale).moduleName;

  @override
  String description(Locale locale) => DriversTexts(locale).moduleDescription;

  @override
  List<ModuleEntry> entries(ModuleContext context) => [
        ModuleEntry(
          title: DriversTexts(context.locale).menu,
          icon: Icons.badge_outlined,
          builder: (_) => DriversScreen(api: context.api),
        ),
      ];

  @override
  List<VehicleSection> vehicleSections(ModuleContext context) => [
        VehicleSection(
          id: 'drivers',
          order: 30,
          // Kartoteka dotyczy pojazdów firmy, które jeżdżą same.
          applies: (v) => v['company_id'] != null && drivableKinds.contains(v['kind']),
          builder: (_, vehicle) => DriversVehicleSection(api: context.api, vehicle: vehicle),
        ),
      ];

  @override
  List<DashboardSection> dashboardSections(ModuleContext context) => [
        DashboardSection(id: 'drivers', order: 30, builder: (_) => DriversDashboardSection(api: context.api)),
      ];
}
