import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../l10n.dart';

/// Rodzaje naczep (te same co na serwerze).
const trailerTypes = ['none', 'curtain', 'box', 'reefer', 'tanker', 'flatbed', 'container', 'lowloader'];

String trailerLabel(AppLocalizations l, String type) => switch (type) {
      'none' => l.trailerNone,
      'curtain' => l.trailerCurtain,
      'box' => l.trailerBox,
      'reefer' => l.trailerReefer,
      'tanker' => l.trailerTanker,
      'flatbed' => l.trailerFlatbed,
      'container' => l.trailerContainer,
      _ => l.trailerLowloader,
    };

/// Rodzaje pojazdów do wyboru (te same co na serwerze). „combination” – dawne wpisy zestawu
/// jako całości: można je zmieniać, ale nowych się nie dodaje.
const vehicleKinds = ['tractor', 'rigid', 'van', 'bus', 'semitrailer', 'trailer'];

/// Naczepy i przyczepy to wyposażenie floty – trasę liczy się dla pozostałych.
const towedKinds = {'semitrailer', 'trailer'};
/// Co do czego można podpiąć: do ciągnika naczepę, do solówki, autobusu i dostawczego przyczepę.
const couples = {'tractor': 'semitrailer', 'rigid': 'trailer', 'bus': 'trailer', 'van': 'trailer'};

bool isDrivable(Map<String, dynamic> vehicle) => !towedKinds.contains(vehicle['kind']);

String kindLabel(AppLocalizations l, String? kind) => switch (kind) {
      'rigid' => l.kindRigid,
      'tractor' => l.kindTractor,
      'van' => l.kindVan,
      'bus' => l.kindBus,
      'semitrailer' => l.kindSemitrailer,
      'trailer' => l.kindTrailer,
      _ => l.kindCombination,
    };

IconData kindIcon(String? kind) => switch (kind) {
      'semitrailer' || 'trailer' => Icons.rv_hookup,
      'van' => Icons.airport_shuttle_outlined,
      'bus' => Icons.directions_bus_outlined,
      _ => Icons.local_shipping_outlined,
    };

/// Zakresy jak na serwerze (VehicleIn) – błąd widać od razu, przed wysłaniem.
const _ranges = {
  'height_m': (1.5, 6.0),
  'width_m': (1.5, 4.5),
  'length_m': (3.0, 40.0),
  'weight_t': (1.0, 150.0),
  'gvw_t': (1.0, 150.0),
  'axle_load_t': (1.0, 20.0),
  'axle_count': (1.0, 20.0),
  'tank_volume_m3': (0.1, 100.0),
  'seats': (1.0, 120.0),
  'standing_places': (0.0, 200.0),
};

/// Nowy pojazd (bez [vehicle]) albo zmiana istniejącego. Zwraca zapisany pojazd z serwera.
class VehicleFormScreen extends StatefulWidget {
  const VehicleFormScreen({super.key, required this.api, this.vehicle});

  final CoreApi api;
  final Map<String, dynamic>? vehicle;

  @override
  State<VehicleFormScreen> createState() => _VehicleFormScreenState();
}

