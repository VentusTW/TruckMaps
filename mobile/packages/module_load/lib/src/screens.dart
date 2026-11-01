import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'texts.dart';

const _base = '/api/m/load';

/// Rodzaje z przestrzenią ładunkową (jak na serwerze – zabudowa).
const cargoKinds = {'combination', 'rigid', 'van', 'semitrailer', 'trailer'};
const itemKinds = ['euro', 'industrial', 'half', 'custom'];

double? _parse(String text) => double.tryParse(text.trim().replaceAll(',', '.'));

InputDecoration _field(String label, {String? suffix}) =>
    InputDecoration(labelText: label, suffixText: suffix, border: const OutlineInputBorder(), isDense: true);

/// Pozycja ładunku w formularzu.
class _Item {
  String kind = 'euro';
  final count = TextEditingController(text: '1');
  final weight = TextEditingController();
  final stack = TextEditingController(text: '1');
  final stop = TextEditingController(text: '1');
  final length = TextEditingController();
  final width = TextEditingController();

  List<TextEditingController> get all => [count, weight, stack, stop, length, width];

  Map<String, dynamic> json() => {
        'kind': kind,
        'count': _parse(count.text)?.round() ?? 1,
        'weight_kg': _parse(weight.text),
        'stack': _parse(stack.text)?.round() ?? 1,
        'stop': _parse(stop.text)?.round() ?? 1,
        if (kind == 'custom') 'length_m': _parse(length.text),
        if (kind == 'custom') 'width_m': _parse(width.text),
      };
}

/// Plan załadunku: pojazd, pozycje ładunku → LDM, masa, rozmieszczenie z góry, pasy, ostrzeżenia.
class LoadPlanScreen extends StatefulWidget {
  const LoadPlanScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<LoadPlanScreen> createState() => _LoadPlanScreenState();
}

class _LoadPlanScreenState extends State<LoadPlanScreen> {
  late final Future<dynamic> _vehicles = widget.api.get('/api/vehicles');
  final _form = GlobalKey<FormState>();
  final _items = [_Item()];
  final _deck = TextEditingController();
  String? _vehicleId;
  bool _frontWall = true;
  bool _mats = false;
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _plan;

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
      final plan = await widget.api.post('$_base/plan', {
        'vehicle_id': _vehicleId,
        'items': [for (final i in _items) i.json()],
        if (_parse(_deck.text) != null) 'deck_length_m': _parse(_deck.text),
        'front_wall': _frontWall,
        'mats': _mats,
      });
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
        return Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
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
            const SizedBox(height: 12),
            TextFormField(
              controller: _deck,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: numbers,
              decoration: _field(t.deckLength, suffix: 'm'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: Text(t.items, style: Theme.of(context).textTheme.titleSmall)),
              TextButton.icon(
                onPressed: () => setState(() => _items.add(_Item())),
                icon: const Icon(Icons.add),
                label: Text(t.addItem),
              ),
            ]),
            for (final (index, item) in _items.indexed)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(children: [
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          value: item.kind,
                          decoration: _field(t.items),
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
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      for (final (controller, label, suffix, check) in [
                        (item.count, t.count, null, true),
                        (item.weight, t.weight, 'kg', true),
                        (item.stack, t.stack, null, true),
                        (item.stop, t.stop, null, true),
                        if (item.kind == 'custom') (item.length, t.length, 'm', true),
                        if (item.kind == 'custom') (item.width, t.width, 'm', true),
                      ])
                        SizedBox(
                          width: 150,
                          child: TextFormField(
                            controller: controller,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            inputFormatters: numbers,
                            decoration: _field(label, suffix: suffix),
                            validator: check ? required : null,
                          ),
                        ),
                    ]),
                  ]),
                ),
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
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            FilledButton.icon(
              onPressed: _busy ? null : _calculate,
              icon: const Icon(Icons.calculate_outlined),
              label: Text(t.calculate),
            ),
            if (_plan case final plan?) ...[const SizedBox(height: 16), PlanResult(plan: plan)],
          ]),
        );
      },
    );
  }
}

/// Wynik planu: podsumowanie, ostrzeżenia i widok z góry (przód – po lewej).
class PlanResult extends StatelessWidget {
  const PlanResult({super.key, required this.plan});

  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final t = LoadTexts.of(context);
    final theme = Theme.of(context);
    final fits = plan['fits'] == true;
    final payload = plan['payload_kg'] as num?;
    final cog = plan['cog_m'] as num?;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Icon(fits ? Icons.check_circle_outline : Icons.error_outline,
            color: fits ? theme.colorScheme.primary : theme.colorScheme.error),
        const SizedBox(width: 8),
        Text(fits ? t.fits : t.notFits, style: theme.textTheme.titleMedium),
      ]),
      const SizedBox(height: 4),
      Text(t.summary(t.number(plan['ldm'] as num), t.number(plan['used_length_m'] as num),
          t.number(plan['deck_length_m'] as num))),
      Text(t.weightLine(t.number(plan['weight_kg'] as num), payload == null ? null : t.number(payload))),
      Text(t.strapsLine(plan['straps'] as int)),
      if (cog != null) Text(t.cog(t.number(cog))),
      for (final warning in (plan['warnings'] as List<dynamic>? ?? const []))
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('⚠ $warning', style: TextStyle(color: theme.colorScheme.error)),
        ),
      const SizedBox(height: 12),
      Text(t.front, style: theme.textTheme.bodySmall),
      AspectRatio(
        aspectRatio: (plan['deck_length_m'] as num) / (plan['deck_width_m'] as num),
        child: CustomPaint(painter: DeckPainter(plan, theme.colorScheme)),
      ),
      const SizedBox(height: 8),
      Text(t.disclaimer, style: theme.textTheme.bodySmall),
    ]);
  }
}

/// Przestrzeń ładunkowa z góry: palety w kolorach rozładunków, numer rozładunku na palecie.
class DeckPainter extends CustomPainter {
  DeckPainter(this.plan, this.colors);

  final Map<String, dynamic> plan;
  final ColorScheme colors;

  static const _stops = [Colors.blue, Colors.orange, Colors.green, Colors.purple, Colors.teal, Colors.brown];

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / (plan['deck_length_m'] as num);
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.surfaceVariant);
    canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = colors.outline);
    for (final p in (plan['placed'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final rect = Rect.fromLTWH((p['x_m'] as num) * scale, (p['y_m'] as num) * scale,
              (p['length_m'] as num) * scale, (p['width_m'] as num) * scale)
          .deflate(1);
      final stop = p['stop'] as int;
      canvas.drawRect(rect, Paint()..color = _stops[(stop - 1) % _stops.length].withOpacity(0.7));
      final label = TextPainter(
        text: TextSpan(text: '$stop', style: TextStyle(color: colors.onPrimary, fontSize: 10)),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, rect.center - Offset(label.width / 2, label.height / 2));
    }
  }

  @override
  bool shouldRepaint(DeckPainter oldDelegate) => oldDelegate.plan != plan;
}
