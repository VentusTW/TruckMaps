import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'deck_view.dart';
import 'texts.dart';

const _base = '/api/m/load';

/// Rodzaje z przestrzenią ładunkową (jak na serwerze – zabudowa).
const cargoKinds = {'combination', 'rigid', 'van', 'semitrailer', 'trailer'};
const itemKinds = ['euro', 'industrial', 'half', 'custom'];

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

/// Plan załadunku: pojazd, pozycje ładunku → LDM, masa, rozmieszczenie z góry, pasy, ostrzeżenia.
class LoadPlanScreen extends StatefulWidget {
  const LoadPlanScreen({super.key, required this.api, this.vehicleId});

  final CoreApi api;

  /// Pojazd wybrany z góry (np. z karty pojazdu).
  final String? vehicleId;

  @override
  State<LoadPlanScreen> createState() => _LoadPlanScreenState();
}

class _LoadPlanScreenState extends State<LoadPlanScreen> {
  late final Future<dynamic> _vehicles = widget.api.get('/api/vehicles');
  final _form = GlobalKey<FormState>();
  final _items = [_Item()];
  final _deck = TextEditingController();
  late String? _vehicleId = widget.vehicleId;
  bool _frontWall = true;
  bool _mats = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _plan;
  bool _checking = false;

  Map<String, dynamic> _body() => {
        'vehicle_id': _vehicleId,
        'items': [for (final i in _items) i.json()],
        if (_parse(_deck.text) != null) 'deck_length_m': _parse(_deck.text),
        'front_wall': _frontWall,
        'mats': _mats,
      };

  /// Ręczne ułożenie (przeciągnięte palety): serwer liczy naciski i ostrzeżenia od nowa.
  Future<void> _check(List<Map<String, dynamic>> placed) async {
    setState(() => _checking = true);
    try {
      final plan = await widget.api.post('$_base/plan/check', {..._body(), 'placed': placed});
      if (mounted) setState(() => _plan = plan as Map<String, dynamic>);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  void dispose() {
    for (final c in [_deck, for (final i in _items) ...i.all]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _calculate() async {
    if (!_form.currentState!.validate() || _vehicleId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await widget.api.post('$_base/plan', _body());
      if (mounted) setState(() => _plan = plan as Map<String, dynamic>);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final numbers = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))];
    String? required(String? text) => _parse(text ?? '') == null ? t.numberInvalid : null;
    return FutureBuilder<dynamic>(
      future: _vehicles,
      builder: (context, snapshot) {
        if (snapshot.hasError) return Center(child: Text('${snapshot.error}'));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final vehicles = [
          for (final v in (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>())
            if (cargoKinds.contains(v['kind'])) v,
        ];
        if (vehicles.isEmpty) return Center(child: Text(t.noVehicles));
        _vehicleId ??= '${vehicles.first['id']}';
        final theme = Theme.of(context);
        final fill = TruckColors.of(context).card;
        final form = SectionCard(
          title: t.items,
          icon: Icons.inventory_2_outlined,
          action: TextButton.icon(
            onPressed: () => setState(() => _items.add(_Item())),
            icon: const Icon(Icons.add),
            label: Text(t.addItem),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
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
              onChanged: (id) => setState(() => _vehicleId = id),
            ),
            const SizedBox(height: Gap.m),
            TextFormField(
              controller: _deck,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: numbers,
              decoration: _field(t.deckLength, suffix: 'm'),
            ),
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
                        onChanged: (k) => setState(() => item.kind = k ?? 'euro'),
                      ),
                    ),
                    if (_items.length > 1)
                      IconButton(
                        onPressed: () => setState(() => _items.removeAt(index).all.forEach((c) => c.dispose())),
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
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _frontWall,
              onChanged: (on) => setState(() => _frontWall = on),
              title: Text(t.frontWall),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _mats,
              onChanged: (on) => setState(() => _mats = on),
              title: Text(t.mats),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.m),
                child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _calculate,
              icon: const Icon(Icons.calculate_outlined),
              label: Text(t.calculate),
            ),
          ]),
        );
        final plan = _plan;
        return Form(
          key: _form,
          child: LayoutBuilder(builder: (context, size) {
            final wide = size.maxWidth >= 1000;
            final pad = wide ? Gap.xl : Gap.l;
            final deck =
                plan == null ? null : PlanDeck(plan: plan, onMoved: _check, onRearrange: _busy ? null : _calculate);
            final side = plan == null
                ? <Widget>[
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(Gap.l),
                        child: Text(t.resultHint, style: theme.textTheme.bodyMedium),
                      ),
                    ),
                  ]
                : PlanResult.panels(plan, mats: _mats, frontWall: _frontWall, checking: _checking);
            final soon = SectionCard(
              title: t.soonTitle,
              icon: Icons.construction,
              child: Column(children: [
                for (final (title, icon) in [
                  (t.soon3d, Icons.view_in_ar_outlined),
                  (t.soonForces, Icons.functions),
                  (t.soonEquipment, Icons.inventory_outlined),
                  (t.soonPdf, Icons.picture_as_pdf_outlined),
                  (t.soonApprove, Icons.check_circle_outline),
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: IconSquare(icon: icon, size: 32),
                    title: Text(title),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openUnderConstruction(context, title, icon: icon),
                  ),
              ]),
            );
            Widget column(List<Widget> children) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, c) in children.indexed) ...[if (i > 0) const SizedBox(height: Gap.l), c],
                  ],
                );
            // Komputer: formularz i rozmieszczenie po lewej (8/12), wynik po prawej (4/12) – jak w projekcie.
            if (wide) {
              return ListView(padding: EdgeInsets.all(pad), children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(flex: 8, child: column([form, if (deck != null) deck])),
                  const SizedBox(width: Gap.xl),
                  Expanded(flex: 4, child: column([...side, soon])),
                ]),
                const SizedBox(height: Gap.l),
                const LoadDisclaimer(),
              ]);
            }
            return ListView(padding: EdgeInsets.all(pad), children: [
              column([form, if (plan != null) ...side, if (deck != null) deck, soon, const LoadDisclaimer()]),
            ]);
          }),
        );
      },
    );
  }
}

