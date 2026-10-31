import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'texts.dart';

const _base = '/api/m/service';

InputDecoration _field(String label, {String? hint, String? suffix}) =>
    InputDecoration(labelText: label, hintText: hint, suffixText: suffix, border: const OutlineInputBorder(), isDense: true);

double? _parse(String text) => double.tryParse(text.trim().replaceAll(',', '.'));

String _vehicleTitle(Map<String, dynamic> o) {
  final plate = '${o['vehicle_plate'] ?? ''}';
  return plate.isEmpty ? '${o['vehicle_name']}' : '${o['vehicle_name']} · $plate';
}

/// Lista zleceń serwisowych (otwarte albo wszystkie) i zgłoszenie nowej usterki.
class ServiceScreen extends StatefulWidget {
  const ServiceScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<ServiceScreen> createState() => _ServiceScreenState();
}

class _ServiceScreenState extends State<ServiceScreen> {
  bool _openOnly = true;
  late Future<dynamic> _orders = _load();

  Future<dynamic> _load() => widget.api.get('$_base/orders?open_only=$_openOnly');

  void _reload() {
    final orders = _load();
    setState(() {
      _orders = orders;
    });
  }

  Future<void> _push(Widget screen) async {
    final changed = await Navigator.of(context).push<dynamic>(MaterialPageRoute(builder: (_) => screen));
    if (changed != null && mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final t = ServiceTexts.of(context);
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'service-report',
        onPressed: () => _push(ReportScreen(api: widget.api)),
        icon: const Icon(Icons.report_problem_outlined),
        label: Text(t.report),
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: true, label: Text(t.openOrders)),
              ButtonSegment(value: false, label: Text(t.allOrders)),
            ],
            selected: {_openOnly},
            onSelectionChanged: (value) {
              _openOnly = value.first;
              _reload();
            },
          ),
        ),
        Expanded(
          child: FutureBuilder<dynamic>(
            future: _orders,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text('${snapshot.error}'),
                    TextButton(onPressed: _reload, child: Text(t.retry)),
                  ]),
                );
              }
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final orders = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
              if (orders.isEmpty) return Center(child: Text(t.empty));
              return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 88), children: [
                for (final o in orders)
                  Card(
                    child: ListTile(
                      leading: _StatusIcon(order: o),
                      title: Text(_vehicleTitle(o)),
                      subtitle: Text('${t.status(o['status'] as String?)} · ${o['description']}',
                          maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: o['urgency'] == 'stopped' ? Tooltip(message: t.stopped, child: const Icon(Icons.block)) : null,
                      onTap: () => _push(OrderScreen(api: widget.api, order: o)),
                    ),
                  ),
              ]);
            },
          ),
        ),
      ]),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.order});

  final Map<String, dynamic> order;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (order['status']) {
      'new' => Icon(Icons.fiber_new_outlined, color: scheme.error),
      'accepted' => Icon(Icons.assignment_turned_in_outlined, color: scheme.primary),
      'in_progress' => Icon(Icons.build_circle_outlined, color: scheme.tertiary),
      'done' => Icon(Icons.check_circle_outline, color: scheme.primary),
      _ => Icon(Icons.cancel_outlined, color: scheme.outline),
    };
  }
}

