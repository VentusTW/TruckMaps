import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'account/common.dart';
import 'company/admin_access_screen.dart';
import 'l10n.dart';

/// Skrzynka wiadomości: prośby administratora TruckMaps o dostęp (wyróżnione, z decyzją od razu),
/// prośby o przedłużenie i informacje o zamknięciu dostępu. Tekst składa aplikacja z rodzaju
/// wiadomości – w języku użytkownika.
class InboxScreen extends StatefulWidget {
  const InboxScreen({super.key, required this.api, this.onChanged});

  final CoreApi api;

  /// Po przeczytaniu albo decyzji – licznik nieprzeczytanych w menu.
  final VoidCallback? onChanged;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  late Future<dynamic> _messages = _load();

  /// Informacje bez decyzji są przeczytane, gdy tylko pojawią się na ekranie.
  Future<dynamic> _load() async {
    final inbox = await widget.api.get('/api/me/messages') as Map<String, dynamic>;
    final items = (inbox['items'] as List<dynamic>).cast<Map<String, dynamic>>();
    final seen = items.where((m) => m['read'] != true && !_actionable(m)).toList();
    for (final message in seen) {
      await widget.api.post('/api/me/messages/${message['id']}/read', null);
    }
    if (seen.isNotEmpty) widget.onChanged?.call();
    return inbox;
  }

  void _reload() {
    final messages = _load();
    setState(() {
      _messages = messages;
    });
  }

  /// Prośba, na którą właściciel może jeszcze odpowiedzieć.
  bool _actionable(Map<String, dynamic> message) {
    final state = (message['grant'] as Map<String, dynamic>?)?['state'];
    return switch (message['kind']) {
      'admin_access_request' => state == 'pending',
      'admin_extension_request' => state == 'active',
      _ => false,
    };
  }

  Future<void> _decide(Map<String, dynamic> message, String action, [int? minutes]) async {
    final path = '/api/companies/${message['company_id']}/admin-access/${message['grant_id']}/$action';
    try {
      await widget.api.post(path, minutes == null ? null : {'minutes': minutes});
      if (!mounted) return;
      _reload();
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return FutureBuilder<dynamic>(
      future: _messages,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text('${snapshot.error}'),
            TextButton(onPressed: _reload, child: Text(l.retry)),
          ]);
        }
        if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
        final items = ((snapshot.data as Map<String, dynamic>)['items'] as List<dynamic>).cast<Map<String, dynamic>>();
        if (items.isEmpty) return Padding(padding: const EdgeInsets.all(16), child: Text(l.inboxEmpty));
        return RefreshIndicator(
          onRefresh: () async => _reload(),
          child: ListView(padding: const EdgeInsets.all(16), children: [for (final m in items) _message(l, m)]),
        );
      },
    );
  }

  Widget _message(AppLocalizations l, Map<String, dynamic> message) {
    final theme = Theme.of(context);
    final actionable = _actionable(message);
    final data = (message['data'] as Map<String, dynamic>?) ?? const {};
    final admin = '${message['sender_name']}'.isEmpty ? l.inboxAdmin : '${message['sender_name']}';
    final when = l.when(DateTime.parse('${message['created_at']}').toLocal());
    final (title, body) = switch (message['kind']) {
      'admin_access_request' => (
          l.inboxAccessRequest(admin),
          [
            (data['scopes'] as List<dynamic>? ?? []).map((s) => scopeLabel(l, '$s')).join(', '),
            if ('${data['note'] ?? ''}'.isNotEmpty) '„${data['note']}”',
            if (actionable) l.inboxAccessRequestHint else _outcome(l, message),
          ].join('\n')
        ),
      'admin_extension_request' => (
          l.inboxExtensionRequest(admin, grantDuration(l, data['minutes'] as int? ?? 60)),
          actionable ? l.inboxExtensionHint : _outcome(l, message)
        ),
      'admin_access_closed' => (l.inboxAccessClosed(admin), ''),
      _ => ('${message['kind']}', ''),
    };
    return Card(
      // Prośba czekająca na decyzję wyróżnia się kolorem – to zmiany w danych firmy.
      color: actionable ? theme.colorScheme.tertiaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(actionable ? Icons.admin_panel_settings : Icons.mail_outline),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
            Text(when, style: theme.textTheme.bodySmall),
          ]),
          if (body.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(body)),
          if (actionable)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                if (message['kind'] == 'admin_access_request') ...[
                  FilledButton(
                    onPressed: () => _decide(message, 'accept', grantMinutes),
                    child: Text(l.inboxAccept(grantDuration(l, grantMinutes))),
                  ),
                  OutlinedButton(onPressed: () => _decide(message, 'reject'), child: Text(l.inboxReject)),
                ] else
                  FilledButton(
                    onPressed: () => _decide(message, 'extend', data['minutes'] as int? ?? 60),
                    child: Text(l.inboxExtend(grantDuration(l, data['minutes'] as int? ?? 60))),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }

  String _outcome(AppLocalizations l, Map<String, dynamic> message) =>
      grantStateLabel(l, message['grant'] as Map<String, dynamic>?);
}