/// Wynik planu w kartach: stan załadunku, naciski na osie, mocowanie, ostrzeżenia.
abstract final class PlanResult {
  static List<Widget> panels(Map<String, dynamic> plan,
          {required bool mats, required bool frontWall, bool checking = false}) =>
      [
        _PlanStatus(plan: plan, checking: checking),
        if ((plan['axles'] as List<dynamic>? ?? const []).isNotEmpty) _AxleLoads(plan: plan),
        _Securing(plan: plan, mats: mats, frontWall: frontWall),
        if ((plan['warnings'] as List<dynamic>? ?? const []).isNotEmpty) _Warnings(plan: plan),
      ];
}

double _ratio(num? value, num? limit) => value == null || limit == null || limit <= 0 ? 0 : value / limit;

class _PlanStatus extends StatelessWidget {
  const _PlanStatus({required this.plan, required this.checking});

  final Map<String, dynamic> plan;
  final bool checking;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final fits = plan['fits'] == true;
    final used = plan['used_length_m'] as num;
    final deck = plan['deck_length_m'] as num;
    final weight = plan['weight_kg'] as num;
    final payload = plan['payload_kg'] as num?;
    final caption = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(Gap.l),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            StatusChip(
              label: fits ? t.fits : t.notFits,
              tone: fits ? StatusTone.ok : StatusTone.error,
              icon: fits ? Icons.check_circle_outline : Icons.error_outline,
              uppercase: false,
            ),
            const Spacer(),
            if (checking) const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          ]),
          const SizedBox(height: Gap.m),
          SectionLabel(t.loadStatus),
          const SizedBox(height: Gap.xs),
          BigNumber(value: t.number(plan['ldm'] as num), unit: 'LDM', size: 24),
          Text(t.summary(t.number(plan['ldm'] as num), t.number(used), t.number(deck)), style: caption),
          const SizedBox(height: Gap.s),
          TruckProgressBar(value: _ratio(used, deck), color: fits ? null : theme.colorScheme.error),
          const SizedBox(height: Gap.l),
          SectionLabel(t.cargoWeight),
          const SizedBox(height: Gap.xs),
          BigNumber(
            value: t.tonnes(weight.toDouble()),
            unit: payload == null ? null : '/ ${t.tonnes(payload.toDouble())}',
            size: 24,
          ),
          Text(t.weightLine(t.number(weight), payload == null ? null : t.number(payload)), style: caption),
          if (payload != null) ...[
            const SizedBox(height: Gap.s),
            TruckProgressBar(value: _ratio(weight, payload), color: weight > payload ? theme.colorScheme.error : null),
          ],
        ]),
      ),
    );
  }
}

