import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'deck_view.dart';
import 'panels.dart';
import 'sim_view.dart';
import 'texts.dart';

const _base = '/api/m/load';

/// Rodzaje z przestrzenią ładunkową (jak na serwerze – zabudowa).
const cargoKinds = {'combination', 'rigid', 'van', 'semitrailer', 'trailer'};
const itemKinds = ['euro', 'industrial', 'half', 'custom'];
const bodyCodes = ['unknown', 'L', 'XL'];

/// Ikony kształtów towaru (wybór rodzaju i okno własnego rodzaju).
const _shapeIcons = <String, IconData>{
  'pallet': Icons.view_module_outlined,
  'box': Icons.inventory_2_outlined,
  'drum': Icons.propane_tank_outlined,
  'roll': Icons.album_outlined,
  'coil': Icons.donut_large,
  'bale': Icons.grass,
  'bale_round': Icons.circle_outlined,
  'bag': Icons.shopping_bag_outlined,
  'long': Icons.straighten,
  'vehicle': Icons.agriculture_outlined,
  'bulk': Icons.landslide_outlined,
};

/// Sprzęt z listy VDI 2700 (te same identyfikatory co na serwerze).
const gearIds = ['straps', 'edges', 'beams', 'mats', 'airbags', 'chains', 'chocks', 'net', 'stakes'];

/// Okno „Moje wyposażenie”: ile sztuk sprzętu ma użytkownik i czy uwzględniać je w planie.
class EquipmentDialog extends StatefulWidget {
  const EquipmentDialog({super.key, required this.items, required this.enabled});

  final Map<String, int> items;
  final bool enabled;

  @override
  State<EquipmentDialog> createState() => _EquipmentDialogState();
}

class _EquipmentDialogState extends State<EquipmentDialog> {
  late final _fields = {for (final id in gearIds) id: TextEditingController(text: '${widget.items[id] ?? 0}')};
  late bool _enabled = widget.enabled || widget.items.isEmpty;

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    return AlertDialog(
      title: Text(t.myEquipmentTitle),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(t.equipmentHint, style: Theme.of(context).textTheme.bodySmall),
            SwitchListTile(
              key: const Key('equipment-enabled'),
              contentPadding: EdgeInsets.zero,
              value: _enabled,
              onChanged: (on) => setState(() => _enabled = on),
              title: Text(t.useEquipment),
            ),
            Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
              for (final id in gearIds)
                SizedBox(
                  width: 260,
                  child: TextField(
                    key: Key('equipment-$id'),
                    controller: _fields[id],
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: _field(t.gear(id), suffix: t.pieces(0).replaceAll('0', '').trim()),
                  ),
                ),
            ]),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
          key: const Key('equipment-save'),
          onPressed: () => Navigator.of(context).pop((
            {for (final e in _fields.entries) e.key: int.tryParse(e.value.text) ?? 0},
            _enabled,
          )),
          child: Text(t.save),
        ),
      ],
    );
  }
}

/// Okno własnego rodzaju towaru: nazwa, grupa, kształt, wymiary, masa, tarcie, mocowanie, stos.
class CustomCargoDialog extends StatefulWidget {
  const CustomCargoDialog({super.key, required this.groups});

  final List<Map<String, dynamic>> groups;

  @override
  State<CustomCargoDialog> createState() => _CustomCargoDialogState();
}

