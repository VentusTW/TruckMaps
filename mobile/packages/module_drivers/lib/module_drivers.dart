/// Moduł Kierowcy: kartoteka, kwalifikacje z terminami, przydział do pojazdów, przejazdy
/// (`/api/m/drivers/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/texts.dart';

export 'src/screens.dart';
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
}
