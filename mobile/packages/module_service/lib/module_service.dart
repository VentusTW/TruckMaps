/// Moduł Serwis: zgłoszenia usterek, zlecenia i protokoły napraw (`/api/m/service/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/texts.dart';

export 'src/screens.dart';
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
}
