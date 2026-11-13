import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';

/// „+ Dodaj kierowcę”: kod zaproszenia do firmy (rola kierowcy, ważny 7 dni) do przekazania
/// kierowcy – dołącza nim w aplikacji („Dołącz do firmy”).
Future<void> inviteDriver(BuildContext context, CoreApi api, String companyId) async {
  final l = context.l;
  final note = TextEditingController();
  final create = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l.drvAdd),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(l.drvInviteHint),
        const SizedBox(height: 12),
        TextField(
          controller: note,
          maxLength: 200,
          decoration: InputDecoration(labelText: l.drvInviteNote, border: const OutlineInputBorder()),
        ),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.drvInviteCreate)),
      ],
    ),
  );
  final text = note.text.trim();
  note.dispose();
  if (create != true || !context.mounted) return;
  try {
    final invite =
        await api.post('/api/companies/$companyId/invites', {'role': 'driver', 'note': text}) as Map<String, dynamic>;
    if (!context.mounted) return;
    final code = '${invite['code']}';
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.drvInviteCode),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SelectableText(code, key: const Key('driver-invite-code'), style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(l.drvInviteCodeHint),
        ]),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            child: Text(l.drvInviteCopy),
          ),
          FilledButton(
              onPressed: () => Navigator.pop(context), child: Text(MaterialLocalizations.of(context).closeButtonLabel)),
        ],
      ),
    );
  } catch (error) {
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
  }
}

/// „Wiadomość do kabiny”: tekst trafia do skrzynki kierowcy (konto członka firmy).
Future<void> messageDriver(BuildContext context, CoreApi api, String companyId, String memberId, String name) async {
  final l = context.l;
  final text = TextEditingController();
  final send = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${l.drvMessage}: $name'),
      content: TextField(
        key: const Key('driver-message-text'),
        controller: text,
        autofocus: true,
        maxLength: 1000,
        maxLines: 4,
        decoration: const InputDecoration(border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.drvMessageSend)),
      ],
    ),
  );
  final body = text.text.trim();
  text.dispose();
  if (send != true || body.isEmpty || !context.mounted) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await api.post('/api/companies/$companyId/members/$memberId/message', {'text': body});
    messenger?.showSnackBar(SnackBar(content: Text(l.drvMessageSent(name))));
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
  }
}

/// „Zadzwoń”: numer w aplikacji telefonu (na komputerze – program do połączeń, jeśli jest).
Future<void> callDriver(String phone) => launchUrl(Uri(scheme: 'tel', path: phone.replaceAll(' ', '')));
