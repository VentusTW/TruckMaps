import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../account/common.dart';
import '../l10n.dart';

/// Członkowie firmy z rolami i zaproszenia kodem. Role zmienia i usuwa członków właściciel;
/// dyspozytor zaprasza tylko kierowców. Firma zawsze ma co najmniej jednego właściciela.
class MembersScreen extends StatefulWidget {
  const MembersScreen(
      {super.key, required this.api, required this.companyId, required this.role, this.companyKind, this.onChanged});

  final CoreApi api;
  final String companyId;

  /// Rola zalogowanego użytkownika w tej firmie.
  final String role;

  /// Rodzaj firmy – w spedycji nie ma kierowców.
  final String? companyKind;

  /// Po zmianie własnej roli (menu zależy od roli).
  final VoidCallback? onChanged;

  @override
  State<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends State<MembersScreen> {
  late Future<dynamic> _company = widget.api.get(_path);
  late Future<dynamic> _invites = widget.api.get('$_path/invites');

  String get _path => '/api/companies/${widget.companyId}';
  bool get _owner => widget.role == 'owner';

  void _reload() {
    final company = widget.api.get(_path);
    final invites = widget.api.get('$_path/invites');
    setState(() {
      _company = company;
      _invites = invites;
    });
  }

  /// Ostatniego właściciela nie można zdegradować ani usunąć – sprawdzamy, zanim zapytamy serwer.
  bool _lastOwner(Map<String, dynamic> member, List<Map<String, dynamic>> members) =>
      member['role'] == 'owner' && members.where((m) => m['role'] == 'owner').length == 1;

  Future<void> _setRole(Map<String, dynamic> member, String role, List<Map<String, dynamic>> members) async {
    final l = context.l;
    if (role != 'owner' && _lastOwner(member, members)) return showError(context, l.companyNeedsOwner);
    try {
      await widget.api.put('$_path/members/${member['id']}', {'role': role});
      if (!mounted) return;
      _reload();
      if (member['is_me'] == true) widget.onChanged?.call();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _remove(Map<String, dynamic> member, List<Map<String, dynamic>> members) async {
    final l = context.l;
    if (_lastOwner(member, members)) return showError(context, l.companyNeedsOwner);
    final name = '${member['display_name']}';
    if (!await confirm(context, title: l.memberRemoveTitle, question: l.memberRemoveQuestion(name))) return;
    try {
      await widget.api.delete('$_path/members/${member['id']}');
      if (mounted) _reload();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _invite() async {
    final invite = await showDialog<(String, String)>(
      context: context,
      builder: (_) => _InviteDialog(owner: _owner, roles: rolesFor(widget.companyKind)),
    );
    if (invite == null || !mounted) return;
    try {
      final created = await widget.api.post('$_path/invites', {'role': invite.$1, 'note': invite.$2}) as Map<String, dynamic>;
      if (!mounted) return;
      _reload();
      await _showCode(created);
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _showCode(Map<String, dynamic> invite) {
    final l = context.l;
    final code = '${invite['code']}';
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.inviteCreated),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          SelectableText(code, style: Theme.of(context).textTheme.headlineMedium?.copyWith(letterSpacing: 4)),
          const SizedBox(height: 8),
          Text(l.inviteCodeHint(roleLabel(l, invite['role'] as String?), _expires(l, invite))),
        ]),
        actions: [
          TextButton.icon(
            onPressed: () => Clipboard.setData(ClipboardData(text: code)),
            icon: const Icon(Icons.copy),
            label: Text(l.copy),
          ),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.ok)),
        ],
      ),
    );
  }

  String _expires(AppLocalizations l, Map<String, dynamic> invite) =>
      l.when(DateTime.parse('${invite['expires_at']}').toLocal());