class _CustomCargoDialogState extends State<CustomCargoDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _fields = {
    'length_m': TextEditingController(text: '1.2'),
    'width_m': TextEditingController(text: '0.8'),
    'height_m': TextEditingController(text: '1.0'),
    'weight_kg': TextEditingController(text: '500'),
    'mu': TextEditingController(text: '0.3'),
    'stack': TextEditingController(text: '1'),
  };

  /// Grupa „Inne i własne”, a gdy jej nie ma – pierwsza z katalogu.
  late String _group =
      widget.groups.any((g) => g['id'] == 'other') ? 'other' : '${widget.groups.firstOrNull?['id'] ?? 'other'}';
  String _shape = 'box';
  String _securing = 'top';

  @override
  void dispose() {
    for (final c in [_name, ..._fields.values]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final numbers = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    String? number(String? text) => _parse(text ?? '') == null ? t.numberInvalid : null;
    Widget field(String key, String label, {String? suffix}) => SizedBox(
          width: 160,
          child: TextFormField(
            key: Key('custom-$key'),
            controller: _fields[key],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: numbers,
            decoration: _field(label, suffix: suffix),
            validator: number,
          ),
        );
    Widget drop(String label, String value, List<(String, String)> items, ValueChanged<String> on) => SizedBox(
          width: 330,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: value,
            decoration: _field(label),
            items: [for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l))],
            onChanged: (v) => setState(() => on(v ?? value)),
          ),
        );
    return AlertDialog(
      title: Text(t.customCargoTitle),
      content: SizedBox(
        width: 680,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
              SizedBox(
                width: 680,
                child: TextFormField(
                  key: const Key('custom-name'),
                  controller: _name,
                  maxLength: 60,
                  decoration: _field(t.customName),
                  validator: (v) => (v ?? '').trim().isEmpty ? t.numberInvalid : null,
                ),
              ),
              drop(t.customGroup, _group, [for (final g in widget.groups) ('${g['id']}', '${g['name']}')],
                  (v) => _group = v),
              drop(t.customShape, _shape, [for (final s in _shapeIcons.keys) (s, t.shape(s))], (v) => _shape = v),
              field('length_m', t.length, suffix: 'm'),
              field('width_m', t.width, suffix: 'm'),
              field('height_m', t.height, suffix: 'm'),
              field('weight_kg', t.customWeight, suffix: 'kg'),
              field('mu', t.customMu),
              field('stack', t.customStack),
              drop(
                  t.customSecuring,
                  _securing,
                  [
                    for (final s in ['top', 'direct', 'none']) (s, t.securingName(s))
                  ],
                  (v) => _securing = v),
              Text(t.customHint, style: Theme.of(context).textTheme.bodySmall),
            ]),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.cancel)),
        FilledButton(
          key: const Key('custom-save'),
          onPressed: () {
            if (!_form.currentState!.validate()) return;
            final v = {for (final e in _fields.entries) e.key: _parse(e.value.text)!};
            Navigator.of(context).pop({
              'name': _name.text.trim(),
              'group': _group,
              'shape': _shape,
              'securing': _securing,
              ...v,
              'stack': v['stack']!.round(),
            });
          },
          child: Text(t.save),
        ),
      ],
    );
  }
}

/// Wymiary palet – do zamiany palet na „inny wymiar” (tryb bezpaletowy).
const _footprints = {'euro': ('1.2', '0.8'), 'industrial': ('1.2', '1.0'), 'half': ('0.8', '0.6')};

typedef LinkOpener = Future<bool> Function(Uri link);

Future<bool> openLink(Uri link) => launchUrl(link, mode: LaunchMode.externalApplication);

double? _parse(String text) => double.tryParse(text.trim().replaceAll(',', '.'));

InputDecoration _field(String label, {String? suffix}) =>
    InputDecoration(labelText: label, suffixText: suffix, isDense: true);

/// Pozycja ładunku w formularzu.
class _Item {
  String kind = 'euro';

  /// Rodzaj towaru z katalogu (`null` – paleta wg [kind]).
  String? cargo;
  final count = TextEditingController(text: '1');
  final weight = TextEditingController();
  final stack = TextEditingController(text: '1');
  final stop = TextEditingController(text: '1');
  final length = TextEditingController();
  final width = TextEditingController();
  final height = TextEditingController();

  List<TextEditingController> get all => [count, weight, stack, stop, length, width, height];

  Map<String, dynamic> json() => {
        'kind': kind,
        if (cargo != null) 'cargo': cargo,
        'count': _parse(count.text)?.round() ?? 1,
        'weight_kg': _parse(weight.text),
        'stack': _parse(stack.text)?.round() ?? 1,
        'stop': _parse(stop.text)?.round() ?? 1,
        if (kind == 'custom') 'length_m': _parse(length.text),
        if (kind == 'custom') 'width_m': _parse(width.text),
        if (_parse(height.text) != null) 'height_m': _parse(height.text),
      };
}

/// Zlecenia i załadunek: pojazd i ładunek zlecenia → symulator (izometria, rzut, przekrój),
/// naciski na osie, bilans sił EN 12195-1, lista sprzętu VDI 2700, normy, PDF i zatwierdzenie.
class LoadPlanScreen extends StatefulWidget {
  const LoadPlanScreen({super.key, required this.api, this.vehicleId, this.linkOpener = openLink});

  final CoreApi api;

  /// Pojazd wybrany z góry (np. z karty pojazdu).
  final String? vehicleId;
  final LinkOpener linkOpener;

  @override
  State<LoadPlanScreen> createState() => _LoadPlanScreenState();
}

class _LoadPlanScreenState extends State<LoadPlanScreen> {
  late final Future<dynamic> _vehicles = widget.api.get('/api/vehicles');

  /// Katalog rodzajów towaru (grupy i rodzaje, także własne); `null` – jeszcze nie ma.
  Map<String, dynamic>? _catalog;

