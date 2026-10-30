import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

import '../account/common.dart';
import '../l10n.dart';
import '../planner/place_field.dart';

/// Firma: dane i stawki (zmienia właściciel), bazy (właściciel i dyspozytorzy),
/// przełączanie między firmami, opuszczenie albo usunięcie firmy.
class CompanyScreen extends StatefulWidget {
  const CompanyScreen({
    super.key,
    required this.api,
    required this.companies,
    required this.company,
    required this.onSwitch,
    required this.onChanged,
  });

  final CoreApi api;

  /// Firmy użytkownika z `/api/companies` (z jego rolą w każdej).
  final List<Map<String, dynamic>> companies;
  final Map<String, dynamic> company;
  final ValueChanged<String> onSwitch;

  /// Po zmianie danych firmy, jej usunięciu albo opuszczeniu.
  final VoidCallback onChanged;

  @override
  State<CompanyScreen> createState() => _CompanyScreenState();
}

class _CompanyScreenState extends State<CompanyScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late String _currency;
  List<String> _currencies = const [];
  late Future<dynamic> _bases = widget.api.get('/api/bases');
  bool _busy = false;

  String get _id => widget.company['id'] as String;
  String? get _role => widget.company['role'] as String?;
  bool get _owner => _role == 'owner';

  @override
  void initState() {
    super.initState();
    final c = widget.company;
    _fields = {
      for (final key in ['name', 'tax_id', 'cost_per_km', 'cost_per_hour']) key: TextEditingController(text: _text(c[key])),
    };
    _currency = c['cost_currency'] as String? ?? 'EUR';
    if (_owner) {
      loadCurrencies(widget.api).then((list) {
        if (mounted) setState(() => _currencies = list);
      });
    }
  }

  bool _formatted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_formatted) return;
    _formatted = true;
    for (final key in ['cost_per_km', 'cost_per_hour']) {
      final value = widget.company[key];
      if (value is num) _fields[key]!.text = context.l.number(value);
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  static String _text(Object? value) => value == null ? '' : '$value';

  String? _validateRate(String? text) {
    if ((text ?? '').trim().isEmpty) return null;
    final value = parseAmount(text!);
    return value == null || value < 0 ? context.l.companyRateInvalid : null;
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    final taxId = _fields['tax_id']!.text.trim();
    try {
      await widget.api.put('/api/companies/$_id', {
        'name': _fields['name']!.text.trim(),
        'tax_id': taxId.isEmpty ? null : taxId,
        'cost_per_km': parseAmount(_fields['cost_per_km']!.text),
        'cost_per_hour': parseAmount(_fields['cost_per_hour']!.text),
        'cost_currency': _currency,
      });
      widget.onChanged();
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.companySaved)));
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reloadBases() {
    final bases = widget.api.get('/api/bases');
    setState(() {
      _bases = bases;
    });
  }

  Future<void> _openBase([Map<String, dynamic>? base]) async {
    final saved = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => BaseFormScreen(api: widget.api, companyId: _id, base: base)),
    );
    if (saved != null && mounted) _reloadBases();
  }

  Future<void> _deleteBase(Map<String, dynamic> base) async {
    final l = context.l;
    if (!await confirm(context, title: l.baseDeleteTitle, question: l.baseDeleteQuestion('${base['name']}'))) return;
    try {
      await widget.api.delete('/api/companies/$_id/bases/${base['id']}');
      if (mounted) _reloadBases();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _leave() async {
    final l = context.l;
    final name = '${widget.company['name']}';
    if (!await confirm(context, title: l.companyLeaveTitle, question: l.companyLeaveQuestion(name), action: l.companyLeave)) {
      return;
    }
    try {
      final details = await widget.api.get('/api/companies/$_id') as Map<String, dynamic>;
      final me = (details['members'] as List<dynamic>).cast<Map<String, dynamic>>().firstWhere((m) => m['is_me'] == true);
      await widget.api.delete('/api/companies/$_id/members/${me['id']}');
      widget.onChanged();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Future<void> _deleteCompany() async {
    final l = context.l;
    if (!await confirm(context, title: l.companyDeleteTitle, question: l.companyDeleteQuestion('${widget.company['name']}'))) {
      return;
    }
    try {
      await widget.api.delete('/api/companies/$_id');
      widget.onChanged();
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }

  Widget _rateField(String key, String label) => TextFormField(
        controller: _fields[key],
        enabled: _owner,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
        decoration: field(label, suffix: _currency),
        validator: _validateRate,
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final currencies = _currencies.contains(_currency) ? _currencies : [_currency, ..._currencies];
    return Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        if (widget.companies.length > 1) ...[
          DropdownButtonFormField<String>(
            value: _id,
            decoration: field(l.companySwitch),
            items: [
              for (final c in widget.companies)
                DropdownMenuItem(value: c['id'] as String, child: Text('${c['name']} · ${roleLabel(l, c['role'] as String?)}')),
            ],
            onChanged: (id) {
              if (id != null && id != _id) widget.onSwitch(id);
            },
          ),
          const SizedBox(height: 16),
        ],
        Text(l.companyDetails, style: theme.textTheme.titleSmall),
        Text(_owner ? l.companyDetailsHint : l.companyDetailsReadOnly(roleLabel(l, _role)), style: theme.textTheme.bodySmall),
        const SizedBox(height: 12),
        TextFormField(
          controller: _fields['name'],
          enabled: _owner,
          maxLength: 200,
          decoration: field(l.companyName),
          validator: (text) => (text ?? '').trim().length < 2 ? l.companyNameRequired : null,
        ),
        TextFormField(controller: _fields['tax_id'], enabled: _owner, maxLength: 30, decoration: field(l.companyTaxId)),
        Text(l.companyRates, style: theme.textTheme.titleSmall),
        Text(l.companyRatesHint, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _rateField('cost_per_km', l.vehicleCostPerKm)),
          const SizedBox(width: 12),
          Expanded(child: _rateField('cost_per_hour', l.vehicleCostPerHour)),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _currency,
              decoration: field(l.companyCurrency),
              items: [for (final code in currencies) DropdownMenuItem(value: code, child: Text(code))],
              onChanged: _owner ? (value) => setState(() => _currency = value ?? _currency) : null,
            ),
          ),
        ]),
        if (_owner)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FilledButton.icon(
                onPressed: _busy ? null : _save,
                icon: const Icon(Icons.save_outlined),
                label: Text(_busy ? l.saving : l.save),
              ),
            ),
          ),
        const SizedBox(height: 24),
        Row(children: [
          Expanded(child: Text(l.basesTitle, style: theme.textTheme.titleSmall)),
          if (managesCompany(_role))
            TextButton.icon(onPressed: _openBase, icon: const Icon(Icons.add_location_alt_outlined), label: Text(l.baseAdd)),
        ]),
        Text(l.basesHint, style: theme.textTheme.bodySmall),
        FutureBuilder<dynamic>(
          future: _bases,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return Row(children: [
                Expanded(child: Text('${snapshot.error}')),
                TextButton(onPressed: _reloadBases, child: Text(l.retry)),
              ]);
            }
            if (!snapshot.hasData) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
            final bases = [
              for (final b in (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>())
                if (b['company_id'] == _id) b,
            ];
            if (bases.isEmpty) return Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(l.basesEmpty));
            return Column(children: [
              for (final base in bases)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.warehouse_outlined),
                  title: Text('${base['name']}'),
                  subtitle: Text('${base['label']}'.isEmpty ? '${base['lat']}, ${base['lon']}' : '${base['label']}'),
                  trailing: managesCompany(_role)
                      ? PopupMenuButton<String>(
                          onSelected: (action) => action == 'edit' ? _openBase(base) : _deleteBase(base),
                          itemBuilder: (context) => [
                            PopupMenuItem(value: 'edit', child: Text(l.edit)),
                            PopupMenuItem(value: 'delete', child: Text(l.delete)),
                          ],
                        )
                      : null,
                ),
            ]);
          },
        ),
        const SizedBox(height: 24),
        Align(
          alignment: Alignment.centerLeft,
          child: _owner
              ? TextButton.icon(
                  onPressed: _deleteCompany,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l.companyDelete),
                  style: TextButton.styleFrom(foregroundColor: theme.colorScheme.error),
                )
              : TextButton.icon(onPressed: _leave, icon: const Icon(Icons.exit_to_app), label: Text(l.companyLeave)),
        ),
      ]),
    );
  }
}