class _VehicleFormScreenState extends State<VehicleFormScreen> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _fields;
  late String _kind;
  late String _trailer;
  late bool _hazmat;
  late String _currency;
  String? _companyId;
  List<Map<String, dynamic>> _companies = const [];
  List<Map<String, dynamic>> _currencies = const [];
  Map<String, double> _perEur = const {};
  bool _busy = false;
  String? _error;

  bool get _editing => widget.vehicle != null;

  @override
  void initState() {
    super.initState();
    final v = widget.vehicle ?? const <String, dynamic>{};
    String text(String key, [Object? fallback]) {
      final value = v[key] ?? fallback;
      return value == null ? '' : '$value';
    }

    _fields = {
      'name': TextEditingController(text: text('name')),
      'plate': TextEditingController(text: text('plate')),
      'height_m': TextEditingController(text: text('height_m', 4.0)),
      'width_m': TextEditingController(text: text('width_m', 2.55)),
      'length_m': TextEditingController(text: text('length_m', 16.5)),
      'weight_t': TextEditingController(text: text('weight_t', 40)),
      'gvw_t': TextEditingController(text: text('gvw_t', 40)),
      'axle_load_t': TextEditingController(text: text('axle_load_t', 11.5)),
      'axle_count': TextEditingController(text: text('axle_count', 5)),
      'cost_per_km': TextEditingController(text: text('cost_per_km')),
      'cost_per_hour': TextEditingController(text: text('cost_per_hour')),
      'tank_volume_m3': TextEditingController(text: text('tank_volume_m3')),
      'seats': TextEditingController(text: text('seats')),
      'standing_places': TextEditingController(text: text('standing_places')),
    };
    _kind = v['kind'] as String? ?? (widget.vehicle == null ? 'tractor' : 'combination');
    _trailer = v['trailer_type'] as String? ?? 'curtain';
    _hazmat = v['hazmat'] == true;
    _currency = v['cost_currency'] as String? ?? 'EUR';
    _companyId = v['company_id'] as String?;
    _loadChoices();
  }

  bool _formatted = false;

  /// Liczby z serwera (4.0) pokazane w zapisie języka (po polsku „4”, „2,55”).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_formatted) return;
    _formatted = true;
    for (final entry in _fields.entries) {
      if (entry.key == 'name' || entry.key == 'plate') continue;
      final value = double.tryParse(entry.value.text);
      if (value != null) entry.value.text = context.l.number(value);
    }
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadChoices() async {
    try {
      final companies = (await widget.api.get('/api/companies') as List<dynamic>).cast<Map<String, dynamic>>();
      final currencies = await widget.api.get('/api/currencies') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        // Pojazd firmy dodają i zmieniają tylko właściciel i dyspozytorzy.
        _companies = [
          for (final c in companies)
            if (c['role'] == 'owner' || c['role'] == 'dispatcher' || c['id'] == _companyId) c,
        ];
        _currencies = (currencies['currencies'] as List<dynamic>).cast<Map<String, dynamic>>();
        _perEur = {
          for (final e in (currencies['per_eur'] as Map<String, dynamic>).entries) e.key: (e.value as num).toDouble(),
        };
      });
    } catch (_) {
      // Bez listy firm i walut formularz działa dalej (pojazd prywatny, waluta jak była).
    }
  }

  double? _number(String key) => double.tryParse(_fields[key]!.text.trim().replaceAll(',', '.'));

  String? _validate(String key, String? text, {bool required = true}) {
    final l = context.l;
    final value = text == null || text.trim().isEmpty ? null : double.tryParse(text.trim().replaceAll(',', '.'));
    if (value == null) return (text ?? '').trim().isEmpty && !required ? null : l.vehicleNumberRequired;
    final range = _ranges[key];
    if (range != null && (value < range.$1 || value > range.$2)) {
      return l.vehicleOutOfRange(l.number(range.$1), l.number(range.$2));
    }
    return null;
  }

  /// Zmiana waluty z wpisanymi stawkami – przeliczenie kursem EBC (jak w planerze w przeglądarce).
  void _changeCurrency(String currency) {
    final from = _perEur[_currency] ?? (_currency == 'EUR' ? 1.0 : null);
    final to = _perEur[currency] ?? (currency == 'EUR' ? 1.0 : null);
    setState(() {
      if (from != null && to != null) {
        for (final key in ['cost_per_km', 'cost_per_hour']) {
          final value = _number(key);
          if (value != null) _fields[key]!.text = context.l.number(value / from * to);
        }
      }
      _currency = currency;
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final body = {
      'name': _fields['name']!.text.trim(),
      'plate': _fields['plate']!.text.trim(),
      for (final key in ['height_m', 'width_m', 'length_m', 'weight_t', 'gvw_t', 'axle_load_t']) key: _number(key),
      'axle_count': _number('axle_count')!.round(),
      'kind': _kind,
      'trailer_type': _trailer,
      'tank_volume_m3': _trailer == 'tanker' ? _number('tank_volume_m3') : null,
      'seats': _kind == 'bus' ? _number('seats')?.round() : null,
      'standing_places': _kind == 'bus' ? _number('standing_places')?.round() : null,
      'hazmat': _hazmat,
      'cost_per_km': _number('cost_per_km'),
      'cost_per_hour': _number('cost_per_hour'),
      'cost_currency': _currency,
      'company_id': _companyId,
    };
    try {
      final saved = _editing
          ? await widget.api.put('/api/vehicles/${widget.vehicle!['id']}', body)
          : await widget.api.post('/api/vehicles', body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _numberField(String key, String label, {String? suffix, bool required = true, bool integer = false}) =>
      TextFormField(
        controller: _fields[key],
        keyboardType: TextInputType.numberWithOptions(decimal: !integer),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(integer ? r'[0-9]' : r'[0-9.,]'))],
        decoration:
            InputDecoration(labelText: label, suffixText: suffix, border: const OutlineInputBorder(), isDense: true),
        validator: (text) => _validate(key, text, required: required),
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final towed = towedKinds.contains(_kind);
    Widget row(List<Widget> children) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final (i, child) in children.indexed) ...[
              if (i > 0) const SizedBox(width: 12),
              Expanded(child: child),
            ],
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: Text(_editing ? l.vehicleEditTitle : l.vehicleAddTitle)),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          DropdownButtonFormField<String>(
            value: _kind,
            decoration: InputDecoration(labelText: l.vehicleKind, border: const OutlineInputBorder(), isDense: true),
            items: [
              for (final k in [if (_kind == 'combination') 'combination', ...vehicleKinds])
                DropdownMenuItem(value: k, child: Text(kindLabel(l, k))),
            ],
            onChanged: (value) => setState(() {
              _kind = value ?? _kind;
              if (towedKinds.contains(_kind) && _trailer == 'none') _trailer = 'curtain';
            }),
          ),
          const SizedBox(height: 12),
          row([
            TextFormField(
              controller: _fields['name'],
              maxLength: 100,
              decoration: InputDecoration(
                  labelText: l.vehicleName,
                  hintText: l.vehicleNameHint,
                  border: const OutlineInputBorder(),
                  isDense: true),
              validator: (text) => (text ?? '').trim().isEmpty ? l.vehicleNameRequired : null,
            ),
            TextFormField(
              controller: _fields['plate'],
              maxLength: 15,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                  labelText: l.vehiclePlate, hintText: 'KTA 12345', border: const OutlineInputBorder(), isDense: true),
            ),
          ]),
          Text(l.vehicleDimensions, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          row([
            _numberField('height_m', l.vehicleHeight, suffix: 'm'),
            _numberField('width_m', l.vehicleWidth, suffix: 'm'),
            _numberField('length_m', l.vehicleLength, suffix: 'm'),
          ]),
          row([
            _numberField('weight_t', l.vehicleWeight, suffix: 't'),
            _numberField('gvw_t', l.vehicleGvw, suffix: 't'),
          ]),
          row([
            _numberField('axle_load_t', l.vehicleAxleLoad, suffix: 't'),
            _numberField('axle_count', l.vehicleAxleCount, integer: true),
          ]),
          DropdownButtonFormField<String>(
            value: _trailer,
            decoration: InputDecoration(
                labelText: towed ? l.vehicleBody : l.vehicleTrailer, border: const OutlineInputBorder(), isDense: true),
            items: [
              for (final t in trailerTypes)
                if (!towed || t != 'none') DropdownMenuItem(value: t, child: Text(trailerLabel(l, t))),
            ],
            onChanged: (value) => setState(() => _trailer = value ?? _trailer),
          ),
          if (_kind == 'bus')
            row([
              _numberField('seats', l.vehicleSeats, integer: true),
              _numberField('standing_places', l.vehicleStanding, integer: true, required: false),
            ]),
          if (_trailer == 'tanker') ...[
            const SizedBox(height: 12),
            _numberField('tank_volume_m3', l.vehicleTankVolume, suffix: 'm³', required: false),
          ],
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _hazmat,
            onChanged: (on) => setState(() => _hazmat = on),
            title: Text(l.vehicleHazmat),
          ),
          const SizedBox(height: 8),
          Text(l.vehicleCosts, style: theme.textTheme.titleSmall),
          Text(l.vehicleCostsHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          row([
            _numberField('cost_per_km', l.vehicleCostPerKm, suffix: _currency, required: false),
            _numberField('cost_per_hour', l.vehicleCostPerHour, suffix: _currency, required: false),
            DropdownButtonFormField<String>(
              value: _currency,
              decoration:
                  InputDecoration(labelText: l.vehicleCurrency, border: const OutlineInputBorder(), isDense: true),
              items: [
                for (final c in _currencies.isEmpty
                    ? [
                        {'code': _currency}
                      ]
                    : _currencies)
                  DropdownMenuItem(value: c['code'] as String, child: Text(c['code'] as String)),
              ],
              onChanged: (value) {
                if (value != null && value != _currency) _changeCurrency(value);
              },
            ),
          ]),
          if (_companies.isNotEmpty) ...[
            DropdownButtonFormField<String?>(
              value: _companyId,
              decoration: InputDecoration(labelText: l.vehicleOwner, border: const OutlineInputBorder(), isDense: true),
              items: [
                DropdownMenuItem(value: null, child: Text(l.vehiclePrivate)),
                for (final c in _companies) DropdownMenuItem(value: c['id'] as String, child: Text('${c['name']}')),
              ],
              onChanged: (value) => setState(() => _companyId = value),
            ),
            const SizedBox(height: 12),
          ],
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
