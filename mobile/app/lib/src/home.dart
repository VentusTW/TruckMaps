import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'auth.dart';
import 'l10n.dart';
import 'modules_screen.dart';
import 'planner/planner_screen.dart';
import 'vehicles_screen.dart';

/// Ekran główny: menu rdzenia (pojazdy, moduły) i ekrany modułów z dostępem.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.session, required this.registry, required this.onLogout});

  final Session session;
  final ModuleRegistry registry;
  final VoidCallback onLogout;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Page {
  const _Page(this.title, this.icon, this.builder);

  final String title;
  final IconData icon;
  final WidgetBuilder builder;
}

class _HomeScreenState extends State<HomeScreen> {
  List<ModuleAccess> _modules = const [];
  String? _error;
  int _selected = 0;

  /// Zmiana pojazdów na ekranie „Pojazdy” → planer odświeża listę.
  final _vehiclesChanged = ValueNotifier(0);

  @override
  void dispose() {
    _vehiclesChanged.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadModules();
  }

  Future<void> _loadModules() async {
    try {
      final list = await widget.session.api.get('/api/me/modules') as List<dynamic>;
      final server = list.map((m) => ServerModule.fromJson(m as Map<String, dynamic>)).toList();
      setState(() => _modules = widget.registry.resolve(server));
    } catch (error) {
      if (mounted) setState(() => _error = context.l.modulesLoadFailed('$error'));
    }
  }

  List<_Page> get _pages {
    final l = context.l;
    final module = ModuleContext(
      api: widget.session.api,
      userName: widget.session.userName,
      locale: Localizations.localeOf(context),
    );
    return [
      _Page(l.menuRoute, Icons.route_outlined,
          (_) => PlannerScreen(api: widget.session.api, vehiclesChanged: _vehiclesChanged)),
      _Page(
          l.menuVehicles,
          Icons.local_shipping_outlined,
          (_) => VehiclesScreen(
                api: widget.session.api,
                onChanged: () => _vehiclesChanged.value++,
              )),
      for (final access in _modules.where((m) => m.usable))
        for (final entry in access.module!.entries(module)) _Page(entry.title, entry.icon, entry.builder),
      _Page(l.menuModules, Icons.extension_outlined, (_) => ModulesScreen(modules: _modules, error: _error)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final pages = _pages;
    final selected = _selected.clamp(0, pages.length - 1);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final menu = [
      for (final page in pages) NavigationDrawerDestination(icon: Icon(page.icon), label: Text(page.title)),
    ];
    void select(int index) {
      setState(() => _selected = index);
      if (!wide) Navigator.of(context).maybePop();
    }

    final drawer = NavigationDrawer(
      selectedIndex: selected,
      onDestinationSelected: select,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
          child: Text(widget.session.userName.isEmpty ? 'TruckMaps' : widget.session.userName,
              style: Theme.of(context).textTheme.titleSmall),
        ),
        ...menu,
        const Divider(indent: 28, endIndent: 28),
        ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 28),
          leading: const Icon(Icons.logout),
          title: Text(context.l.logout),
          onTap: widget.onLogout,
        ),
      ],
    );
    // Ekrany zostają w pamięci: po powrocie do planera trasa i mapa są tam, gdzie były.
    final body = IndexedStack(index: selected, children: [for (final page in pages) page.builder(context)]);
    return Scaffold(
      appBar: AppBar(title: Text(pages[selected].title)),
      drawer: wide ? null : drawer,
      body: wide ? Row(children: [SizedBox(width: 280, child: drawer), Expanded(child: body)]) : body,
    );
  }
}
