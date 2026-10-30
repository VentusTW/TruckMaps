import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Ostrzeżenia o końcu dostępu: okno 10 i 5 minut przed końcem, od 2 minut odliczanie na pasku.
const warnings = [Duration(minutes: 10), Duration(minutes: 5)];
const countdownFrom = Duration(minutes: 2);

/// Które ostrzeżenie pokazać przy [left] do końca (`null` – żadnego, poza oknem ostrzeżeń).
Duration? warningFor(Duration left) {
  if (left <= countdownFrom) return null;
  for (final warning in warnings.reversed) {
    if (left <= warning) return warning;
  }
  return null;
}

/// „4:05” – minuty i sekundy do końca.
String clock(Duration left) {
  final seconds = left.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

Duration leftOf(Map<String, dynamic> grant, DateTime now) => DateTime.parse('${grant['expires_at']}').difference(now);

/// Pasek u góry: prośba czeka albo dostęp aktywny (z przyciskami), a od 2 minut – odliczanie.
class GrantBar extends StatelessWidget {
  const GrantBar({super.key, required this.grant, required this.now, required this.onExtend, required this.onClose});

  final Map<String, dynamic> grant;
  final DateTime now;
  final VoidCallback onExtend;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    final company = '${grant['company_name']}';
    final pending = grant['state'] == 'pending';
    final left = pending ? null : leftOf(grant, now);
    final urgent = left != null && left <= countdownFrom;
    final text = pending
        ? l.grantPendingBar(company)
        : urgent
            ? l.grantCountdown(company, clock(left))
            : l.grantActiveBar(company, l.when(DateTime.parse('${grant['expires_at']}')));
    final color = urgent ? scheme.errorContainer : scheme.secondaryContainer;
    return Material(
      color: color,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(children: [
          Icon(pending
              ? Icons.hourglass_top
              : urgent
                  ? Icons.timer
                  : Icons.lock_open),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text,
                style: urgent ? Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold) : null),
          ),
          if (!pending) TextButton(onPressed: onExtend, child: Text(l.grantRequestExtension)),
          TextButton(onPressed: onClose, child: Text(pending ? l.grantCancelRequest : l.grantClose)),
        ]),
      ),
    );
  }
}

/// Prośba o dostęp do zmian w firmie: zakres i powód (właściciel zobaczy go w skrzynce).
class RequestDialog extends StatefulWidget {
  const RequestDialog({super.key, required this.api, required this.companyId});

  final CoreApi api;
  final String companyId;

  @override
  State<RequestDialog> createState() => _RequestDialogState();
}

class _RequestDialogState extends State<RequestDialog> {
  final _note = TextEditingController();
  final _scopes = <String>{'company'};
  String? _error;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    try {
      await widget.api.post('/api/admin/companies/${widget.companyId}/access-requests', {
        'scopes': [
          for (final s in const ['company', 'bases'])
            if (_scopes.contains(s)) s
        ],
        'note': _note.text.trim(),
      });
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      title: Text(l.requestTitle),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.requestHint),
          for (final scope in const ['company', 'bases'])
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _scopes.contains(scope),
              title: Text(l.scope(scope)),
              onChanged: (on) => setState(() => on == true ? _scopes.add(scope) : _scopes.remove(scope)),
            ),
          TextField(
            controller: _note,
            maxLength: 300,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(labelText: l.requestReason, border: const OutlineInputBorder()),
          ),
          if (_error case final error?) Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: _scopes.isEmpty || _note.text.trim().length < 3 ? null : _send,
          child: Text(l.requestSend),
        ),
      ],
    );
  }
}
