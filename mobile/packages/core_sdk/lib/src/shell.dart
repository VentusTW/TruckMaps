import 'package:flutter/material.dart';

import 'theme.dart';

/// Pozycja menu bocznego albo dolnej nawigacji.
class ShellItem {
  const ShellItem(this.id, this.label, this.icon, {this.badge = 0, this.enabled = true});

  final String id;
  final String label;
  final IconData icon;

  /// Liczba nowych (np. nieprzeczytane wiadomości).
  final int badge;

  /// Wyłączona – widać ją, ale nie da się jej wybrać (funkcja niedostępna albo jeszcze nie gotowa).
  final bool enabled;
}

/// Układ ekranu głównego. Komputer (szeroko): białe menu boczne 288 px i górny pasek z tytułem i akcjami.
/// Telefon: górny pasek, menu wysuwane i opcjonalna dolna nawigacja (np. dla kierowcy).
class TruckShell extends StatelessWidget {
  const TruckShell({
    super.key,
    required this.title,
    required this.items,
    required this.selected,
    required this.onSelect,
    required this.body,
    this.brand = 'TruckMaps',
    this.subtitle,
    this.actions = const [],
    this.footer = const [],
    this.bottomItems,
    this.wideFrom = 720,
  });

  final String title;
  final List<ShellItem> items;

  /// Identyfikator wybranej pozycji (`null` – żadna).
  final String? selected;
  final ValueChanged<String> onSelect;
  final Widget body;

  /// Nazwa w nagłówku menu i pod nią np. użytkownik.
  final String brand;
  final String? subtitle;

  /// Przyciski w górnym pasku.
  final List<Widget> actions;

  /// Pod pozycjami menu (np. wylogowanie, objaśnienie).
  final List<Widget> footer;

  /// Dolna nawigacja na telefonie; `null` – bez niej.
  final List<ShellItem>? bottomItems;

  /// Od tej szerokości – układ komputerowy.
  final double wideFrom;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= wideFrom;
    final menu = _SideMenu(
      brand: brand,
      subtitle: subtitle,
      items: items,
      selected: selected,
      footer: footer,
      onSelect: (id) {
        if (!wide) Scaffold.maybeOf(context)?.closeDrawer();
        onSelect(id);
      },
    );
    if (wide) {
      final colors = TruckColors.of(context);
      return Scaffold(
        body: Row(children: [
          Material(
            color: colors.card,
            elevation: 1,
            shadowColor: Colors.black26,
            child: SizedBox(width: TruckTheme.sideMenuWidth, child: menu),
          ),
          Expanded(
            child: Column(children: [
              _TopBar(title: title, actions: actions),
              Expanded(child: body),
            ]),
          ),
        ]),
      );
    }
    final bottom = bottomItems;
    return Scaffold(
      appBar: AppBar(title: Text(title), actions: actions),
      drawer: Drawer(child: SafeArea(child: menu)),
      body: body,
      bottomNavigationBar: bottom == null ? null : _BottomNav(items: bottom, selected: selected, onSelect: onSelect),
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({required this.title, required this.actions});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: TruckColors.of(context).card,
      child: SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
          child: Row(children: [
            Expanded(
              child: Text(title, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            ...actions,
          ]),
        ),
      ),
    );
  }
}

class _SideMenu extends StatelessWidget {
  const _SideMenu({
    required this.brand,
    required this.subtitle,
    required this.items,
    required this.selected,
    required this.footer,
    required this.onSelect,
  });

  final String brand;
  final String? subtitle;
  final List<ShellItem> items;
  final String? selected;
  final List<Widget> footer;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListView(padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: Gap.l), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.m, 0, Gap.m, Gap.l),
        child: Row(children: [
          Icon(Icons.local_shipping, color: scheme.primary, size: 28),
          const SizedBox(width: Gap.s),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(brand,
                  style: theme.textTheme.titleLarge?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.secondary)),
            ]),
          ),
        ]),
      ),
      for (final item in items)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: _MenuTile(item: item, selected: item.id == selected, onTap: () => onSelect(item.id)),
        ),
      if (footer.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.symmetric(vertical: Gap.s), child: Divider()),
        ...footer,
      ],
    ]);
  }
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({required this.item, required this.selected, required this.onTap});

  final ShellItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final tile = Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        onTap: item.enabled ? onTap : null,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m),
            child: Row(children: [
              Badge(
                isLabelVisible: item.badge > 0,
                label: Text('${item.badge}'),
                child: Icon(item.icon, size: 22, color: fg),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(color: selected ? fg : scheme.onSurface)),
              ),
            ]),
          ),
        ),
      ),
    );
    return item.enabled ? tile : Opacity(opacity: 0.38, child: tile);
  }
}

/// Dolna nawigacja telefonu: wybrana – w kolorze marki, wyłączone – przygaszone.
class _BottomNav extends StatelessWidget {
  const _BottomNav({required this.items, required this.selected, required this.onSelect});

  final List<ShellItem> items;
  final String? selected;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: TruckColors.of(context).card,
      elevation: 3,
      shadowColor: Colors.black26,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 64,
          child: Row(children: [
            for (final item in items)
              Expanded(
                child: Opacity(
                  opacity: item.enabled ? 1 : 0.38,
                  child: InkWell(
                    key: Key('bottom-${item.id}'),
                    onTap: item.enabled ? () => onSelect(item.id) : null,
                    child: Builder(builder: (context) {
                      final color = item.id == selected ? scheme.primary : scheme.onSurfaceVariant;
                      return Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Badge(
                          isLabelVisible: item.badge > 0,
                          label: Text('${item.badge}'),
                          child: Icon(item.icon, color: color),
                        ),
                        const SizedBox(height: 2),
                        Text(item.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelMedium?.copyWith(color: color)),
                      ]);
                    }),
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