  Map<String, Map<String, dynamic>> get _types => {
        for (final c in (_catalog?['types'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>())
          '${c['id']}': c,
      };

  @override
  void initState() {
    super.initState();
    _loadCatalog();
    _loadEquipment();
  }

  Future<void> _loadCatalog() async {
    try {
      final catalog = await widget.api.get('$_base/cargo-types');
      if (mounted && catalog is Map<String, dynamic>) setState(() => _catalog = catalog);
    } catch (_) {
      // Bez katalogu zostają palety i „inny wymiar”.
    }
  }

  /// Wygląd pozycji na rysunku: kształt i grupa rodzaju towaru.
  CargoLook _look(_Item item) {
    final type = _types[item.cargo];
    return CargoLook(
      item.kind,
      shape: '${type?['shape'] ?? (item.kind == 'custom' ? 'box' : 'pallet')}',
      group: '${type?['group'] ?? (item.kind == 'custom' ? 'other' : 'pallets')}',
      name: '${type?['name'] ?? ''}',
      securing: '${type?['securing'] ?? 'top'}',
      gear: [for (final g in (type?['gear'] as List<dynamic>? ?? const [])) '$g'],
    );
  }

  String _cargoName(LoadTexts t, _Item item) => '${_types[item.cargo]?['name'] ?? t.kind(item.kind)}';

  String _num(num value) => '$value'.replaceAll(RegExp(r'\.0$'), '');

  /// Rodzaj wybrany: paleta standardowa albo wymiary, wysokość i masa z katalogu (do zmiany).
  void _applyCargo(_Item item, Map<String, dynamic> type) {
    _changed(() {
      item.cargo = '${type['id']}';
      item.kind = '${type['kind']}';
      if (item.kind == 'custom') {
        item.length.text = _num(type['length_m'] as num);
        item.width.text = _num(type['width_m'] as num);
      }
      if (item.height.text.trim().isEmpty && item.kind == 'custom') item.height.text = _num(type['height_m'] as num);
      if (item.weight.text.trim().isEmpty) item.weight.text = _num(type['weight_kg'] as num);
      final max = (type['stack'] as int?) ?? 1;
      if ((_parse(item.stack.text) ?? 1) > max) item.stack.text = '$max';
    });
  }

  Future<void> _pickCargo(_Item item) async {
    final t = LoadTexts.of(context);
    final catalog = _catalog;
    if (catalog == null) return;
    final groups = (catalog['groups'] as List<dynamic>).cast<Map<String, dynamic>>();
    final types = (catalog['types'] as List<dynamic>).cast<Map<String, dynamic>>();
    String details(Map<String, dynamic> c) => t.cargoDetails(
        '${t.number(c['length_m'] as num)} × ${t.number(c['width_m'] as num)} × ${t.number(c['height_m'] as num)} m',
        '${t.number(c['weight_kg'] as num)} kg',
        t.number(c['mu'] as num));
    final picked = await showGroupedPicker<String>(
      context,
      texts: PickerTexts(title: t.cargoPickerTitle, search: t.cargoSearch, empty: t.pickerEmpty, all: t.pickerAll),
      selected: item.cargo,
      groups: [
        for (final g in groups)
          if (types.any((c) => c['group'] == g['id']))
            PickerGroup('${g['name']}', [
              for (final c in types)
                if (c['group'] == g['id'])
                  PickerOption(
                    '${c['id']}',
                    c['custom'] == true ? '${c['name']} (${t.customBadge})' : '${c['name']}',
                    subtitle: details(c),
                    icon: _shapeIcons['${c['shape']}'],
                    trailing: c['custom'] == true
                        ? Builder(
                            builder: (dialog) => IconButton(
                              key: ValueKey('cargo-delete-${c['id']}'),
                              tooltip: t.delete,
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => Navigator.of(dialog).pop('delete:${c['id']}'),
                            ),
                          )
                        : null,
                  ),
            ]),
      ],
      actions: (dialog) => [
        TextButton.icon(
          key: const Key('cargo-add-custom'),
          onPressed: () => Navigator.of(dialog).pop('new'),
          icon: const Icon(Icons.add),
          label: Text(t.addCustomCargo),
        ),
      ],
    );
    if (!mounted || picked == null) return;
    if (picked == 'new') return _addCustom(item);
    if (picked.startsWith('delete:')) return _deleteCustom(item, picked.substring(7));
    final type = _types[picked];
    if (type != null) _applyCargo(item, type);
  }

  Future<void> _addCustom(_Item item) async {
    final groups = (_catalog?['groups'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final data = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => CustomCargoDialog(groups: groups),
    );
    if (data == null || !mounted) return;
    try {
      final created = await widget.api.post('$_base/cargo-types', data) as Map<String, dynamic>;
      await _loadCatalog();
      if (mounted) _applyCargo(item, created);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _deleteCustom(_Item item, String id) async {
    final t = LoadTexts.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        content: Text(t.deleteCargo('${_types[id]?['name'] ?? ''}')),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(false), child: Text(t.cancel)),
          FilledButton(
              key: const Key('cargo-delete-confirm'),
              onPressed: () => Navigator.of(dialog).pop(true),
              child: Text(t.delete)),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.api.delete('$_base/cargo-types/$id');
      for (final i in _items.where((i) => i.cargo == id)) {
        i.cargo = null;
      }
      await _loadCatalog();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  final _form = GlobalKey<FormState>();
  final _items = [_Item()];
  final _deck = TextEditingController();
  final _reference = TextEditingController();
  late String? _vehicleId = widget.vehicleId;
  String _bodyCode = 'unknown';
  bool _frontWall = true;
  bool _mats = false;
  bool _busy = false;
  bool _checking = false;
  bool _manual = false;
  String? _error;
  Map<String, dynamic>? _plan;
  String _view = 'iso';
  bool _straps = true;
  bool _vectors = true;
  final _checked = <String>{};

  /// Wyposażenie użytkownika (ile sztuk sprzętu ma) i czy uwzględniać je w planie.
  Map<String, int> _equipment = {};
  bool _useEquipment = false;

  /// Plan zaproponował maty (z wyposażenia) – sprawdzenie ręcznego ułożenia i PDF też z matami.
  bool get _planMats => _plan?['mats'] == true;

  Future<void> _loadEquipment() async {
    try {
      final data = await widget.api.get('$_base/equipment') as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _equipment = {for (final e in (data['items'] as Map<String, dynamic>).entries) e.key: e.value as int};
        _useEquipment = data['enabled'] == true;
      });
    } catch (_) {
      // Bez zapisanego wyposażenia – plan bez ograniczeń sprzętu.
    }
  }

  Future<void> _editEquipment() async {
    final result = await showDialog<(Map<String, int>, bool)>(
      context: context,
      builder: (_) => EquipmentDialog(items: _equipment, enabled: _useEquipment),
    );
    if (result == null || !mounted) return;
    final (items, enabled) = result;
    _changed(() {
      _equipment = items;
      _useEquipment = enabled;
    });
    try {
      await widget.api.put('$_base/equipment', {'items': items, 'enabled': enabled});
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
    if (_plan != null && mounted) await _recalculate();
  }

  /// Sprzęt z listy pod kursorem – podświetlony na rysunku.
  String? _gearHover;
  bool _approved = false;

  Map<String, dynamic> _body() => {
        'vehicle_id': _vehicleId,
        'items': [for (final i in _items) i.json()],
        if (_parse(_deck.text) != null) 'deck_length_m': _parse(_deck.text),
        'front_wall': _frontWall,
        'mats': _mats,
        'body_code': _bodyCode,
        'reference': _reference.text.trim(),
        if (_useEquipment) 'available': _equipment,
      };

  /// Każda zmiana danych cofa zatwierdzenie planu.
  void _changed(VoidCallback change) => setState(() {
        change();
        _approved = false;
      });

  Future<void> _run(Future<dynamic> Function() call, {bool check = false}) async {
    setState(() {
      check ? _checking = true : _busy = true;
      _error = null;
      _approved = false;
    });
    try {
      final plan = await call();
      if (mounted) setState(() => _plan = plan as Map<String, dynamic>);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _checking = false;
        });
      }
    }
  }

  /// Ręczne ułożenie (przeciągnięte palety): serwer liczy naciski i ostrzeżenia od nowa.
  Future<void> _check(List<Map<String, dynamic>> placed) {
    _manual = true;
    return _run(() => widget.api.post('$_base/plan/check', {..._body(), 'mats': _mats || _planMats, 'placed': placed}),
        check: true);
  }

  Future<void> _calculate() async {
    if (!_form.currentState!.validate() || _vehicleId == null) return;
    _manual = false;
    await _run(() => widget.api.post('$_base/plan', _body()));
  }

  /// „Przelicz siły”: ręczne ułożenie zostaje, inaczej plan od nowa.
  Future<void> _recalculate() async {
    final plan = _plan;
    if (_manual && plan != null && _form.currentState!.validate()) {
      return _check((plan['placed'] as List<dynamic>).cast<Map<String, dynamic>>());
    }
    return _calculate();
  }

  Future<void> _export() async {
    final t = LoadTexts.of(context);
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      final link = await widget.api.post('$_base/plan/pdf', {
        ..._body(),
        if (_manual && _plan != null) 'placed': _plan!['placed'],
        if (_manual) 'mats': _mats || _planMats,
        'checked': _checked.toList(),
        'approved': _approved,
      }) as Map<String, dynamic>;
      final opened = await widget.linkOpener(widget.api.uri('${link['path']}'));
      if (!opened) messenger?.showSnackBar(SnackBar(content: Text(t.exportFailed)));
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  List<Map<String, dynamic>> _gear(Map<String, dynamic> plan) =>
      (plan['equipment'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();

  bool _canApprove(Map<String, dynamic>? plan) {
    if (plan == null || plan['fits'] != true) return false;
    final norms = (plan['norms'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    if (norms.any((n) => n['ok'] != true)) return false;
    return _gear(plan).every((g) => (g['required'] as int) == 0 || _checked.contains(g['id']));
  }

  /// Tryb symulatora z pozycji ładunku.
  String get _mode {
    if (_items.any((i) => i.kind == 'custom')) return 'bulk';
    if (_items.any((i) => (_parse(i.stack.text) ?? 1) >= 2)) return 'stacked';
    return 'standard';
  }

  void _setMode(String mode) {
    _changed(() {
      for (final item in _items) {
        switch (mode) {
          case 'bulk':
            final size = _footprints[item.kind];
            if (size != null) {
              if (item.length.text.trim().isEmpty) item.length.text = size.$1;
              if (item.width.text.trim().isEmpty) item.width.text = size.$2;
            }
            item.kind = 'custom';
          case 'stacked':
            if (item.kind == 'custom') {
              item.kind = 'euro';
              item.cargo = null;
            }
            item.stack.text = '2';
          default:
            if (item.kind == 'custom') {
              item.kind = 'euro';
              item.cargo = null;
            }
            item.stack.text = '1';
        }
      }
    });
    if (_plan != null) _calculate();
  }

  @override
  void dispose() {
    for (final c in [_deck, _reference, for (final i in _items) ...i.all]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    return FutureBuilder<dynamic>(
      future: _vehicles,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final data = snapshot.data;
        final all = data is List ? data.whereType<Map<String, dynamic>>().toList() : <Map<String, dynamic>>[];
        final vehicles = [
          for (final v in all)
            if (cargoKinds.contains(v['kind'])) v
        ];
        if (vehicles.isEmpty) return Center(child: Text(t.noVehicles));
        _vehicleId ??= '${vehicles.first['id']}';
        final cargo = vehicles.firstWhere((v) => '${v['id']}' == _vehicleId, orElse: () => vehicles.first);
        final tractor =
            all.where((v) => v['trailer_id'] != null && '${v['trailer_id']}' == '${cargo['id']}').firstOrNull;
        final plan = _plan;
        final canApprove = _canApprove(plan);
        final header = LoadHeader(
          cargo: cargo,
          tractor: tractor,
          plan: plan,
          bodyCode: _bodyCode,
          reference: _reference.text.trim(),
          mats: _mats,
          approved: _approved,
          busy: _busy || _checking,
          onForces: _busy ? null : _recalculate,
          onExport: plan == null ? null : _export,
          onApprove: plan == null || _approved
              ? null
              : () {
                  if (canApprove) {
                    setState(() => _approved = true);
                  } else {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(t.approveBlocked)));
                  }
                },
        );
        final form = _orderForm(context, vehicles);
        final simulator = SimulatorCard(
          plan: plan,
          kinds: [for (final i in _items) _look(i)],
          mode: _mode,
          onMode: _busy ? null : _setMode,
          view: _view,
          onView: (v) => setState(() => _view = v),
          straps: _straps,
          onStraps: (v) => setState(() => _straps = v),
          vectors: _vectors,
          onVectors: (v) => setState(() => _vectors = v),
          highlight: _gearHover,
          edit: plan == null
              ? null
              : PlanDeck(plan: plan, onMoved: _check, onRearrange: _busy ? null : _calculate, embedded: true),
        );
        final gear = plan == null
            ? null
            : GearTable(
                plan: plan,
                checked: _checked,
                onChecked: (id, on) => _changed(() => on ? _checked.add(id) : _checked.remove(id)),
                available: _useEquipment ? _equipment : null,
                highlight: _gearHover,
                onHighlight: (id) {
                  if (id != _gearHover) setState(() => _gearHover = id);
                },
              );
        final side = plan == null
            ? <Widget>[
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(Gap.l),
                    child: Text(t.resultHint, style: Theme.of(context).textTheme.bodyMedium),
                  ),
                ),
              ]
            : <Widget>[
                AxlePanel(plan: plan),
                ForcesPanel(plan: plan),
                NormsPanel(
                    plan: plan,
                    gearDone: _gear(plan).every((g) => (g['required'] as int) == 0 || _checked.contains(g['id']))),
                if ((plan['warnings'] as List<dynamic>? ?? const []).isNotEmpty) WarningsPanel(plan: plan),
              ];
        return Form(
          key: _form,
          child: LayoutBuilder(builder: (context, size) {
            final wide = size.maxWidth >= 1000;
            final pad = wide ? Gap.xl : Gap.l;
            Widget column(List<Widget> children) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: Gap.l), c],
                  ],
                );
            if (wide) {
              return ListView(padding: EdgeInsets.all(pad), children: [
                header,
                const SizedBox(height: Gap.l),
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 8, child: column([simulator, if (gear != null) gear, form])),
                  const SizedBox(width: Gap.xl),
                  Expanded(flex: 4, child: column(side)),
                ]),
                const SizedBox(height: Gap.l),
                const LoadDisclaimer(),
              ]);
            }
            return ListView(padding: EdgeInsets.all(pad), children: [
              column([header, form, simulator, ...side, if (gear != null) gear, const LoadDisclaimer()]),
            ]);
          }),
        );
      },
    );
  }

  Widget _orderForm(BuildContext context, List<Map<String, dynamic>> vehicles) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final fill = TruckColors.of(context).card;
    final numbers = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    String? required(String? text) => _parse(text ?? '') == null ? t.numberInvalid : null;
    Widget sized(Widget child, [double width = 260]) => SizedBox(width: width, child: child);
    return SectionCard(
      title: t.orderItems,
      icon: Icons.inventory_2_outlined,
      action: TextButton.icon(
        onPressed: () => _changed(() => _items.add(_Item())),
        icon: const Icon(Icons.add),
        label: Text(t.addItem),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: Gap.m, runSpacing: Gap.m, children: [
          sized(
            DropdownButtonFormField<String>(
              isExpanded: true,
              value: _vehicleId,
              decoration: _field(t.vehicle),
              items: [
                for (final v in vehicles)
                  DropdownMenuItem(
                    value: '${v['id']}',
                    child: Text([v['name'], if (v['plate'] != null) v['plate']].join(' · ')),
                  ),
              ],
              onChanged: (id) => _changed(() => _vehicleId = id),
            ),
            320,
          ),
          sized(TextFormField(
            controller: _reference,
            decoration: _field(t.reference),
            maxLength: 40,
            buildCounter: (_, {required currentLength, required isFocused, maxLength}) => null,
            onChanged: (_) => _changed(() {}),
          )),
          sized(DropdownButtonFormField<String>(
            isExpanded: true,
            value: _bodyCode,
            decoration: _field(t.bodyCode),
            items: [for (final c in bodyCodes) DropdownMenuItem(value: c, child: Text(t.body(c)))],
            onChanged: (c) => _changed(() => _bodyCode = c ?? 'unknown'),
          )),
          sized(TextFormField(
            controller: _deck,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: numbers,
            decoration: _field(t.deckLength, suffix: 'm'),
          )),
        ]),
        for (final (index, item) in _items.indexed)
          Container(
            margin: const EdgeInsets.only(top: Gap.m),
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: TruckColors.of(context).surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: _catalog == null
                      ? DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: item.kind,
                          decoration: _field(t.items).copyWith(fillColor: fill),
                          items: [for (final k in itemKinds) DropdownMenuItem(value: k, child: Text(t.kind(k)))],
                          onChanged: (k) => _changed(() => item.kind = k ?? 'euro'),
                        )
                      : PickerField(
                          key: ValueKey('cargo-field-$index'),
                          label: t.cargoType,
                          value: _cargoName(t, item),
                          icon: _shapeIcons[_look(item).shape],
                          onTap: () => _pickCargo(item),
                        ),
                ),
                if (_items.length > 1)
                  IconButton(
                    onPressed: () => _changed(() => _items.removeAt(index).all.forEach((c) => c.dispose())),
                    icon: const Icon(Icons.close),
                  ),
              ]),
              const SizedBox(height: Gap.s),
              Wrap(spacing: Gap.s, runSpacing: Gap.s, children: [
                for (final (controller, label, suffix, check) in [
                  (item.count, t.count, null, true),
                  (item.weight, t.weight, 'kg', true),
                  (item.stack, t.stack, null, true),
                  (item.stop, t.stop, null, true),
                  if (item.kind == 'custom') (item.length, t.length, 'm', true),
                  if (item.kind == 'custom') (item.width, t.width, 'm', true),
                  (item.height, t.height, 'm', false),
                ])
                  SizedBox(
                    width: 150,
                    child: TextFormField(
                      controller: controller,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: numbers,
                      decoration: _field(label, suffix: suffix).copyWith(fillColor: fill),
                      validator: check ? required : (text) => (text ?? '').trim().isEmpty ? null : required(text),
                    ),
                  ),
              ]),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: Gap.m),
          child: Wrap(spacing: Gap.m, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
            OutlinedButton.icon(
              key: const Key('my-equipment'),
              onPressed: _editEquipment,
              icon: const Icon(Icons.handyman_outlined),
              label: Text(t.myEquipment),
            ),
            StatusChip(
              label: _useEquipment ? t.equipmentOn(_equipment.values.where((v) => v > 0).length) : t.equipmentOff,
              tone: _useEquipment ? StatusTone.info : StatusTone.neutral,
              uppercase: false,
            ),
          ]),
        ),
        Wrap(spacing: Gap.xl, children: [
          for (final (value, label, set) in [
            (_frontWall, t.frontWall, (bool on) => _frontWall = on),
            (_mats, t.mats, (bool on) => _mats = on),
          ])
            SizedBox(
              width: 300,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: value,
                onChanged: (on) => _changed(() => set(on)),
                title: Text(label),
              ),
            ),
        ]),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: Gap.m),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: _busy ? null : _calculate,
            icon: const Icon(Icons.calculate_outlined),
            label: Text(t.calculate),
          ),
        ),
      ]),
    );
  }
}

