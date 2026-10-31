import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account/account_screen.dart';
import 'account/common.dart';
import 'account/onboarding.dart';
import 'auth.dart';
import 'company/company_screen.dart';
import 'company/admin_access_screen.dart';
import 'company/members_screen.dart';
import 'inbox_screen.dart';
import 'l10n.dart';
import 'modules_screen.dart';
import 'planner/planner_screen.dart';
import 'updates.dart';
import 'vehicles_screen.dart';

/// Ekran główny: menu rdzenia (trasa, pojazdy, firma, konto, moduły) i ekrany modułów z dostępem.
/// Ekrany firmy zależą od roli w wybranej firmie; bez firmy przy pierwszym logowaniu – wybór,
/// czy zakładasz firmę, dołączasz kodem, czy jeździsz sam.
class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      required this.session,
      required this.registry,
      required this.onLogout,
      this.onLanguage,
      this.openUrl});

  final Session session;
  final ModuleRegistry registry;
  final VoidCallback onLogout;

  /// Język wybrany w koncie (`null` = język telefonu).
  final ValueChanged<String?>? onLanguage;

  /// Pobranie aktualizacji (testy podmieniają); zwykle przeglądarka systemowa.
  final ValueChanged<Uri>? openUrl;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _Page {
  const _Page(this.id, this.title, this.icon, this.builder, {this.badge = 0});

  /// Stały identyfikator: wybrany ekran zostaje wybrany, gdy menu zmienia się z rolą albo językiem.
  final String id;

  final String title;
  final IconData icon;
  final WidgetBuilder builder;

  /// Liczba nowych (np. nieprzeczytane wiadomości) przy pozycji menu.
  final int badge;
}

/// Ikona z licznikiem nowych.
Widget _badged(IconData icon, int count) =>
    Badge(isLabelVisible: count > 0, label: Text('$count'), child: Icon(icon));

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

  /// Wejście na ekran „Pojazdy” → świeża lista (np. pojazd właśnie trafił do serwisu).
  final _vehiclesShown = ValueNotifier(0);

  /// Nieprzeczytane wiadomości i prośby administratora, które już pokazaliśmy.
  int _unread = 0;
  final _announced = <String>{};
  Timer? _inboxTimer;
  int _inboxVersion = 0;

  @override
  void dispose() {
    _vehiclesChanged.dispose();
    _vehiclesShown.dispose();
    _inboxTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadModules();
    _loadAccount();
    _checkUpdates();
    _loadInbox();
    // Prośba administratora ma dotrzeć bez ponownego uruchamiania aplikacji.
    _inboxTimer = Timer.periodic(const Duration(minutes: 1), (_) => _loadInbox());
  }

  /// Licznik nieprzeczytanych; nowa prośba administratora o dostęp – wyróżnione powiadomienie.
  Future<void> _loadInbox() async {
    try {
      final inbox = await widget.session.api.get('/api/me/messages') as Map<String, dynamic>;
      if (!mounted) return;
      final requests = [
        for (final m in (inbox['items'] as List<dynamic>).cast<Map<String, dynamic>>())
          if (m['kind'] == 'admin_access_request' && (m['grant'] as Map?)?['state'] == 'pending') '${m['id']}',
      ];
      setState(() => _unread = inbox['unread'] as int? ?? 0);
      final fresh = requests.where(_announced.add).toList();
      if (fresh.isEmpty || _selected == 'inbox') return;
      final l = context.l;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        duration: const Duration(seconds: 10),
        backgroundColor: Theme.of(context).colorScheme.tertiary,
        content: Text(l.inboxNewRequest),
        action: SnackBarAction(label: l.inboxShow, onPressed: () => setState(() => _selected = 'inbox')),
      ));
    } catch (_) {
      // Skrzynka jest dodatkiem – bez niej aplikacja działa dalej.
    }
  }

  void _inboxChanged() {
    _loadInbox();
    setState(() => _inboxVersion++);
  }

  /// Po zalogowaniu: czy są nowsze wydania. Pytamy tylko na ekranie głównym – nigdy w trakcie
  /// jazdy (nawigacja i inne ekrany otwierają się nad nim).
  Future<void> _checkUpdates() async {
    final updates = await checkUpdates(widget.session.api);
    if (updates.isEmpty || !mounted || ModalRoute.of(context)?.isCurrent == false) return;
    await showDialog<void>(
      context: context,
      builder: (_) => UpdateDialog(updates: updates, onDownload: (update) => _download(Uri.parse('${update['url']}'))),
    );
  }

  void _download(Uri url) {
    final open = widget.openUrl;
    if (open != null) return open(url);
    launchUrl(url, mode: LaunchMode.externalApplication);
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
                refresh: _vehiclesShown,
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
                    companyKind: company['kind'] as String?,
                    onChanged: _loadAccount,
                  )),
        if (company['role'] == 'owner')
          _Page(
              'admin-access',
              l.menuAdminAccess,
              Icons.admin_panel_settings_outlined,
              (_) => AdminAccessScreen(
                    key: ValueKey(('admin-access', company['id'])),
                    api: widget.session.api,
                    companyId: company['id'] as String,
                  )),
      ],
      for (final access in _modules.where((m) => m.usable))
        for (final (i, entry) in access.module!.entries(module).indexed)
          _Page('${access.id}/$i', entry.title, entry.icon, entry.builder),
      _Page(
          'inbox',
          l.menuInbox,
          Icons.mail_outline,
          (_) => InboxScreen(
                key: ValueKey(('inbox', _inboxVersion)),
                api: widget.session.api,
                onChanged: _loadInbox,
              ),
          badge: _unread),
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
      for (final page in pages) NavigationDrawerDestination(icon: _badged(page.icon, page.badge), label: Text(page.title)),
    ];
    void select(int index) {
      if (pages[index].id == 'inbox' && _selected != 'inbox') _inboxChanged();
      // Stan pojazdów zmienia się poza tym ekranem (serwis, nawigacja innych kierowców).
      if (pages[index].id == 'vehicles') _vehiclesShown.value++;
      if (pages[index].id == 'route') _vehiclesChanged.value++;
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
      appBar: AppBar(title: Text(pages[selected].title), actions: [
        IconButton(
          tooltip: context.l.menuInbox,
          onPressed: () {
            if (_selected != 'inbox') _inboxChanged();
            setState(() => _selected = 'inbox');
          },
          icon: _badged(Icons.mail_outline, _unread),
        ),
      ]),
      drawer: wide ? null : drawer,
      body: wide ? Row(children: [SizedBox(width: 280, child: drawer), Expanded(child: body)]) : body,
    );
  }
}
