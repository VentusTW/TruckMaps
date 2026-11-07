import 'package:flutter/material.dart';

import 'theme.dart';

/// Pozycja w oknie wyboru.
class PickerOption<T> {
  const PickerOption(this.value, this.label, {this.subtitle, this.icon, this.trailing});

  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;

  /// Np. przycisk usunięcia własnej pozycji.
  final Widget? trailing;
}

/// Grupa pozycji (nagłówek w liście i filtr).
class PickerGroup<T> {
  const PickerGroup(this.title, this.options, {this.icon});

  final String title;
  final List<PickerOption<T>> options;
  final IconData? icon;
}

/// Teksty okna wyboru (z tłumaczeń pakietu, który je otwiera).
class PickerTexts {
  const PickerTexts({required this.title, required this.search, required this.empty, required this.all});

  final String title;
  final String search;
  final String empty;
  final String all;
}

/// Okno wyboru z grupami, filtrem grup i wyszukiwarką (nazwa, opis, grupa). Zwraca wybraną
/// wartość albo `null` (zamknięte). [actions] – przyciski pod listą, np. „Dodaj własny”.
Future<T?> showGroupedPicker<T>(
  BuildContext context, {
  required PickerTexts texts,
  required List<PickerGroup<T>> groups,
  T? selected,
  List<Widget> Function(BuildContext dialog)? actions,
}) =>
    showDialog<T>(
      context: context,
      builder: (dialog) => _PickerDialog<T>(texts: texts, groups: groups, selected: selected, actions: actions),
    );

class _PickerDialog<T> extends StatefulWidget {
  const _PickerDialog({required this.texts, required this.groups, this.selected, this.actions});

  final PickerTexts texts;
  final List<PickerGroup<T>> groups;
  final T? selected;
  final List<Widget> Function(BuildContext dialog)? actions;

  @override
  State<_PickerDialog<T>> createState() => _PickerDialogState<T>();
}

class _PickerDialogState<T> extends State<_PickerDialog<T>> {
  String _query = '';
  int? _group;

  bool _matches(PickerGroup<T> group, PickerOption<T> option) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return [option.label, option.subtitle ?? '', group.title].any((s) => s.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final size = MediaQuery.sizeOf(context);
    final visible = [
      for (final (i, g) in widget.groups.indexed)
        if (_group == null || _group == i)
          (
            g,
            [
              for (final o in g.options)
                if (_matches(g, o)) o
            ]
          ),
    ].where((e) => e.$2.isNotEmpty).toList();
    return Dialog(
      insetPadding: const EdgeInsets.all(Gap.l),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 680, maxHeight: size.height * 0.85),
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(child: Text(widget.texts.title, style: theme.textTheme.titleLarge)),
              IconButton(onPressed: () => Navigator.of(context).pop(), icon: const Icon(Icons.close)),
            ]),
            const SizedBox(height: Gap.s),
            TextField(
              key: const Key('picker-search'),
              autofocus: true,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: widget.texts.search,
                isDense: true,
              ),
              onChanged: (q) => setState(() => _query = q),
            ),
            const SizedBox(height: Gap.s),
            // Wszystkie grupy widoczne naraz – zawijane do kolejnych wierszy (bez przewijania w bok,
            // przy którym ostatnie były ucięte). Przy bardzo wielu grupach – przewijany obszar.
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: size.height * 0.22),
              child: SingleChildScrollView(
                child: Wrap(spacing: Gap.xs, runSpacing: Gap.xs, children: [
                  for (final (i, label) in [
                    (null, widget.texts.all),
                    for (final (i, g) in widget.groups.indexed) (i, '${g.title} (${g.options.length})')
                  ])
                    ChoiceChip(
                      key: ValueKey('picker-group-$i'),
                      label: Text(label),
                      selected: _group == i,
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _group = i),
                    ),
                ]),
              ),
            ),
            const SizedBox(height: Gap.s),
            Flexible(
              child: visible.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(Gap.xl),
                      child: Text(widget.texts.empty, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                    )
                  : ListView(shrinkWrap: true, children: [
                      for (final (group, options) in visible) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(Gap.xs, Gap.m, Gap.xs, Gap.xs),
                          child: Row(children: [
                            if (group.icon != null) ...[
                              Icon(group.icon, size: 18, color: scheme.primary),
                              const SizedBox(width: Gap.s),
                            ],
                            Expanded(
                              child: Text(group.title.toUpperCase(),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                      letterSpacing: 0.6, color: scheme.primary, fontWeight: FontWeight.w700)),
                            ),
                            Text('${options.length}', style: theme.textTheme.labelSmall),
                          ]),
                        ),
                        for (final o in options)
                          ListTile(
                            key: ValueKey('picker-${o.value}'),
                            dense: true,
                            selected: o.value == widget.selected,
                            leading: o.icon == null ? null : Icon(o.icon, size: 20),
                            title: Text(o.label),
                            subtitle: o.subtitle == null ? null : Text(o.subtitle!),
                            trailing: o.trailing ??
                                (o.value == widget.selected ? Icon(Icons.check, color: scheme.primary) : null),
                            onTap: () => Navigator.of(context).pop(o.value),
                          ),
                      ],
                    ]),
            ),
            if (widget.actions != null) ...[
              const Divider(height: Gap.l),
              Wrap(alignment: WrapAlignment.end, spacing: Gap.s, children: widget.actions!(context)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Pole formularza otwierające [showGroupedPicker]: etykieta i nazwa wybranej pozycji.
class PickerField extends StatelessWidget {
  const PickerField({
    super.key,
    required this.label,
    required this.value,
    required this.onTap,
    this.icon,
    this.dense = true,
  });

  final String label;
  final String value;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool dense;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            isDense: dense,
            prefixIcon: icon == null ? null : Icon(icon, size: 20),
            suffixIcon: const Icon(Icons.unfold_more),
          ),
          child: Text(value, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      );
}