/// Nowa baza firmy albo zmiana istniejącej: nazwa i adres z wyszukiwarki (albo GPS).
class BaseFormScreen extends StatefulWidget {
  const BaseFormScreen({super.key, required this.api, required this.companyId, this.base});

  final CoreApi api;
  final String companyId;
  final Map<String, dynamic>? base;

  @override
  State<BaseFormScreen> createState() => _BaseFormScreenState();
}

class _BaseFormScreenState extends State<BaseFormScreen> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.base?['name'] as String? ?? '');
  late final _place = TextEditingController(text: widget.base?['label'] as String? ?? '');
  late Place? _chosen = widget.base == null
      ? null
      : Place(widget.base!['label'] as String? ?? '',
          LatLng((widget.base!['lat'] as num).toDouble(), (widget.base!['lon'] as num).toDouble()));
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _place.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final valid = _form.currentState!.validate();
    if (_chosen == null) setState(() => _error = context.l.basePlaceRequired);
    if (!valid || _chosen == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = {
      'name': _name.text.trim(),
      'label': _chosen!.label,
      'lat': _chosen!.point.latitude,
      'lon': _chosen!.point.longitude,
    };
    final path = '/api/companies/${widget.companyId}/bases';
    try {
      final saved = widget.base == null
          ? await widget.api.post(path, body)
          : await widget.api.put('$path/${widget.base!['id']}', body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.base == null ? l.baseAddTitle : l.baseEditTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          TextFormField(
            controller: _name,
            maxLength: 100,
            decoration: field(l.baseName, hint: l.baseNameHint),
            validator: (text) => (text ?? '').trim().isEmpty ? l.baseNameRequired : null,
          ),
          PlaceField(
            api: widget.api,
            label: l.basePlace,
            icon: Icons.place_outlined,
            controller: _place,
            onSelected: (place) => setState(() {
              _chosen = place;
              _error = null;
            }),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ),
          FilledButton.icon(
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_busy ? l.saving : l.save),
          ),
        ]),
      ),
    );
  }
}
