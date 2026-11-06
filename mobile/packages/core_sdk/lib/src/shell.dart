import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// Pozycja menu bocznego albo dolnej nawigacji.
class ShellItem {
  const ShellItem(this.id, this.label, this.icon,
      {this.badge = 0, this.enabled = true, this.group, this.tag, this.tagLive = false, this.sub = false});

  final String id;
  final String label;
  final IconData icon;

  /// Liczba nowych (np. nieprzeczytane wiadomości).
  final int badge;

  /// Wyłączona – widać ją, ale nie da się jej wybrać (funkcja niedostępna albo jeszcze nie gotowa).
  final bool enabled;

  /// Nagłówek grupy w menu (np. „Moduły operacyjne”); nowa grupa zaczyna się, gdy nagłówek się zmienia.
  final String? group;

  /// Krótki znacznik po prawej (np. „3D”, „Wkrótce”).
  final String? tag;

  /// Znacznik stanu na żywo – ciemnozielone tło.
  final bool tagLive;

  /// Podpozycja (wcięta, mniejsza, bez ikony) pod poprzednią pozycją.
  final bool sub;
}

/// Wyszukiwarka górnego paska: podpowiada pozycje menu; skrót Ctrl+K.
class ShellSearch {
  const ShellSearch({required this.hint, this.shortcutLabel = 'Ctrl K'});

  final String hint;
  final String shortcutLabel;
}