/// Zgłoszenie usterki: pojazd, opis, czy pojazd może jechać.
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.api, this.vehicleId});

  final CoreApi api;
  final String? vehicleId;

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  final _form = GlobalKey<FormState>();
  final _description = TextEditingController();
  late String? _vehicleId = widget.vehicleId;
  String _urgency = 'can_drive';
  late final Future<dynamic> _vehicles = widget.api.get('/api/vehicles');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _description.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.api.post('$_base/orders', {
        'vehicle_id': _vehicleId,
        'description': _description.text.trim(),
        'urgency': _urgency,
      });
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ServiceTexts.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(t.reportTitle)),
      body: Form(
        key: _form,
        child: FutureBuilder<dynamic>(
          future: _vehicles,
          builder: (context, snapshot) {
            final vehicles = snapshot.hasData ? (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>() : const [];
            return ListView(padding: const EdgeInsets.all(16), children: [
              if (snapshot.hasData && vehicles.isEmpty) Text(t.noVehicles),
              DropdownButtonFormField<String>(
                value: vehicles.any((v) => v['id'] == _vehicleId) ? _vehicleId : null,
                isExpanded: true,
                decoration: _field(t.vehicle),
                items: [
                  for (final v in vehicles)
                    DropdownMenuItem(
                      value: v['id'] as String,
                      child: Text('${v['plate'] ?? ''}'.isEmpty ? '${v['name']}' : '${v['name']} · ${v['plate']}'),
                    ),
                ],
                validator: (value) => value == null ? t.vehicleRequired : null,
                onChanged: (value) => setState(() => _vehicleId = value),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                minLines: 3,
                maxLines: 6,
                maxLength: 2000,
                decoration: _field(t.description, hint: t.descriptionHint),
                validator: (text) => (text ?? '').trim().length < 3 ? t.descriptionRequired : null,
              ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: 'can_drive',
                groupValue: _urgency,
                title: Text(t.canDrive),
                onChanged: (value) => setState(() => _urgency = value ?? _urgency),
              ),
              RadioListTile<String>(
                contentPadding: EdgeInsets.zero,
                value: 'stopped',
                groupValue: _urgency,
                title: Text(t.stopped),
                subtitle: Text(t.stoppedHint),
                onChanged: (value) => setState(() => _urgency = value ?? _urgency),
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                ),
              FilledButton.icon(
                onPressed: _busy ? null : _send,
                icon: const Icon(Icons.send_outlined),
                label: Text(t.send),
              ),
            ]);
          },
        ),
      ),
    );
  }
}

/// Zlecenie: szczegóły, a dla mechanika / dyspozytora / właściciela – kolejne kroki.
class OrderScreen extends StatefulWidget {
  const OrderScreen({super.key, required this.api, required this.order});

  final CoreApi api;
  final Map<String, dynamic> order;

  @override
  State<OrderScreen> createState() => _OrderScreenState();
}

class _OrderScreenState extends State<OrderScreen> {
  late Map<String, dynamic> _order = widget.order;
  bool _changed = false;
  bool _busy = false;
  String? _error;

