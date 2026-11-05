/// Moduł Dokumenty: CMR, zlecenie transportowe, karta drogowa – szablony firmy, autouzupełnianie
/// z danych systemu, PDF (`/api/m/documents/...`).
library;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'src/screens.dart';
import 'src/texts.dart';

export 'src/screens.dart';
export 'src/texts.dart';

class DocumentsModule extends TruckMapsModule {
  @override
  String get id => 'documents';

  @override
  String name(Locale locale) => DocumentsTexts(locale).moduleName;

  @override
  String description(Locale locale) => DocumentsTexts(locale).moduleDescription;

  @override
  List<ModuleEntry> entries(ModuleContext context) => [
        ModuleEntry(
          title: DocumentsTexts(context.locale).menu,
          icon: Icons.description_outlined,
          builder: (_) => DocumentsScreen(api: context.api),
        ),
      ];

  @override
  List<VehicleAction> vehicleActions(ModuleContext context) => [
        VehicleAction(
          id: 'documents',
          label: DocumentsTexts(context.locale).add,
          icon: Icons.description_outlined,
          // Dokumenty prowadzi firma – pojazdy prywatne bez nich.
          applies: (v) => v['company_id'] != null,
          run: (ctx, vehicle) async {
            final kind = await chooseKind(ctx, context.api);
            if (kind == null || !ctx.mounted) return false;
            await Navigator.of(ctx).push<void>(MaterialPageRoute(
              builder: (_) => DocumentFormScreen(
                api: context.api,
                companyId: '${vehicle['company_id']}',
                kind: kind,
                vehicleId: '${vehicle['id']}',
              ),
            ));
            return false;
          },
        ),
      ];
}