  Future<void> _cancelInvite(Map<String, dynamic> invite) async {
    final l = context.l;
    final code = '${invite['code']}';
    if (!await confirm(context, title: l.inviteCancelTitle, question: l.inviteCancelQuestion(code), action: l.inviteCancel)) {
      return;
    }
    try {
      await widget.api.delete('$_path/invites/$code');
      if (mounted) _reload();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Widget _failed(Object? error) => Row(children: [
        Expanded(child: Text('$error')),
        TextButton(onPressed: _reload, child: Text(context.l.retry)),
      ]);

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'invite',
        onPressed: _invite,
        icon: const Icon(Icons.person_add_alt),
        label: Text(l.invite),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
        Text(l.membersTitle, style: theme.textTheme.titleSmall),
        FutureBuilder<dynamic>(
          future: _company,
          builder: (context, snapshot) {
            if (snapshot.hasError) return _failed(snapshot.error);
            if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
            final members = ((snapshot.data as Map<String, dynamic>)['members'] as List<dynamic>).cast<Map<String, dynamic>>();
            return Column(children: [for (final m in members) _member(l, m, members)]);
          },
        ),
        const SizedBox(height: 24),
        Text(l.invitesTitle, style: theme.textTheme.titleSmall),
        Text(_owner ? l.invitesHint : l.inviteDriversOnly, style: theme.textTheme.bodySmall),
        FutureBuilder<dynamic>(
          future: _invites,
          builder: (context, snapshot) {
            if (snapshot.hasError) return _failed(snapshot.error);
            if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
            final invites = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
            if (invites.isEmpty) return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(l.invitesEmpty));
            return Column(children: [
              for (final invite in invites)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.vpn_key_outlined),
                  title: SelectableText('${invite['code']}', style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2)),
                  subtitle: Text([
                    roleLabel(l, invite['role'] as String?),
                    if ('${invite['note']}'.isNotEmpty) '${invite['note']}',
                    l.inviteExpires(_expires(l, invite)),
                  ].join(' · ')),
                  trailing: IconButton(
                    tooltip: l.inviteCancel,
                    onPressed: () => _cancelInvite(invite),
                    icon: const Icon(Icons.close),
                  ),
                ),
            ]);
          },
        ),
      ]),
    );
  }

  Widget _member(AppLocalizations l, Map<String, dynamic> member, List<Map<String, dynamic>> members) {
    final me = member['is_me'] == true;
    final role = member['role'] as String?;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(switch (role) {
        'owner' => Icons.star_outline,
        'dispatcher' => Icons.support_agent,
        'mechanic' => Icons.build_outlined,
        _ => Icons.local_shipping_outlined,
      }),
      title: Text(me ? l.memberMe('${member['display_name']}') : '${member['display_name']}'),
      subtitle: Text(roleLabel(l, role)),
      trailing: _owner
          ? PopupMenuButton<String>(
              tooltip: l.memberActions,
              onSelected: (action) =>
                  action == 'remove' ? _remove(member, members) : _setRole(member, action, members),
              itemBuilder: (context) => [
                for (final r in rolesFor(widget.companyKind))
                  if (r != role) PopupMenuItem(value: r, child: Text(l.memberMakeRole(roleLabel(l, r)))),
                if (!me) PopupMenuItem(value: 'remove', child: Text(l.memberRemove)),
              ],
            )
          : null,
    );
  }
}

/// Rola i notatka nowego zaproszenia; dyspozytor zaprasza tylko kierowców.
class _InviteDialog extends StatefulWidget {
  const _InviteDialog({required this.owner, required this.roles});

  final bool owner;
  final List<String> roles;

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  final _note = TextEditingController();
  late String _role = widget.roles.last;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      title: Text(l.inviteTitle),
      content: SizedBox(
        width: 400,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.owner)
            DropdownButtonFormField<String>(
              value: _role,
              decoration: field(l.inviteRole),
              items: [for (final r in widget.roles) DropdownMenuItem(value: r, child: Text(roleLabel(l, r)))],
              onChanged: (value) => setState(() => _role = value ?? _role),
            )
          else
            Text(l.inviteDriversOnly),
          const SizedBox(height: 16),
          TextField(controller: _note, maxLength: 200, decoration: field(l.inviteNote, hint: l.inviteNoteHint)),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, (_role, _note.text.trim())), child: Text(l.inviteCreate)),
      ],
    );
  }
}
