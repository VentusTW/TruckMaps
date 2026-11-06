import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Pozycja menu, której ekran jest jeszcze w przygotowaniu.
class UnderConstructionScreen extends StatelessWidget {
  const UnderConstructionScreen({super.key, required this.title, required this.icon, this.onBack});

  final String title;
  final IconData icon;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(Gap.xxl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              IconSquare(icon: icon, size: 56),
              const SizedBox(height: Gap.l),
              Text(title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: Gap.s),
              StatusChip(label: l.underConstruction, tone: StatusTone.neutral, icon: Icons.construction_outlined),
              const SizedBox(height: Gap.m),
              Text(l.underConstructionText,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              if (onBack != null) ...[
                const SizedBox(height: Gap.l),
                OutlinedButton.icon(
                    onPressed: onBack, icon: const Icon(Icons.grid_view_outlined, size: 18), label: Text(l.menuMain)),
              ],
            ]),
          ),
        ),
      ),
    );
  }
}