/// Rozmieszczenie do edycji: widoki z góry i z boku (przód – po lewej) z przybliżaniem,
/// przesuwaniem obrazu i przeciąganiem palet; „Ułóż automatycznie” – plan od nowa bez przekroczeń.
class PlanDeck extends StatefulWidget {
  const PlanDeck({super.key, required this.plan, this.onMoved, this.onRearrange, this.embedded = false});

  final Map<String, dynamic> plan;

  /// Palety przeciągnięte – nowe ułożenie do sprawdzenia; `null` – bez przeciągania.
  final ValueChanged<List<Map<String, dynamic>>>? onMoved;
  final VoidCallback? onRearrange;

  /// W karcie symulatora – bez własnej karty.
  final bool embedded;

  @override
  State<PlanDeck> createState() => _PlanDeckState();
}

class _PlanDeckState extends State<PlanDeck> {
  bool _moving = false;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final plan = widget.plan;
    String m(Object? value) => value is num ? '${t.number(value)} m' : '–';
    final content = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: Gap.s, runSpacing: Gap.s, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (widget.onMoved != null)
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(value: false, icon: const Icon(Icons.pan_tool_outlined), label: Text(t.moveView)),
              ButtonSegment(value: true, icon: const Icon(Icons.open_with), label: Text(t.moveItems)),
            ],
            selected: {_moving},
            onSelectionChanged: (value) => setState(() => _moving = value.first),
          ),
        if (widget.onRearrange != null)
          OutlinedButton.icon(
            onPressed: widget.onRearrange,
            icon: const Icon(Icons.auto_fix_high_outlined),
            label: Text(t.rearrange),
          ),
      ]),
      const SizedBox(height: Gap.s),
      Text(_moving ? t.moveItemsHint : (desktop ? t.moveViewHintDesktop : t.moveViewHint),
          style: theme.textTheme.bodySmall),
      Text(t.front, style: theme.textTheme.bodySmall),
      DeckView(plan: plan, moving: _moving && widget.onMoved != null, onMoved: widget.onMoved ?? (_) {}),
      const SizedBox(height: Gap.s),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Gap.s),
        decoration: BoxDecoration(
          color: TruckColors.of(context).surfaceLow,
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        ),
        child: Text(t.deckDims(m(plan['deck_length_m']), m(plan['deck_width_m']), m(plan['inner_height_m'])),
            style: theme.textTheme.labelMedium),
      ),
      const SizedBox(height: Gap.s),
      Text(t.heightHint, style: theme.textTheme.bodySmall),
    ]);
    if (widget.embedded) return content;
    return SectionCard(title: t.layoutTitle, icon: Icons.view_in_ar_outlined, child: content);
  }
}

