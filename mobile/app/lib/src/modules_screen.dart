import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Lista modułów: aktywne, do kupienia i wymagające nowszej wersji aplikacji.
class ModulesScreen extends StatelessWidget {
  const ModulesScreen({super.key, required this.modules, this.error});

  final List<ModuleAccess> modules;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    if (error != null) return Center(child: Text(error!));
    if (modules.isEmpty) return Center(child: Text(l.modulesEmpty));
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final access in modules)
        Card(
          child: ListTile(
            leading: Icon(access.usable ? Icons.check_circle_outline : Icons.lock_outline),
            title: Text(access.name(Localizations.localeOf(context))),
            subtitle: Text(access.needsAppUpdate
                ? l.moduleNeedsUpdate
                : access.usable
                    ? l.moduleActive
                    : l.moduleInactive),
            trailing: access.usable || access.needsAppUpdate
                ? null
                : FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => BuyModuleScreen(access: access)),
                    ),
                    child: Text(l.buyModule),
                  ),
          ),
        ),
    ]);
  }
}

/// Ekran „Kup moduł”. Zakupy w sklepach (Google Play, App Store) i licencje firmowe
/// z panelu floty będą później – na razie dostęp nadaje się na serwerze.
class BuyModuleScreen extends StatelessWidget {
  const BuyModuleScreen({super.key, required this.access});

  final ModuleAccess access;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = context.l;
    final locale = Localizations.localeOf(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.buyModule)),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Text(access.name(locale), style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(access.module?.description(locale) ?? ''),
        if (access.server.version != null) ...[
          const SizedBox(height: 4),
          Text(l.moduleVersion('${access.server.version}'), style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 24),
        FilledButton(onPressed: null, child: Text(l.buyInStoreSoon)),
        const SizedBox(height: 12),
        Text(l.moduleFromCompanyLicense),
      ]),
    );
  }
}
