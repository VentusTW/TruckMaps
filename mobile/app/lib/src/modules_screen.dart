import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

/// Lista modułów: aktywne, do kupienia i wymagające nowszej wersji aplikacji.
class ModulesScreen extends StatelessWidget {
  const ModulesScreen({super.key, required this.modules, this.error});

  final List<ModuleAccess> modules;
  final String? error;

  @override
  Widget build(BuildContext context) {
    if (error != null) return Center(child: Text(error!));
    if (modules.isEmpty) return const Center(child: Text('Na serwerze nie ma jeszcze modułów.'));
    return ListView(padding: const EdgeInsets.all(12), children: [
      for (final access in modules)
        Card(
          child: ListTile(
            leading: Icon(access.usable ? Icons.check_circle_outline : Icons.lock_outline),
            title: Text(access.name),
            subtitle: Text(access.needsAppUpdate
                ? 'Wymaga nowszej wersji aplikacji.'
                : access.usable
                    ? 'Aktywny'
                    : 'Nieaktywny – kup moduł, żeby z niego korzystać.'),
            trailing: access.usable || access.needsAppUpdate
                ? null
                : FilledButton.tonal(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => BuyModuleScreen(access: access)),
                    ),
                    child: const Text('Kup moduł'),
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
    return Scaffold(
      appBar: AppBar(title: const Text('Kup moduł')),
      body: ListView(padding: const EdgeInsets.all(24), children: [
        Text(access.name, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 8),
        Text(access.module?.description ?? ''),
        if (access.server.version != null) ...[
          const SizedBox(height: 4),
          Text('Wersja ${access.server.version}', style: theme.textTheme.bodySmall),
        ],
        const SizedBox(height: 24),
        const FilledButton(onPressed: null, child: Text('Kup w sklepie – wkrótce')),
        const SizedBox(height: 12),
        const Text('Moduł z firmowej licencji? Właściciel firmy przydzieli go w panelu floty.'),
      ]),
    );
  }
}
