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
  bool _approved = false;

  Map<String, dynamic> _body() => {
        'vehicle_id': _vehicleId,
        'items': [for (final i in _items) i.json()],
        if (_parse(_deck.text) != null) 'deck_length_m': _parse(_deck.text),
        'front_wall': _frontWall,
        'mats': _mats,
        'body_code': _bodyCode,
        'reference': _reference.text.trim(),
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
    return _run(() => widget.api.post('$_base/plan/check', {..._body(), 'placed': placed}), check: true);
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
            if (item.kind == 'custom') item.kind = 'euro';
            item.stack.text = '2';
          default:
            if (item.kind == 'custom') item.kind = 'euro';
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
          kinds: [for (final i in _items) i.kind],
          mode: _mode,
          onMode: _busy ? null : _setMode,
          view: _view,
          onView: (v) => setState(() => _view = v),
          straps: _straps,
          onStraps: (v) => setState(() => _straps = v),
          vectors: _vectors,
          onVectors: (v) => setState(() => _vectors = v),
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
                  child: DropdownButtonFormField<String>(
                    isExpanded: true,
                    value: item.kind,
                    decoration: _field(t.items).copyWith(fillColor: fill),
                    items: [for (final k in itemKinds) DropdownMenuItem(value: k, child: Text(t.kind(k)))],
                    onChanged: (k) => _changed(() => item.kind = k ?? 'euro'),
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
      Text(_moving ? t.moveItemsHint : t.moveViewHint, style: theme.textTheme.bodySmall),
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
  });

  final Map<String, dynamic>? plan;
  final List<String> kinds;
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
  });

  final Map<String, dynamic> plan;
  final List<String> kinds;
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
            child: InteractiveViewer(
              maxScale: 5,
              child: CustomPaint(
                key: ValueKey('sim-view-${view.name}'),
                painter: SimPainter(scene: scene, view: view, straps: straps, vectors: vectors, texts: t, dark: dark),
                child: const SizedBox.expand(),
              ),
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
