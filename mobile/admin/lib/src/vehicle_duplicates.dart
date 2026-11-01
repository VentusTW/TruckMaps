import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Pojazdy z tym samym numerem VIN: scalenie w wybrany pojazd i przypisanie pojazdu
/// innej firmie albo członkowi firmy. Obie zmiany tylko za zgodą firmy (zakres „pojazdy”).
class VehicleDuplicatesScreen extends StatefulWidget {
  const VehicleDuplicatesScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<VehicleDuplicatesScreen> createState() => _VehicleDuplicatesScreenState();
}

class _VehicleDuplicatesScreenState extends State<VehicleDuplicatesScreen> {
  late Future<dynamic> _groups = widget.api.get('/api/admin/vehicles/duplicates');
  final _keep = <String, String>{};
  bool _busy = false;

  void _reload() {
    final groups = widget.api.get('/api/admin/vehicles/duplicates');
    setState(() {
      _groups = groups;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      _reload();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Wszystkie pozostałe pojazdy grupy scalane w wybrany.
  Future<void> _merge(String vin, List<Map<String, dynamic>> vehicles) async {
    final l = context.l;
    final keep = _keep[vin] ?? '${vehicles.first['id']}';
    final kept = vehicles.firstWhere((v) => v['id'] == keep);
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.mergeTitle),
        content: Text(l.mergeQuestion(vehicles.length - 1, '${kept['name']}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.merge)),
        ],
      ),
    );
    if (sure != true) return;
    await _run(() async {
      for (final v in vehicles) {
        if (v['id'] != keep) await widget.api.post('/api/admin/vehicles/merge', {'keep_id': keep, 'merge_id': v['id']});
      }
    });
  }

  /// Pojazd prywatny: prośba do właściciela o zgodę na zmiany w jego pojazdach.
  Future<void> _askConsent(Map<String, dynamic> vehicle) async {
    final l = context.l;
    final note = TextEditingController();
    final send = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.askPersonConsent),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: note,
            maxLength: 300,
            decoration: InputDecoration(labelText: l.askPersonConsentNote, border: const OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.send)),
        ],
      ),
    );
    final text = note.text.trim();
    if (send != true || text.length < 3) return;
    await _run(() => widget.api.post('/api/admin/accounts/${vehicle['owner_subject']}/access-requests', {
          'scopes': ['vehicles'],
          'note': text,
        }));
    if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(l.askPersonConsentSent)));
  }

  Future<void> _assign(Map<String, dynamic> vehicle) async {
    final body = await showDialog<Map<String, String?>>(
      context: context,
      builder: (_) => _AssignDialog(vehicle: vehicle),
    );
    if (body != null) await _run(() => widget.api.put('/api/admin/vehicles/${vehicle['id']}/assign', body));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(title: Text(l.duplicatesTitle)),
      body: FutureBuilder<dynamic>(
        future: _groups,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${snapshot.error}'),
              TextButton(onPressed: _reload, child: Text(l.retry)),
            ]));
          }
          if (!snapshot.hasData) return const Align(alignment: Alignment.topCenter, child: LinearProgressIndicator());
          final groups = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
          return ListView(padding: const EdgeInsets.all(16), children: [
            Text(l.duplicatesHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            if (groups.isEmpty) Text(l.duplicatesEmpty),
            for (final group in groups) _group(l, group),
          ]);
        },
      ),
    );
  }

  Widget _group(AdminLocalizations l, Map<String, dynamic> group) {
    final vin = '${group['vin']}';
    final vehicles = (group['vehicles'] as List<dynamic>).cast<Map<String, dynamic>>();
    final keep = _keep[vin] ?? '${vehicles.first['id']}';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('VIN $vin', style: Theme.of(context).textTheme.titleSmall),
          for (final v in vehicles)
            RadioListTile<String>(
              value: '${v['id']}',
              groupValue: keep,
              onChanged: _busy ? null : (id) => setState(() => _keep[vin] = id!),
              title: Text([v['name'], if (v['plate'] != null) v['plate']].join(' · ')),
              subtitle:
                  Text(v['company_name'] == null ? l.privateVehicle('${v['owner_subject']}') : '${v['company_name']}'),
              secondary: Row(mainAxisSize: MainAxisSize.min, children: [
                if (v['company_id'] == null)
                  IconButton(
                    tooltip: l.askPersonConsent,
                    onPressed: _busy ? null : () => _askConsent(v),
                    icon: const Icon(Icons.mark_email_unread_outlined),
                  ),
                IconButton(
                  tooltip: l.assign,
                  onPressed: _busy ? null : () => _assign(v),
                  icon: const Icon(Icons.swap_horiz),
                ),
              ]),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _merge(vin, vehicles),
              icon: const Icon(Icons.merge),
              label: Text(l.mergeInto),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Nowy właściciel: identyfikator firmy albo członka firmy (pojazd prywatny).
class _AssignDialog extends StatefulWidget {
  const _AssignDialog({required this.vehicle});

  final Map<String, dynamic> vehicle;

  @override
  State<_AssignDialog> createState() => _AssignDialogState();
}

class _AssignDialogState extends State<_AssignDialog> {
  final _value = TextEditingController();
  bool _toCompany = true;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return AlertDialog(
      title: Text(l.assignTitle('${widget.vehicle['name']}')),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (widget.vehicle['company_id'] != null)
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: Text(l.assignToCompany)),
                ButtonSegment(value: false, label: Text(l.assignToMember)),
              ],
              selected: {_toCompany},
              onSelectionChanged: (s) => setState(() => _toCompany = s.first),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _value,
            decoration: InputDecoration(
              labelText: _toCompany ? l.assignCompanyId : l.assignMemberSubject,
              border: const OutlineInputBorder(),
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
        FilledButton(
          onPressed: () {
            final value = _value.text.trim();
            if (value.isEmpty) return;
            Navigator.pop(context, _toCompany ? {'company_id': value} : {'company_id': null, 'owner_subject': value});
          },
          child: Text(l.assign),
        ),
      ],
    );
  }
}