/// Układ ekranu głównego. Komputer (szeroko): białe menu boczne 288 px (logo, grupy pozycji,
/// karta stanu na dole) i górny pasek 64 px (wyszukiwarka, kontekst, ikony, konto).
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
    this.version,
    this.search,
    this.leading,
    this.context,
    this.actions = const [],
    this.account,
    this.status,
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

  /// Znacznik wydania obok nazwy (np. „v0.1”).
  final String? version;

  /// Wyszukiwarka w górnym pasku (komputer); `null` – w pasku tytuł ekranu.
  final ShellSearch? search;

  /// Lewy brzeg górnego paska przed wyszukiwarką (np. „Cofnij” i ścieżka ekranu; komputer).
  final Widget? leading;

  /// Element obok wyszukiwarki (np. wybór firmy).
  final Widget? context;

  /// Przyciski w górnym pasku.
  final List<Widget> actions;

  /// Prawy brzeg górnego paska (imię, rola, awatar).
  final Widget? account;

  /// Karta na dole menu (np. stan połączenia i floty).
  final Widget? status;

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
      version: version,
      items: items,
      selected: selected,
      footer: footer,
      status: wide ? status : null,
      onSelect: (id) {
        if (!wide) Scaffold.maybeOf(context)?.closeDrawer();
        onSelect(id);
      },
    );
    if (wide) {
      final colors = TruckColors.of(context);
      return Scaffold(
        body: Row(children: [
          DecoratedBox(
            decoration: BoxDecoration(color: colors.card, boxShadow: TruckTheme.softShadow),
            child: SizedBox(width: TruckTheme.sideMenuWidth, child: menu),
          ),
          Expanded(
            child: Column(children: [
              _TopBar(
                title: title,
                search: search,
                leading: leading,
                items: items,
                onSelect: onSelect,
                context: this.context,
                actions: actions,
                account: account,
              ),
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
  const _TopBar({
    required this.title,
    required this.search,
    required this.leading,
    required this.items,
    required this.onSelect,
    required this.context,
    required this.actions,
    required this.account,
  });

  final String title;
  final ShellSearch? search;
  final Widget? leading;
  final List<ShellItem> items;
  final ValueChanged<String> onSelect;
  final Widget? context;
  final List<Widget> actions;
  final Widget? account;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    final search = this.search;
    return Container(
      height: 64,
      decoration: BoxDecoration(color: colors.card.withOpacity(0.9), boxShadow: TruckTheme.softShadow),
      padding: const EdgeInsets.symmetric(horizontal: Gap.xl),
      child: Row(children: [
        if (leading != null) ...[
          Flexible(flex: 5, child: Align(alignment: Alignment.centerLeft, child: leading)),
          const SizedBox(width: Gap.m),
        ],
        if (search != null)
          // Wyszukiwarka bierze większość wolnego miejsca (najwyżej 400 px), reszta – odstęp do ikon.
          Flexible(
            flex: 6,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: _MenuSearch(search: search, items: items, onSelect: onSelect),
            ),
          )
        else
          Expanded(child: Text(title, style: theme.textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
        if (this.context != null) ...[const SizedBox(width: Gap.l), this.context!],
        if (search != null) const Spacer(flex: 1),
        ...actions,
        if (account != null) ...[
          Container(
            width: 1,
            height: 32,
            margin: const EdgeInsets.symmetric(horizontal: Gap.m),
            color: theme.colorScheme.outlineVariant,
          ),
          account!,
        ],
      ]),
    );
  }
}

/// Wyszukiwarka pozycji menu; Ctrl+K przenosi do niej kursor, Enter otwiera pierwszą podpowiedź.
class _MenuSearch extends StatefulWidget {
  const _MenuSearch({required this.search, required this.items, required this.onSelect});

  final ShellSearch search;
  final List<ShellItem> items;
  final ValueChanged<String> onSelect;

  @override
  State<_MenuSearch> createState() => _MenuSearchState();
}

class _MenuSearchState extends State<_MenuSearch> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyK &&
        HardwareKeyboard.instance.isControlPressed) {
      _focus.requestFocus();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = TruckColors.of(context);
    final scheme = theme.colorScheme;
    return RawAutocomplete<ShellItem>(
      textEditingController: _controller,
      focusNode: _focus,
      displayStringForOption: (item) => item.label,
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return const [];
        return widget.items.where((i) => i.enabled && i.label.toLowerCase().contains(query));
      },
      onSelected: (item) {
        _controller.clear();
        _focus.unfocus();
        widget.onSelect(item.id);
      },
      fieldViewBuilder: (context, controller, focus, submit) => TextField(
        key: const Key('shell-search'),
        controller: controller,
        focusNode: focus,
        onSubmitted: (_) => submit(),
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          hintText: widget.search.hint,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(color: scheme.outline),
          prefixIcon: Icon(Icons.search, size: 20, color: scheme.outline),
          suffixIcon: Padding(
            padding: const EdgeInsets.only(right: Gap.s),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surfaceHigh,
                  borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(widget.search.shortcutLabel,
                      style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                ),
              ),
            ]),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TruckTheme.smallRadius), borderSide: BorderSide.none),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(TruckTheme.smallRadius), borderSide: BorderSide.none),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          color: colors.card,
          borderRadius: BorderRadius.circular(TruckTheme.radius),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400, maxHeight: 320),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(Gap.xs), children: [
              for (final item in options)
                ListTile(
                  dense: true,
                  leading: Icon(item.icon, size: 20),
                  title: Text(item.label),
                  onTap: () => onSelected(item),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SideMenu extends StatelessWidget {
  const _SideMenu({
    required this.brand,
    required this.subtitle,
    required this.version,
    required this.items,
    required this.selected,
    required this.footer,
    required this.status,
    required this.onSelect,
  });

  final String brand;
  final String? subtitle;
  final String? version;
  final List<ShellItem> items;
  final String? selected;
  final List<Widget> footer;
  final Widget? status;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final list = <Widget>[];
    String? group;
    for (final item in items) {
      if (item.group != null && item.group != group) {
        list.add(Padding(
          padding: EdgeInsets.fromLTRB(Gap.m, list.isEmpty ? 0 : Gap.l, Gap.m, Gap.s),
          child: Text(item.group!.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline, letterSpacing: 0.8)),
        ));
      }
      group = item.group;
      list.add(Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: _MenuTile(item: item, selected: item.id == selected, onTap: () => onSelect(item.id)),
      ));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(Gap.l, Gap.l, Gap.l, Gap.l),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(TruckTheme.radius)),
            child: Icon(Icons.local_shipping_outlined, color: scheme.onPrimary, size: 20),
          ),
          const SizedBox(width: Gap.m),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  child: Text(brand,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(color: scheme.primary, fontWeight: FontWeight.w700)),
                ),
                if (version != null) ...[
                  const SizedBox(width: Gap.s),
                  _Tag(label: version!, background: scheme.secondaryContainer, color: scheme.onSecondaryContainer),
                ],
              ]),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
          ),
        ]),
      ),
      Expanded(
        child: ListView(padding: const EdgeInsets.symmetric(horizontal: Gap.m), children: [
          ...list,
          if (footer.isNotEmpty) ...[
            const Padding(padding: EdgeInsets.symmetric(vertical: Gap.s), child: Divider()),
            ...footer,
          ],
        ]),
      ),
      if (status != null) Padding(padding: const EdgeInsets.all(Gap.l), child: status!),
    ]);
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label, required this.background, required this.color});

  final String label;
  final Color background;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(TruckTheme.smallRadius)),
        child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color, fontSize: 10)),
      );
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
    final colors = TruckColors.of(context);
    final fg = selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant;
    final tag = item.tag;
    if (item.sub) {
      return Padding(
        padding: const EdgeInsets.only(left: 22),
        child: DecoratedBox(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: colors.surfaceHigh, width: 2))),
          child: InkWell(
            borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
            hoverColor: colors.surfaceLow,
            onTap: item.enabled ? onTap : null,
            child: Container(
              height: 32,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: Gap.l),
              color: selected ? colors.surfaceLow : null,
              child: Text(item.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                      color: selected ? scheme.primary : scheme.onSurface,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500)),
            ),
          ),
        ),
      );
    }
    final tile = Material(
      color: selected ? scheme.primaryContainer : Colors.transparent,
      borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
      child: InkWell(
        borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
        hoverColor: colors.surfaceLow,
        onTap: item.enabled ? onTap : null,
        child: SizedBox(
          height: 44,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m),
            child: Row(children: [
              Badge(
                isLabelVisible: item.badge > 0,
                label: Text('${item.badge}'),
                child: Icon(item.icon, size: 20, color: fg),
              ),
              const SizedBox(width: Gap.m),
              Expanded(
                child: Text(item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        color: selected ? fg : scheme.onSurface,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500)),
              ),
              if (tag != null)
                _Tag(
                  label: tag,
                  background: item.tagLive
                      ? scheme.tertiaryContainer
                      : (selected ? scheme.onPrimaryContainer.withOpacity(0.2) : colors.surfaceHigh),
                  color: item.tagLive ? scheme.onTertiaryContainer : (selected ? fg : scheme.primary),
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
