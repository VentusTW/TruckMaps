import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../account/common.dart';
import '../l10n.dart';

/// Zakresy, w których właściciel może pozwolić administratorowi TruckMaps na zmiany.
const adminScopes = ['company', 'bases'];

/// Tyle trwa dostęp po zgodzie; dłużej – po przedłużeniu.
const grantMinutes = 60;
const _durations = [30, 60, 120, 240, 480];

String scopeLabel(AppLocalizations l, String scope) => switch (scope) {
      'company' => l.adminScopeCompany,
      'bases' => l.adminScopeBases,
      _ => scope,
    };

/// „30 min”, „1 godz.”, „8 godz.”.
String grantDuration(AppLocalizations l, int minutes) =>
    minutes < 60 ? l.durationMinutes(minutes) : l.durationHours(minutes ~/ 60);

/// Stan dostępu w jednym zdaniu (prośba czeka, aktywny do…, odrzucona, zamknięty, wygasł).
String grantStateLabel(AppLocalizations l, Map<String, dynamic>? grant) {
  String at(String key) => l.when(DateTime.parse('${grant![key]}').toLocal());
  return switch (grant?['state']) {
    'pending' => l.adminStatePending,
    'active' => l.adminAccessUntil(at('expires_at')),
    'rejected' => l.adminStateRejected,
    'closed' => l.adminAccessRevoked(at('revoked_at')),
    'expired' => l.adminAccessExpired(at('expires_at')),
    _ => '',
  };
}

/// Dostęp administratora TruckMaps do zmian w firmie – tylko właściciel.
/// Administrator widzi dane zawsze, ale zmienia je wyłącznie po zgodzie właściciela, przez
/// określony czas (zwykle godzinę); każda jego zmiana jest w dzienniku poniżej.
class AdminAccessScreen extends StatefulWidget {
  const AdminAccessScreen({super.key, required this.api, required this.companyId});

  final CoreApi api;
  final String companyId;

  @override
  State<AdminAccessScreen> createState() => _AdminAccessScreenState();
}

class _AdminAccessScreenState extends State<AdminAccessScreen> {
  late Future<dynamic> _access = widget.api.get(_path);
  Timer? _ticker;

  String get _path => '/api/companies/${widget.companyId}/admin-access';

  @override
  void initState() {
    super.initState();
    // Pozostały czas aktywnego dostępu odświeża się co pół minuty.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _reload() {
    final access = widget.api.get(_path);
    setState(() {
      _access = access;
    });
  }