/// Symulator: tryb ładunku, widok (izometria / rzut / przekrój / edycja), nakładki, legenda, dane naczepy.
class SimulatorCard extends StatelessWidget {
  const SimulatorCard({
    super.key,
    required this.plan,
    required this.kinds,
    required this.mode,
    required this.onMode,
    required this.view,
    required this.onView,
    required this.straps,
    required this.onStraps,
    required this.vectors,
    required this.onVectors,
    this.edit,
    this.highlight,
  });

  /// Sprzęt podświetlony z listy VDI 2700.
  final String? highlight;
  final Map<String, dynamic>? plan;
  final List<CargoLook> kinds;
  final String mode;
  final ValueChanged<String>? onMode;
  final String view;
  final ValueChanged<String> onView;
  final bool straps;
  final ValueChanged<bool> onStraps;
  final bool vectors;
  final ValueChanged<bool> onVectors;
  final Widget? edit;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final plan = this.plan;
    final norms = (plan?['norms'] as List<dynamic>? ?? const []).cast<Map<String, dynamic>>();
    final allOk = norms.isNotEmpty && norms.every((n) => n['ok'] == true) && plan?['fits'] == true;
    Widget pills(List<String> values, String selected, String Function(String) label, ValueChanged<String>? on,
            {Map<String, IconData> icons = const {}}) =>
        Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
          for (final v in values)
            ChoiceChip(
              key: ValueKey('sim-$v'),
              avatar: icons[v] == null ? null : Icon(icons[v], size: 16),
              label: Text(label(v)),
              selected: v == selected,
              showCheckmark: false,
              onSelected: on == null ? null : (_) => on(v),
            ),
        ]);
    return SectionCard(
      title: t.simTitle,
      icon: Icons.view_in_ar_outlined,
      action: plan == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(right: Gap.s),
              child: StatusChip(
                label: allOk ? t.normsAllOk : t.normsSomeFail,
                tone: allOk ? StatusTone.ok : StatusTone.warning,
                uppercase: false,
              ),
            ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        pills(['standard', 'stacked', 'bulk'], mode, t.mode, onMode,
            icons: {
              'standard': Icons.view_module_outlined,
              'stacked': Icons.layers_outlined,
              'bulk': Icons.inventory_2_outlined,
            }),
        const SizedBox(height: Gap.s),
        pills(['iso', 'top', 'section', if (edit != null) 'edit'], view, t.view, onView,
            icons: {
              'iso': Icons.view_in_ar_outlined,
              'top': Icons.grid_view,
              'section': Icons.vertical_split_outlined,
              'edit': Icons.open_with,
            }),
        const SizedBox(height: Gap.m),
        if (plan == null)
          Container(
            height: 220,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(Gap.l),
            decoration: BoxDecoration(
              color: TruckColors.of(context).surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Text(t.simHint, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          )
        else if (view == 'edit' && edit != null)
          edit!
        else
          _Drawing(
            plan: plan,
            kinds: kinds,
            view: SimView.values.byName(view == 'edit' ? 'iso' : view),
            straps: straps,
            vectors: vectors,
            onStraps: onStraps,
            onVectors: onVectors,
            highlight: highlight,
          ),
        if (plan != null) ...[
          const SizedBox(height: Gap.m),
          SimLegend(plan: plan, kinds: kinds),
        ],
      ]),
    );
  }
}

