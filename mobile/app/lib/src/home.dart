import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'account/account_screen.dart';
import 'account/common.dart';
import 'account/onboarding.dart';
import 'auth.dart';
import 'company/company_screen.dart';
import 'company/members_screen.dart';
import 'l10n.dart';
import 'modules_screen.dart';
import 'planner/planner_screen.dart';
import 'vehicles_screen.dart';

/// Ekran główny: menu rdzenia (trasa, pojazdy, firma, konto, moduły) i ekrany modułów z dostępem.
/// Ekrany firmy zależą od roli w wybranej firmie; bez firmy przy pierwszym logowaniu – wybór,
/// czy zakładasz firmę, dołączasz kodem, czy jeździsz sam.
class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key, required this.session, required this.registry, required this.onLogout, this.onLanguage});

  final Session session;
  final ModuleRegistry registry;
  final VoidCallback onLogout;

  /// Język wybrany w koncie (`null` = język telefonu).
  final ValueChanged<String?>? onLanguage;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Page {
  const _Page(this.id, this.title, this.icon, this.builder);

  /// Stały identyfikator: wybrany ekran zostaje wybrany, gdy menu zmienia się z rolą albo językiem.
  final String id;

  final String title;
  final IconData icon;
  final WidgetBuilder builder;
}

class _HomeScreenState extends State<HomeScreen> {
  List<ModuleAccess> _modules = const [];
  String? _error;
  String _selected = 'route';

  /// Ustawienia konta (`/api/me/settings`) i firmy użytkownika z jego rolą w każdej.
  Map<String, dynamic> _settings = const {};
  List<Map<String, dynamic>> _companies = const [];
  String? _companyId;
  bool _onboarding = false;

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
    _loadAccount();
  }

  Future<void> _loadAccount() async {
    try {
      final results = await Future.wait([widget.session.api.get('/api/me/settings'), widget.session.api.get('/api/companies')]);
      if (!mounted) return;
      final settings = results[0] as Map<String, dynamic>;
      final companies = (results[1] as List<dynamic>).cast<Map<String, dynamic>>();
      final language = settings['language'] as String?;
      if (language != null && language != _settings['language']) widget.onLanguage?.call(language);
      setState(() {
        _settings = settings;
        _companies = companies;
        if (!companies.any((c) => c['id'] == _companyId)) _companyId = companies.firstOrNull?['id'] as String?;
        _onboarding = settings['onboarded'] == false && companies.isEmpty;
      });
    } catch (_) {
      // Bez konta z serwera aplikacja działa dalej: planer i pojazdy bez ekranów firmy.
    }
  }

  Map<String, dynamic>? get _company => _companies.where((c) => c['id'] == _companyId).firstOrNull;

  String get _userName {
    final name = _settings['display_name'] as String? ?? '';
    return name.isEmpty ? widget.session.userName : name;
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
      userName: _userName,
      locale: Localizations.localeOf(context),
    );
    return [
      _Page('route', l.menuRoute, Icons.route_outlined,
          (_) => PlannerScreen(api: widget.session.api, vehiclesChanged: _vehiclesChanged)),
      _Page(
          'vehicles',
          l.menuVehicles,
          Icons.local_shipping_outlined,
          (_) => VehiclesScreen(
                api: widget.session.api,
                onChanged: () => _vehiclesChanged.value++,
              )),
      if (_company case final company?) ...[
        _Page(
            'company',
            l.menuCompany,
            Icons.business_outlined,
            (_) => CompanyScreen(
                  key: ValueKey(('company', company)),
                  api: widget.session.api,
                  companies: _companies,
                  company: company,
                  onSwitch: (id) => setState(() => _companyId = id),
                  onChanged: _loadAccount,
                )),
        if (managesCompany(company['role'] as String?))
          _Page(
              'members',
              l.menuMembers,
              Icons.group_outlined,
              (_) => MembersScreen(
                    key: ValueKey(('members', company['id'], company['role'])),
                    api: widget.session.api,
                    companyId: company['id'] as String,
                    role: company['role'] as String,
                    onChanged: _loadAccount,
                  )),
      ],
      for (final access in _modules.where((m) => m.usable))
        for (final (i, entry) in access.module!.entries(module).indexed)
          _Page('${access.id}/$i', entry.title, entry.icon, entry.builder),
      _Page('modules', l.menuModules, Icons.extension_outlined, (_) => ModulesScreen(modules: _modules, error: _error)),
      _Page(
          'account',
          l.menuAccount,
          Icons.person_outline,
          (_) => AccountScreen(
                key: ValueKey(('account', _settings)),
                api: widget.session.api,
                settings: _settings,
                onChanged: _loadAccount,
                onLanguage: (language) => widget.onLanguage?.call(language),
                onLogout: widget.onLogout,
              )),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (_onboarding) {
      return OnboardingScreen(api: widget.session.api, onDone: _loadAccount, onLogout: widget.onLogout);
    }
    final pages = _pages;
    final selected = pages.indexWhere((page) => page.id == _selected).clamp(0, pages.length - 1);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final menu = [
      for (final page in pages) NavigationDrawerDestination(icon: Icon(page.icon), label: Text(page.title)),
    ];
    void select(int index) {
      setState(() => _selected = pages[index].id);
      if (!wide) Navigator.of(context).maybePop();
    }

    final drawer = NavigationDrawer(
      selectedIndex: selected,
      onDestinationSelected: select,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
          child: Text(_userName.isEmpty ? 'TruckMaps' : _userName, style: Theme.of(context).textTheme.titleSmall),
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