  Future<void> _call(Future<dynamic> Function() request) async {
    try {
      await request();
      if (mounted) _reload();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _grant() async {
    final grant = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _GrantDialog());
    if (grant != null && mounted) await _call(() => widget.api.post(_path, grant));
  }

  Future<void> _revoke(Map<String, dynamic> grant) async {
    final l = context.l;
    if (!await confirm(context, title: l.adminRevokeTitle, question: l.adminRevokeQuestion, action: l.adminRevoke)) {
      return;
    }
    await _call(() => widget.api.delete('$_path/${grant['id']}'));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'admin-grant',
        onPressed: _grant,
        icon: const Icon(Icons.lock_open_outlined),
        label: Text(l.adminGrant),
      ),
      body: FutureBuilder<dynamic>(
        future: _access,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return ListView(padding: const EdgeInsets.all(16), children: [
              Text('${snapshot.error}'),
              TextButton(onPressed: _reload, child: Text(l.retry)),
            ]);
          }
          if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
          final data = snapshot.data as Map<String, dynamic>;
          final grants = (data['grants'] as List<dynamic>).cast<Map<String, dynamic>>();
          final changes = (data['changes'] as List<dynamic>).cast<Map<String, dynamic>>();
          return ListView(padding: const EdgeInsets.fromLTRB(16, 16, 16, 88), children: [
            Text(l.adminAccessTitle, style: theme.textTheme.titleSmall),
            Text(l.adminAccessHint, style: theme.textTheme.bodySmall),
            if (grants.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(l.adminAccessNone)),
            for (final grant in grants) _grantTile(l, grant),
            const SizedBox(height: 24),
            Text(l.adminChangesTitle, style: theme.textTheme.titleSmall),
            if (changes.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(l.adminChangesNone)),
            for (final change in changes) _changeTile(l, change),
          ]);
        },
      ),
    );
  }

  Widget _grantTile(AppLocalizations l, Map<String, dynamic> grant) {
    final state = grant['state'] as String?;
    final active = state == 'active';
    final pending = state == 'pending';
    final scopes = (grant['scopes'] as List<dynamic>).map((s) => scopeLabel(l, '$s')).join(', ');
    final left = active ? DateTime.parse('${grant['expires_at']}').difference(DateTime.now()) : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: active || pending,
      leading: Icon(active
          ? Icons.lock_open
          : pending
              ? Icons.hourglass_top
              : Icons.lock_outline),
      title: Text(scopes),
      subtitle: Text([
        if (grant['requested_by'] != null) l.adminRequestedBy('${grant['requested_by']}'),
        grantStateLabel(l, grant),
        if (left != null) l.adminTimeLeft(grantDuration(l, left.inMinutes.clamp(0, 9999) + 1)),
        if ('${grant['note']}'.isNotEmpty) '${grant['note']}',
      ].join(' · ')),
      trailing: pending
          ? Wrap(spacing: 4, children: [
              IconButton(
                tooltip: l.inboxReject,
                onPressed: () => _call(() => widget.api.post('$_path/${grant['id']}/reject', null)),
                icon: const Icon(Icons.close),
              ),
              IconButton(
                tooltip: l.inboxAccept(grantDuration(l, grantMinutes)),
                onPressed: () =>
                    _call(() => widget.api.post('$_path/${grant['id']}/accept', {'minutes': grantMinutes})),
                icon: const Icon(Icons.check),
              ),
            ])
          : active
              ? Wrap(spacing: 4, children: [
                  PopupMenuButton<int>(
                    tooltip: l.adminExtend,
                    icon: const Icon(Icons.more_time),
                    onSelected: (minutes) =>
                        _call(() => widget.api.post('$_path/${grant['id']}/extend', {'minutes': minutes})),
                    itemBuilder: (_) => [
                      for (final m in const [30, 60, 120])
                        PopupMenuItem(value: m, child: Text(l.adminExtendBy(grantDuration(l, m)))),
                    ],
                  ),
                  IconButton(tooltip: l.adminRevoke, onPressed: () => _revoke(grant), icon: const Icon(Icons.block)),
                ])
              : null,
    );
  }

  Widget _changeTile(AppLocalizations l, Map<String, dynamic> change) {
    final fields = (change['changes'] as Map<String, dynamic>).entries.map((e) {
      final values = e.value as List<dynamic>;
      return '${_fieldLabel(l, e.key)}: ${_value(values[0])} → ${_value(values[1])}';
    });
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.history),
      title: Text('${_actionLabel(l, '${change['action']}')} · ${change['admin']}'),
      subtitle: Text([l.when(DateTime.parse('${change['at']}').toLocal()), ...fields].join('\n')),
      isThreeLine: fields.isNotEmpty,
    );
  }

  String _value(Object? value) => value == null || '$value'.isEmpty ? '—' : '$value';

  String _actionLabel(AppLocalizations l, String action) => switch (action) {
        'company.update' => l.adminActionCompany,
        'base.update' => l.adminActionBase,
        _ => action,
      };

  String _fieldLabel(AppLocalizations l, String field) => switch (field) {
        'name' => l.companyName,
        'tax_id' => l.companyTaxId,
        'cost_per_km' => l.vehicleCostPerKm,
        'cost_per_hour' => l.vehicleCostPerHour,
        'cost_currency' => l.companyCurrency,
        'base' => l.adminFieldBase,
        'label' => l.adminFieldAddress,
        'lat' || 'lon' => l.adminFieldPosition,
        _ => field,
      };
}

/// Zakres, czas i notatka dostępu, którego właściciel udziela sam.
class _GrantDialog extends StatefulWidget {
  const _GrantDialog();

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  final _note = TextEditingController();
  final _scopes = <String>{'company'};
  int _minutes = grantMinutes;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      title: Text(l.adminGrantTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(l.adminGrantHint),
            for (final scope in adminScopes)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _scopes.contains(scope),
                title: Text(scopeLabel(l, scope)),
                onChanged: (on) => setState(() => on == true ? _scopes.add(scope) : _scopes.remove(scope)),
              ),
            DropdownButtonFormField<int>(
              value: _minutes,
              decoration: field(l.adminGrantDuration),
              items: [for (final m in _durations) DropdownMenuItem(value: m, child: Text(grantDuration(l, m)))],
              onChanged: (value) => setState(() => _minutes = value ?? _minutes),
            ),
            const SizedBox(height: 16),
            TextField(controller: _note, maxLength: 300, decoration: field(l.adminGrantNote, hint: l.adminGrantNoteHint)),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: _scopes.isEmpty
              ? null
              : () => Navigator.pop(context, {
                    'scopes': [for (final s in adminScopes) if (_scopes.contains(s)) s],
                    'minutes': _minutes,
                    'note': _note.text.trim(),
                  }),
          child: Text(l.adminGrant),
        ),
      ],
    );
  }
}
