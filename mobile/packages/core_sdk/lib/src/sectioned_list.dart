import 'package:flutter/material.dart';

import 'theme.dart';

/// Nagłówek sekcji w [SectionedListView]: zaczyna nową kartę.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(children: [
      Container(
        width: 4,
        height: 20,
        decoration: BoxDecoration(gradient: TruckGradients.brand, borderRadius: BorderRadius.circular(2)),
      ),
      const SizedBox(width: Gap.s),
      Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
    ]);
  }
}

/// Lista z sekcjami: każdy [SectionHeader] (także w wierszu z przyciskiem) zaczyna nową kartę z cieniem,
/// a pozycje do następnego nagłówka trafiają do niej. Zastępuje płaską listę z nagłówkami.
class SectionedListView extends StatelessWidget {
  const SectionedListView({super.key, required this.children, this.padding = const EdgeInsets.all(Gap.l)});

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  static bool _isHeader(Widget w) =>
      w is SectionHeader || (w is Row && w.children.any((c) => c is Expanded && c.child is SectionHeader));

  /// Odstępy i linie na brzegach karty są zbędne – karta ma własne marginesy.
  static bool _isSpacer(Widget w) => (w is SizedBox && w.child == null) || w is Divider;

  @override
  Widget build(BuildContext context) {
    final groups = <List<Widget>>[];
    for (final child in children) {
      if (groups.isEmpty || _isHeader(child)) groups.add([]);
      groups.last.add(child);
    }
    final cards = <Widget>[];
    for (var group in groups) {
      while (group.isNotEmpty && _isSpacer(group.last)) {
        group = group.sublist(0, group.length - 1);
      }
      while (group.isNotEmpty && _isSpacer(group.first)) {
        group = group.sublist(1);
      }
      if (group.isEmpty) continue;
      cards.add(Padding(
        padding: const EdgeInsets.only(bottom: Gap.l),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.l),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, w) in group.indexed) ...[
                w,
                if (i == 0 && _isHeader(w)) const SizedBox(height: Gap.m),
              ],
            ]),
          ),
        ),
      ));
    }
    return ListView(padding: padding, children: cards);
  }
}
