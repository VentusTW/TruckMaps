import 'package:flutter/material.dart';

import 'components.dart';
import 'module.dart' show pick;
import 'theme.dart';

String _t(BuildContext context, String pl, String en) => pick(Localizations.localeOf(context), {'pl': pl, 'en': en});

/// Funkcja zapowiedziana, jeszcze bez ekranu: link prowadzi tutaj.
class UnderConstructionScreen extends StatelessWidget {
  const UnderConstructionScreen({super.key, required this.title, this.icon = Icons.construction});

  /// Nazwa funkcji.
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(Gap.xl),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              IconSquare(icon: icon, size: 72),
              const SizedBox(height: Gap.l),
              StatusChip(
                label: _t(context, 'W budowie', 'Under construction'),
                tone: StatusTone.warning,
                icon: Icons.construction,
              ),
              const SizedBox(height: Gap.m),
              Text(title, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
              const SizedBox(height: Gap.s),
              Text(
                _t(context, 'Ta funkcja jest w przygotowaniu i pojawi się w jednej z kolejnych wersji TruckMaps.',
                    'This feature is being prepared and will arrive in one of the next TruckMaps versions.'),
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.secondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Gap.xl),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back),
                label: Text(_t(context, 'Wróć', 'Back')),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Otwiera ekran „W budowie” dla zapowiedzianej funkcji.
Future<void> openUnderConstruction(BuildContext context, String title, {IconData icon = Icons.construction}) =>
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => UnderConstructionScreen(title: title, icon: icon)));

/// Pozycja zapowiedzianej funkcji: ikona, nazwa, chip „Wkrótce”; kliknięcie – ekran „W budowie”.
class SoonTile extends StatelessWidget {
  const SoonTile({super.key, required this.title, required this.icon, this.subtitle});

  final String title;
  final IconData icon;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => IconListTile(
        icon: icon,
        title: title,
        subtitle: subtitle,
        tone: StatusTone.neutral,
        trailing: StatusChip(label: _t(context, 'Wkrótce', 'Soon'), tone: StatusTone.neutral),
        onTap: () => openUnderConstruction(context, title, icon: icon),
      );
}

/// Przycisk zapowiedzianej funkcji (np. w nagłówku ekranu); kliknięcie – ekran „W budowie”.
class SoonButton extends StatelessWidget {
  const SoonButton({super.key, required this.label, required this.icon});

  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        onPressed: () => openUnderConstruction(context, label, icon: icon),
        icon: Icon(icon, size: 18),
        label: Text(label),
      );
}
