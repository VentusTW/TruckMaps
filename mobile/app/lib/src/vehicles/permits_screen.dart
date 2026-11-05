import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import '../planner/place_field.dart';
import 'service_dates.dart' show towedKinds;

/// Kraje do wyboru przy zezwoleniu na cały kraj.
const permitCountries = ['PL', 'DE', 'CZ', 'SK', 'LT', 'AT', 'HU', 'NL', 'BE', 'FR', 'IT'];

String _day(DateTime d) => DateFormat('yyyy-MM-dd').format(d);

/// Opis zezwolenia na liście: zasięg, limity i ważność.
String permitSummary(AppLocalizations l, Map<String, dynamic> p) {
  String n(Object? v) => v is num ? l.number(v) : '';
  final limits = [
    if (p['max_weight_t'] != null) l.permitMaxWeight(n(p['max_weight_t'])),
    if (p['max_axle_t'] != null) l.permitMaxAxle(n(p['max_axle_t'])),
    if (p['max_length_m'] != null) l.permitMaxLength(n(p['max_length_m'])),
    if (p['max_width_m'] != null) l.permitMaxWidth(n(p['max_width_m'])),
    if (p['max_height_m'] != null) l.permitMaxHeight(n(p['max_height_m'])),
    if (p['hgv_ban'] == true) l.permitHgvBan,
  ];
  final scope = switch (p['scope']) {
    'country' => l.permitScopeCountryValue('${p['country']}'),
    'circle' => l.permitScopeCircleValue('${p['place'] ?? ''}', n(p['radius_km'])),
    _ => l.permitScopeWaysValue((p['way_ids'] as List<dynamic>? ?? const []).length),
  };
  return [scope, limits.join(', '), l.permitValid('${p['valid_from']}', '${p['valid_to']}')].join(' · ');
}

/// Zezwolenia na przejazd: lista, dodawanie, zmiana, usunięcie.
class PermitsScreen extends StatefulWidget {
  const PermitsScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<PermitsScreen> createState() => _PermitsScreenState();
}

class _PermitsScreenState extends State<PermitsScreen> {
  late Future<dynamic> _permits = widget.api.get('/api/permits');

  void _reload() => setState(() {
        _permits = widget.api.get('/api/permits');
      });

  Future<void> _open([Map<String, dynamic>? permit]) async {
    final saved = await Navigator.of(context)
        .push<dynamic>(MaterialPageRoute(builder: (_) => PermitFormScreen(api: widget.api, permit: permit)));
    if (saved != null && mounted) _reload();
  }

  Future<void> _delete(Map<String, dynamic> permit) async {
    try {
      await widget.api.delete('/api/permits/${permit['id']}');
      _reload();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final today = _day(DateTime.now());
    return Scaffold(
      appBar: AppBar(title: Text(l.permitsTitle)),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-permit',
        onPressed: _open,
        icon: const Icon(Icons.add),
        label: Text(l.permitAdd),
      ),
      body: FutureBuilder<dynamic>(
        future: _permits,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final permits = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
          return ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 80), children: [
            Text(l.permitsHint, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 8),
            if (permits.isEmpty) Text(l.permitsEmpty),
            for (final p in permits)
              Card(
                child: ListTile(
                  leading: Icon(
                    Icons.verified_outlined,
                    color: '${p['valid_to']}'.compareTo(today) < 0 ? Theme.of(context).disabledColor : Colors.blue,
                  ),
                  title: Text([p['number'], if ('${p['issuer']}'.isNotEmpty) p['issuer']].join(' · ')),
                  subtitle: Text(permitSummary(l, p)),
                  onTap: p['can_edit'] == true ? () => _open(p) : null,
                  trailing: p['can_edit'] == true
                      ? IconButton(
                          tooltip: l.delete, onPressed: () => _delete(p), icon: const Icon(Icons.delete_outline))
                      : const Icon(Icons.lock_outline),
                ),
              ),
          ]);
        },
      ),
    );
  }
}

/// Formularz zezwolenia: numer, wydawca, ważność, czego dotyczy, zasięg i pojazdy.
class PermitFormScreen extends StatefulWidget {
  const PermitFormScreen({super.key, required this.api, this.permit});

