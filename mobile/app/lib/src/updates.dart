import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Wersja aplikacji – ta sama co `version` w `pubspec.yaml` (pilnuje tego test).
const appVersion = '0.1.0';

/// Nazwa aplikacji w katalogu wydań serwera (`kind=app`).
const appName = 'truckmaps';

/// Platforma w nazewnictwie serwera (`/api/updates/check`).
String currentPlatform() => kIsWeb
    ? 'web'
    : switch (defaultTargetPlatform) {
        TargetPlatform.android => 'android',
        TargetPlatform.iOS => 'ios',
        TargetPlatform.macOS => 'macos',
        TargetPlatform.linux => 'linux',
        _ => 'windows',
      };

/// Nowsze wydania (albo powrót z wycofanego) dla tego, co jest zainstalowane.
/// Bez połączenia albo przy błędzie serwera – pusta lista: aktualizacja nigdy nie blokuje jazdy.
Future<List<Map<String, dynamic>>> checkUpdates(CoreApi api) async {
  try {
    final found = await api.post('/api/updates/check', {
      'platform': currentPlatform(),
      'installed': [
        {'kind': 'app', 'name': appName, 'version': appVersion},
      ],
    }) as List<dynamic>;
    return found.cast<Map<String, dynamic>>();
  } catch (_) {
    return const [];
  }
}

/// Pytanie o pobranie: wersja, rozmiar, lista zmian. „Później” – zapytamy przy następnym uruchomieniu.
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.updates, required this.onDownload});

  final List<Map<String, dynamic>> updates;
  final ValueChanged<Map<String, dynamic>> onDownload;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final rollback = updates.any((u) => u['action'] == 'rollback');
    return AlertDialog(
      title: Text(rollback ? l.updateRollbackTitle : l.updateTitle),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final update in updates) ...[
              Text(
                l.updateVersion('${update['installed_version']}', '${update['version']}',
                    l.number((update['size_bytes'] as num) / 1e6, decimals: 1)),
                style: theme.textTheme.titleSmall,
              ),
              if (update['action'] == 'rollback') Text(l.updateRollbackHint),
              if ('${update['notes']}'.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('${update['notes']}')),
              const SizedBox(height: 12),
            ],
            Text(l.updateWifiHint, style: theme.textTheme.bodySmall),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.updateLater)),
        FilledButton.icon(
          onPressed: () {
            Navigator.pop(context);
            for (final update in updates) {
              onDownload(update);
            }
          },
          icon: const Icon(Icons.download),
          label: Text(l.updateDownload),
        ),
      ],
    );
  }
}