class _Drawing extends StatelessWidget {
  const _Drawing({
    required this.plan,
    required this.kinds,
    required this.view,
    required this.straps,
    required this.vectors,
    required this.onStraps,
    required this.onVectors,
    this.highlight,
  });

  final String? highlight;
  final Map<String, dynamic> plan;
  final List<CargoLook> kinds;
  final SimView view;
  final bool straps;
  final bool vectors;
  final ValueChanged<bool> onStraps;
  final ValueChanged<bool> onVectors;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scene = SimScene(plan, kinds);
    final cogOk = cogBalanced(plan);
    Widget toggle(String label, bool value, ValueChanged<bool> on) => InkWell(
          onTap: () => on(!value),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Checkbox(value: value, onChanged: (v) => on(v ?? false), visualDensity: VisualDensity.compact),
            Text(label, style: theme.textTheme.labelMedium),
            const SizedBox(width: Gap.s),
          ]),
        );
    final background =
        dark ? const Color(0xFF0F172A) : (view == SimView.top ? const Color(0xFFEFF4FB) : const Color(0xFFF1F5F9));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(children: [
        toggle(t.overlayStraps((plan['straps'] as int?) ?? 0), straps, onStraps),
        toggle(t.overlayVectors, vectors, onVectors),
      ]),
      const SizedBox(height: Gap.xs),
      ClipRRect(
        borderRadius: BorderRadius.circular(TruckTheme.radius),
        child: Container(
          color: background,
          child: AspectRatio(
            aspectRatio: view == SimView.top ? 2.6 : (view == SimView.section ? 2.4 : 1.9),
            child: CustomPaint(
              key: ValueKey('sim-view-${view.name}'),
              painter: SimPainter(
                  scene: scene,
                  view: view,
                  straps: straps,
                  vectors: vectors,
                  texts: t,
                  dark: dark,
                  highlight: highlight),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
      const SizedBox(height: Gap.s),
      Wrap(spacing: Gap.s, runSpacing: Gap.xs, children: [
        StatusChip(
          label: t.view(view.name),
          tone: StatusTone.info,
          icon: Icons.view_in_ar_outlined,
          uppercase: false,
        ),
        if (scene.cog != null)
          StatusChip(
            label: cogOk ? t.cogBalanced : t.cogCheck,
            tone: cogOk ? StatusTone.ok : StatusTone.warning,
            icon: Icons.adjust,
            uppercase: false,
          ),
      ]),
    ]);
  }
}

/// Zastrzeżenie: plan jest pomocniczy, odpowiedzialność ponoszą kierowca i załadowca.
class LoadDisclaimer extends StatelessWidget {
  const LoadDisclaimer({super.key});

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme.bodySmall?.copyWith(color: scheme.secondary);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          IconSquare(icon: Icons.gavel, color: scheme.onErrorContainer, background: scheme.errorContainer),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SectionLabel(t.disclaimerFull, color: scheme.onSurface),
              const SizedBox(height: Gap.xs),
              Text(t.disclaimer, style: text),
              const SizedBox(height: Gap.xs),
              Text(t.disclaimerLong, style: text),
              const SizedBox(height: Gap.s),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(Gap.m),
                decoration: BoxDecoration(
                  color: TruckColors.of(context).surfaceLow,
                  borderRadius: BorderRadius.circular(TruckTheme.radius),
                ),
                child: Text(t.disclaimerLaw, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}
