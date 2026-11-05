/// Moduł Serwis: zgłoszenia usterek, zlecenia i protokoły napraw (`/api/m/service/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/sections.dart';
import 'src/texts.dart';

export 'src/screens.dart';
export 'src/sections.dart';
export 'src/texts.dart';

class ServiceModule extends TruckMapsModule {
  @override
  String get id => 'service';

  @override
  String name(Locale locale) => ServiceTexts(locale).moduleName;

  @override
  String description(Locale locale) => ServiceTexts(locale).moduleDescription;

  @override
  List<ModuleEntry> entries(ModuleContext context) => [
        ModuleEntry(
          title: ServiceTexts(context.locale).menu,
          icon: Icons.build_outlined,
          builder: (_) => ServiceScreen(api: context.api),
        ),
      ];

  @override
  List<VehicleAction> vehicleActions(ModuleContext context) => [
        VehicleAction(
          id: 'service-report',
          label: ServiceTexts(context.locale).report,
          icon: Icons.report_problem_outlined,
          run: (ctx, vehicle) => reportFault(ctx, context.api, vehicle),
        ),
      ];

  @override
  List<VehicleSection> vehicleSections(ModuleContext context) => [
        VehicleSection(
          id: 'service',
          order: 50,
          builder: (_, vehicle) => ServiceVehicleSection(api: context.api, vehicle: vehicle),
        ),
      ];

  @override
  List<DashboardSection> dashboardSections(ModuleContext context) => [
        DashboardSection(id: 'service', order: 20, builder: (_) => ServiceDashboardSection(api: context.api)),
      ];
}