  Future<void> _action(String action, [Object? body]) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.api.post('$_base/orders/${_order['id']}/$action', body ?? {});
      if (!mounted) return;
      setState(() {
        _order = saved as Map<String, dynamic>;
        _changed = true;
      });
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final t = ServiceTexts.of(context);
    final reason = TextEditingController();
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.rejectTitle),
        content: TextField(controller: reason, maxLength: 1000, decoration: _field(t.rejectReason)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.reject)),
        ],
      ),
    );
    final text = reason.text.trim();
    reason.dispose();
    if (sure == true && mounted) await _action('reject', {'reason': text});
  }

  Future<void> _complete() async {
    final protocol = await Navigator.of(context)
        .push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const ProtocolScreen()));
    if (protocol != null && mounted) await _action('complete', protocol);
  }

  @override
  Widget build(BuildContext context) {
    final t = ServiceTexts.of(context);
    final theme = Theme.of(context);
    final o = _order;
    final status = o['status'] as String?;
    final handle = o['can_handle'] == true;
    final parts = (o['parts'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) Navigator.of(context).pop(_changed ? _order : null);
      },
      child: Scaffold(
        appBar: AppBar(title: Text(_vehicleTitle(o))),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [
            _StatusIcon(order: o),
            const SizedBox(width: 8),
            Text(t.status(status), style: theme.textTheme.titleMedium),
            if (o['urgency'] == 'stopped') ...[
              const SizedBox(width: 12),
              Chip(avatar: const Icon(Icons.block, size: 18), label: Text(t.stopped)),
            ],
          ]),
          const SizedBox(height: 12),
          Text('${o['description']}', style: theme.textTheme.bodyLarge),
          const SizedBox(height: 8),
          Text(t.reportedBy('${o['reporter_name']}', DateTime.parse('${o['created_at']}')),
              style: theme.textTheme.bodySmall),
          if (o['mechanic_name'] != null) Text(t.mechanic('${o['mechanic_name']}'), style: theme.textTheme.bodySmall),
          if (o['reject_reason'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(t.rejected('${o['reject_reason']}'), style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (status == 'done') ...[
            const Divider(height: 32),
            Text(t.protocolTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text('${o['work_done']}'),
            for (final p in parts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: const Icon(Icons.settings_outlined),
                title: Text('${p['name']}'),
                trailing: Text([
                  '× ${p['quantity']}',
                  if (p['price'] != null) '${p['price']}',
                ].join('  ')),
              ),
            if (o['labour_hours'] != null) Text('${t.labourHours}: ${t.hours('${o['labour_hours']}')}'),
            if (o['odometer_km'] != null) Text('${t.odometer}: ${o['odometer_km']} km'),
            if (o['notes'] != null) Text('${t.notes}: ${o['notes']}'),
            if (o['completed_at'] != null)
              Text(t.completed(DateTime.parse('${o['completed_at']}')), style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          if (handle)
            Wrap(spacing: 12, runSpacing: 8, children: [
              if (status == 'new') FilledButton(onPressed: _busy ? null : () => _action('accept'), child: Text(t.accept)),
              if (status == 'new' || status == 'accepted')
                FilledButton.tonal(onPressed: _busy ? null : () => _action('start'), child: Text(t.start)),
              if (status == 'new' || status == 'accepted' || status == 'in_progress')
                FilledButton.tonal(onPressed: _busy ? null : _complete, child: Text(t.complete)),
              if (status == 'new' || status == 'accepted')
                TextButton(onPressed: _busy ? null : _reject, child: Text(t.reject)),
            ]),
        ]),
      ),
    );
  }
}

/// Protokół naprawy: czynności, części (nazwa, ilość, cena), czas pracy, przebieg, uwagi.
class ProtocolScreen extends StatefulWidget {
  const ProtocolScreen({super.key});

  @override
  State<ProtocolScreen> createState() => _ProtocolScreenState();
}

class _ProtocolScreenState extends State<ProtocolScreen> {
  final _form = GlobalKey<FormState>();
  final _work = TextEditingController();
  final _hours = TextEditingController();
  final _odometer = TextEditingController();
  final _notes = TextEditingController();
  final List<(TextEditingController, TextEditingController, TextEditingController)> _parts = [];

  @override
  void dispose() {
    for (final c in [_work, _hours, _odometer, _notes, for (final p in _parts) ...[p.$1, p.$2, p.$3]]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _number(String? text, ServiceTexts t) =>
      (text ?? '').trim().isEmpty || _parse(text!) != null ? null : t.numberInvalid;

  void _save() {
    if (!_form.currentState!.validate()) return;
    Navigator.of(context).pop({
      'work_done': _work.text.trim(),
      'parts': [
        for (final p in _parts)
          if (p.$1.text.trim().isNotEmpty)
            {'name': p.$1.text.trim(), 'quantity': _parse(p.$2.text) ?? 1, 'price': _parse(p.$3.text)},
      ],
      'labour_hours': _parse(_hours.text),
      'odometer_km': _parse(_odometer.text)?.round(),
      'notes': _notes.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = ServiceTexts.of(context);
    final numbers = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    return Scaffold(
      appBar: AppBar(title: Text(t.protocolTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _work,
            minLines: 3,
            maxLines: 8,
            maxLength: 4000,
            decoration: _field(t.workDone),
            validator: (text) => (text ?? '').trim().length < 3 ? t.workDoneRequired : null,
          ),
          Row(children: [
            Expanded(child: Text(t.parts, style: Theme.of(context).textTheme.titleSmall)),
            TextButton.icon(
              onPressed: () => setState(
                  () => _parts.add((TextEditingController(), TextEditingController(text: '1'), TextEditingController()))),
              icon: const Icon(Icons.add),
              label: Text(t.addPart),
            ),
          ]),
          for (final (i, p) in _parts.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(flex: 3, child: TextFormField(controller: p.$1, decoration: _field(t.partName))),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: p.$2,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: numbers,
                    decoration: _field(t.partQuantity),
                    validator: (text) => _number(text, t),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: p.$3,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: numbers,
                    decoration: _field(t.partPrice),
                    validator: (text) => _number(text, t),
                  ),
                ),
                IconButton(
                  onPressed: () => setState(() => _parts.removeAt(i)),
                  icon: const Icon(Icons.close),
                ),
              ]),
            ),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _hours,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: numbers,
                decoration: _field(t.labourHours, suffix: 'h'),
                validator: (text) => _number(text, t),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextFormField(
                controller: _odometer,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: _field(t.odometer, suffix: 'km'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          TextFormField(controller: _notes, maxLength: 2000, maxLines: 3, decoration: _field(t.notes)),
          FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save_outlined), label: Text(t.save)),
        ]),
      ),
    );
  }
}