class _AxleLoads extends StatelessWidget {
  const _AxleLoads({required this.plan});

  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final axles = (plan['axles'] as List<dynamic>).cast<Map<String, dynamic>>();
    final over = axles.any((a) => a['over'] == true);
    return SectionCard(
      title: t.axleTitle,
      icon: Icons.balance,
      action: Padding(
        padding: const EdgeInsets.only(right: Gap.s),
        child: StatusChip(label: over ? t.axleOver : t.axleOk, tone: over ? StatusTone.error : StatusTone.ok),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final axle in axles)
          Builder(builder: (context) {
            final load = axle['load_kg'] as num;
            final limit = axle['limit_kg'] as num?;
            final ratio = _ratio(load, limit);
            final isOver = axle['over'] == true;
            final color =
                isOver ? scheme.error : (ratio >= 0.9 ? TruckColors.of(context).warning : scheme.primaryContainer);
            return Padding(
              padding: const EdgeInsets.only(bottom: Gap.m),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(
                  t.axleLine(t.axle(axle['name'] as String), t.tonnes(load.toDouble()),
                      limit == null ? null : t.tonnes(limit.toDouble())),
                  style: theme.textTheme.labelMedium?.copyWith(color: isOver ? scheme.error : scheme.onSurface),
                ),
                if (limit != null) ...[
                  const SizedBox(height: Gap.xs),
                  TruckProgressBar(value: ratio, height: 10, color: color),
                ],
              ]),
            );
          }),
        if (plan['cog_m'] case final num cog)
          Container(
            padding: const EdgeInsets.all(Gap.m),
            decoration: BoxDecoration(
              color: TruckColors.of(context).surfaceLow,
              borderRadius: BorderRadius.circular(TruckTheme.radius),
            ),
            child: Text(t.cog(t.number(cog)), style: theme.textTheme.labelLarge),
          ),
      ]),
    );
  }
}

class _Securing extends StatelessWidget {
  const _Securing({required this.plan, required this.mats, required this.frontWall});

  final Map<String, dynamic> plan;
  final bool mats;
  final bool frontWall;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: Gap.xs),
          child: Row(children: [
            Expanded(
              child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.secondary)),
            ),
            Text(value, style: theme.textTheme.labelLarge),
          ]),
        );
    return SectionCard(
      title: t.securingTitle,
      icon: Icons.link,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(t.strapsLine(plan['straps'] as int), style: theme.textTheme.bodyMedium),
        const Divider(height: Gap.l),
        row(t.mats, mats ? t.yes : t.no),
        row(t.frontWall, frontWall ? t.yes : t.no),
      ]),
    );
  }
}

class _Warnings extends StatelessWidget {
  const _Warnings({required this.plan});

  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(Gap.l),
      decoration: BoxDecoration(color: scheme.errorContainer, borderRadius: BorderRadius.circular(TruckTheme.radius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final warning in (plan['warnings'] as List<dynamic>))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text('⚠ $warning', style: TextStyle(color: scheme.onErrorContainer)),
          ),
      ]),
    );
  }
}

/// Rozmieszczenie: widoki z góry i z boku (przód – po lewej) z przybliżaniem, przesuwaniem obrazu
/// i przeciąganiem palet; „Ułóż automatycznie” – plan od nowa bez przekroczeń.
class PlanDeck extends StatefulWidget {
  const PlanDeck({super.key, required this.plan, this.onMoved, this.onRearrange});

  final Map<String, dynamic> plan;

  /// Palety przeciągnięte – nowe ułożenie do sprawdzenia; `null` – bez przeciągania.
  final ValueChanged<List<Map<String, dynamic>>>? onMoved;
  final VoidCallback? onRearrange;

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
    return SectionCard(
      title: t.layoutTitle,
      icon: Icons.view_in_ar_outlined,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
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
      ]),
    );
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
              SectionLabel(t.disclaimerTitle, color: scheme.onSurface),
              const SizedBox(height: Gap.xs),
              Text(t.disclaimer, style: text),
              Text(t.disclaimerLaw, style: text),
            ]),
          ),
        ]),
      ),
    );
  }
}
