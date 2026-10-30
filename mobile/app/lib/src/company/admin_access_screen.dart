import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../account/common.dart';
import '../l10n.dart';

/// Zakresy, w których właściciel może pozwolić administratorowi TruckMaps na zmiany.
const adminScopes = ['company', 'bases'];
const _grantDays = [1, 3, 7, 14, 30];

String scopeLabel(AppLocalizations l, String scope) => switch (scope) {
      'company' => l.adminScopeCompany,
      'bases' => l.adminScopeBases,
      _ => scope,
    };

/// Dostęp administratora TruckMaps do zmian w firmie – tylko właściciel.
/// Administrator widzi dane zawsze, ale zmienia je wyłącznie w zakresie i terminie, na które
/// pozwoli właściciel; każda jego zmiana jest w dzienniku poniżej.
class AdminAccessScreen extends StatefulWidget {
  const AdminAccessScreen({super.key, required this.api, required this.companyId});

  final CoreApi api;
  final String companyId;

  @override
  State<AdminAccessScreen> createState() => _AdminAccessScreenState();
}

class _AdminAccessScreenState extends State<AdminAccessScreen> {
  late Future<dynamic> _access = widget.api.get(_path);

  String get _path => '/api/companies/${widget.companyId}/admin-access';

  void _reload() {
    final access = widget.api.get(_path);
    setState(() {
      _access = access;
    });
  }

  Future<void> _grant() async {
    final grant = await showDialog<Map<String, dynamic>>(context: context, builder: (_) => const _GrantDialog());
    if (grant == null || !mounted) return;
    try {
      await widget.api.post(_path, grant);
      if (mounted) _reload();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _revoke(Map<String, dynamic> grant) async {
    final l = context.l;
    if (!await confirm(context, title: l.adminRevokeTitle, question: l.adminRevokeQuestion, action: l.adminRevoke)) {
      return;
    }
    try {
      await widget.api.delete('$_path/${grant['id']}');
      if (mounted) _reload();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  String _when(AppLocalizations l, Object? moment) => l.when(DateTime.parse('$moment').toLocal());

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
    final active = grant['active'] == true;
    final scopes = (grant['scopes'] as List<dynamic>).map((s) => scopeLabel(l, '$s')).join(', ');
    final state = active
        ? l.adminAccessUntil(_when(l, grant['expires_at']))
        : grant['revoked_at'] != null
            ? l.adminAccessRevoked(_when(l, grant['revoked_at']))
            : l.adminAccessExpired(_when(l, grant['expires_at']));
    return ListTile(
      contentPadding: EdgeInsets.zero,
      enabled: active,
      leading: Icon(active ? Icons.lock_open : Icons.lock_outline),
      title: Text(scopes),
      subtitle: Text([state, if ('${grant['note']}'.isNotEmpty) '${grant['note']}'].join(' · ')),
      trailing: active
          ? IconButton(tooltip: l.adminRevoke, onPressed: () => _revoke(grant), icon: const Icon(Icons.block))
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
      subtitle: Text([_when(l, change['at']), ...fields].join('\n')),
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

/// Zakres, termin i notatka nowego dostępu.
class _GrantDialog extends StatefulWidget {
  const _GrantDialog();

  @override
  State<_GrantDialog> createState() => _GrantDialogState();
}

class _GrantDialogState extends State<_GrantDialog> {
  final _note = TextEditingController();
  final _scopes = <String>{'company'};
  int _days = 1;

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
              value: _days,
              decoration: field(l.adminGrantDuration),
              items: [for (final d in _grantDays) DropdownMenuItem(value: d, child: Text(l.adminGrantDays(d)))],
              onChanged: (value) => setState(() => _days = value ?? _days),
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
                    'days': _days,
                    'note': _note.text.trim(),
                  }),
          child: Text(l.adminGrant),
        ),
      ],
    );
  }
}
