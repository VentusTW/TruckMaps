/// Moduł Plan załadunku: LDM, rozmieszczenie palet, środek ciężkości, mocowanie (`/api/m/load/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/texts.dart';

export 'src/deck_view.dart' show DeckCamera;
export 'src/screens.dart';
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
}