  final CoreApi api;
  final Map<String, dynamic>? permit;

  @override
  State<PermitFormScreen> createState() => _PermitFormScreenState();
}

class _PermitFormScreenState extends State<PermitFormScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, dynamic> _p = widget.permit ?? {};
  late final _number = TextEditingController(text: '${_p['number'] ?? ''}');
  late final _issuer = TextEditingController(text: '${_p['issuer'] ?? ''}');
  late final _place = TextEditingController(text: '${_p['place'] ?? ''}');
  late final Map<String, TextEditingController> _limits = {
    for (final key in const ['max_weight_t', 'max_axle_t', 'max_length_m', 'max_width_m', 'max_height_m', 'radius_km'])
      key: TextEditingController(text: _p[key] == null ? '' : '${_p[key]}'),
  };
  late DateTime _from = DateTime.tryParse('${_p['valid_from']}') ?? DateUtils.dateOnly(DateTime.now());
  late DateTime _to = DateTime.tryParse('${_p['valid_to']}') ?? _from.add(const Duration(days: 365));
  late bool _hgvBan = _p['hgv_ban'] == true;
  late String _scope = '${_p['scope'] ?? 'country'}';
  late String _country = '${_p['country'] ?? 'PL'}';
  late double? _lat = (_p['lat'] as num?)?.toDouble();
  late double? _lon = (_p['lon'] as num?)?.toDouble();
  late final Set<String> _vehicles = {for (final v in (_p['vehicle_ids'] as List<dynamic>? ?? const [])) '$v'};
  late final Future<dynamic> _allVehicles = widget.api.get('/api/vehicles');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final c in [_number, _issuer, _place, ..._limits.values]) {
      c.dispose();
    }
    super.dispose();
  }

  double? _value(String key) => double.tryParse(_limits[key]!.text.trim().replaceAll(',', '.'));

  Future<void> _pickDate(bool from) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: from ? _from : _to,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => from ? _from = picked : _to = picked);
  }

  Future<void> _save(List<Map<String, dynamic>> vehicles) async {
    if (!_form.currentState!.validate()) return;
    final chosen = [
      for (final v in vehicles)
        if (_vehicles.contains('${v['id']}')) v
    ];
    final body = {
      'company_id': chosen.isEmpty ? null : chosen.first['company_id'],
      'vehicle_ids': [for (final v in chosen) v['id']],
      'number': _number.text.trim(),
      'issuer': _issuer.text.trim(),
      'valid_from': _day(_from),
      'valid_to': _day(_to),
      for (final key in const ['max_weight_t', 'max_axle_t', 'max_length_m', 'max_width_m', 'max_height_m'])
        key: _value(key),
      'hgv_ban': _hgvBan,
      'scope': _scope,
      'country': _scope == 'country' ? _country : null,
      if (_scope == 'circle') ...{
        'place': _place.text.trim(),
        'lat': _lat,
        'lon': _lon,
        'radius_km': _value('radius_km')
      },
      if (_scope == 'ways') 'way_ids': _p['way_ids'] ?? const [],
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = widget.permit == null
          ? await widget.api.post('/api/permits', body)
          : await widget.api.put('/api/permits/${widget.permit!['id']}', body);
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
    final numbers = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    InputDecoration field(String label, {String? suffix}) =>
        InputDecoration(labelText: label, suffixText: suffix, border: const OutlineInputBorder(), isDense: true);
    String? number(String? text) =>
        (text ?? '').trim().isEmpty || double.tryParse(text!.trim().replaceAll(',', '.')) != null
            ? null
            : l.vehicleNumberRequired;
    return Scaffold(
      appBar: AppBar(title: Text(widget.permit == null ? l.permitAdd : l.permitEdit)),
      body: FutureBuilder<dynamic>(
        future: _allVehicles,
        builder: (context, snapshot) {
          final vehicles = [
            for (final v in (snapshot.data as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
              if (v['can_edit'] != false) v,
          ];
          return Form(
            key: _form,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              TextFormField(
                controller: _number,
                decoration: field(l.permitNumber),
                validator: (text) => (text ?? '').trim().isEmpty ? l.permitNumberRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(controller: _issuer, decoration: field(l.permitIssuer)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(
                  onPressed: () => _pickDate(true),
                  icon: const Icon(Icons.event),
                  label: Text(l.permitFrom(_day(_from))),
                ),
                OutlinedButton.icon(
                  onPressed: () => _pickDate(false),
                  icon: const Icon(Icons.event_busy),
                  label: Text(l.permitTo(_day(_to))),
                ),
              ]),
              const SizedBox(height: 16),
              Text(l.permitCovers, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (key, label, suffix) in [
                  ('max_weight_t', l.permitWeight, 't'),
                  ('max_axle_t', l.permitAxle, 't'),
                  ('max_length_m', l.permitLength, 'm'),
                  ('max_width_m', l.permitWidth, 'm'),
                  ('max_height_m', l.permitHeight, 'm'),
                ])
                  SizedBox(
                    width: 170,
                    child: TextFormField(
                      controller: _limits[key],
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: numbers,
                      decoration: field(label, suffix: suffix),
                      validator: number,
                    ),
                  ),
              ]),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _hgvBan,
                onChanged: (on) => setState(() => _hgvBan = on),
                title: Text(l.permitHgvBan),
              ),
              Text(l.permitCoversHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              Text(l.permitScope, style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(value: 'country', label: Text(l.permitScopeCountry)),
                  ButtonSegment(value: 'circle', label: Text(l.permitScopeCircle)),
                  if (_scope == 'ways') ButtonSegment(value: 'ways', label: Text(l.permitScopeWays)),
                ],
                selected: {_scope},
                onSelectionChanged: (value) => setState(() => _scope = value.first),
              ),
              const SizedBox(height: 12),
              if (_scope == 'country')
                DropdownButtonFormField<String>(
                  value: permitCountries.contains(_country) ? _country : 'PL',
                  decoration: field(l.permitCountry),
                  items: [for (final c in permitCountries) DropdownMenuItem(value: c, child: Text(c))],
                  onChanged: (value) => setState(() => _country = value ?? 'PL'),
                ),
              if (_scope == 'circle') ...[
                PlaceField(
                  api: widget.api,
                  label: l.permitPlace,
                  icon: Icons.place_outlined,
                  controller: _place,
                  onSelected: (place) => setState(() {
                    _lat = place.point.latitude;
                    _lon = place.point.longitude;
                  }),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 170,
                  child: TextFormField(
                    controller: _limits['radius_km'],
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: numbers,
                    decoration: field(l.permitRadius, suffix: 'km'),
                    validator: (text) =>
                        double.tryParse((text ?? '').trim().replaceAll(',', '.')) == null ? l.vehicleNumberRequired : null,
                  ),
                ),
                if (_lat == null) Text(l.permitPlaceRequired, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              Text(l.permitVehicles, style: theme.textTheme.titleSmall),
              Text(l.permitVehiclesHint, style: theme.textTheme.bodySmall),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final v in vehicles)
                  if (!towedKinds.contains(v['kind']) || v['kind'] == 'semitrailer' || v['kind'] == 'trailer')
                    FilterChip(
                      label: Text([v['name'], if (v['plate'] != null) v['plate']].join(' · ')),
                      selected: _vehicles.contains('${v['id']}'),
                      onSelected: (on) => setState(() {
                        if (on) {
                          // Zezwolenie jednej firmy (albo prywatne) – pojazdy jednego właściciela.
                          final company = v['company_id'];
                          _vehicles.removeWhere((id) =>
                              vehicles.firstWhere((x) => x['id'] == id, orElse: () => v)['company_id'] != company);
                          _vehicles.add('${v['id']}');
                        } else {
                          _vehicles.remove('${v['id']}');
                        }
                      }),
                    ),
              ]),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy || (_scope == 'circle' && _lat == null) ? null : () => _save(vehicles),
                child: Text(l.save),
              ),
            ]),
          );
        },
      ),
    );
  }
}
