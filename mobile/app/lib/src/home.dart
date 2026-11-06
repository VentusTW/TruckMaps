import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:url_launcher/url_launcher.dart';

import 'account/account_screen.dart';
import 'account/common.dart';
import 'account/onboarding.dart';
import 'auth.dart';
import 'company/company_screen.dart';
import 'company/admin_access_screen.dart';
import 'company/members_screen.dart';
import 'dashboard_screen.dart';
import 'inbox_screen.dart';
import 'l10n.dart';
import 'modules_screen.dart';
import 'planner/country_bans_screen.dart';
import 'planner/planner_screen.dart';
import 'planner/recent.dart';
import 'updates.dart';
import 'vehicles/vehicle_actions.dart' show openVehicleForm;
import 'vehicles/vehicle_card.dart';
import 'vehicles_screen.dart';

/// Ekran główny: pulpit, menu rdzenia (trasa, pojazdy, firma, konto, moduły) i ekrany modułów z dostępem.
/// Moduły dokładają sekcje do pulpitu i karty pojazdu przez kontrakt [TruckMapsModule].
/// Ekrany firmy zależą od roli w wybranej firmie; bez firmy przy pierwszym logowaniu – wybór,
/// czy zakładasz firmę, dołączasz kodem, czy jeździsz sam.
class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key,
      required this.session,
      required this.registry,
      required this.onLogout,
      this.onLanguage,
      this.openUrl,
      this.pageMemory,
      this.plannerMemory});

  final Session session;
  final ModuleRegistry registry;
  final VoidCallback onLogout;

  /// Język wybrany w koncie (`null` = język telefonu).
  final ValueChanged<String?>? onLanguage;

  /// Pobranie aktualizacji (testy podmieniają); zwykle przeglądarka systemowa.
  final ValueChanged<Uri>? openUrl;

  /// Ostatnio używany ekran (testy podmieniają); zwykle magazyn systemu.
  final PageMemory? pageMemory;

  /// Ostatnie trasy i pojazd planera (testy podmieniają); zwykle magazyn systemu.
  final PlannerMemory? plannerMemory;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Który ekran był otwarty ostatnio – po ponownym uruchomieniu aplikacja wraca do niego.
abstract class PageMemory {
  Future<String?> load();
  Future<void> save(String pageId);
}

class SecurePageMemory implements PageMemory {
  static const _key = 'truckmaps.lastPage';
  final _storage = const FlutterSecureStorage();

  @override
  Future<String?> load() async {
    try {
      return await _storage.read(key: _key);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  @override
  Future<void> save(String pageId) async {
    try {
      await _storage.write(key: _key, value: pageId);
    } on PlatformException {
      // bez zapamiętania – następnym razem ekran startowy
    } on MissingPluginException {
      // jak wyżej
    }
  }
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
  /// Wybrany ekran; `null` – jeszcze nie wiadomo (wtedy pulpit).
  String? _selected;
  late final PageMemory _memory = widget.pageMemory ?? SecurePageMemory();
  late final PlannerMemory _plannerMemory = widget.plannerMemory ?? PlannerMemory(const FlutterSecureStorage());
  final _planner = PlannerController();

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

  /// Wejście na pulpit → świeże dane (terminy, wiadomości, sekcje modułów).
  int _dashboardVersion = 0;

  @override
  void dispose() {
    _vehiclesChanged.dispose();
    _vehiclesShown.dispose();
    _planner.dispose();
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
    _restorePage();
    // Prośba administratora ma dotrzeć bez ponownego uruchamiania aplikacji.
    _inboxTimer = Timer.periodic(const Duration(minutes: 1), (_) => _loadInbox());
  }

  Future<void> _restorePage() async {
    final saved = await _memory.load();
    if (saved != null && mounted && _selected == null) setState(() => _selected = saved);
  }

  void _open(String pageId) {
    setState(() => _selected = pageId);
    _memory.save(pageId);
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
        action: SnackBarAction(label: l.inboxShow, onPressed: () => _open('inbox')),
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

  ModuleContext get _moduleContext => ModuleContext(
        api: widget.session.api,
        userName: _userName,
        locale: Localizations.localeOf(context),
      );

  Iterable<TruckMapsModule> get _usable => [for (final m in _modules) if (m.usable) m.module!];

  List<VehicleSection> get _vehicleSections => [for (final m in _usable) ...m.vehicleSections(_moduleContext)];
  List<VehicleAction> get _vehicleActions => [for (final m in _usable) ...m.vehicleActions(_moduleContext)];

  void _vehiclesUpdated() {
    _vehiclesChanged.value++;
    _vehiclesShown.value++;
  }

  /// Karta pojazdu nad bieżącym ekranem (z pulpitu albo listy).
  Future<void> _openVehicle(Map<String, dynamic> vehicle) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => VehicleCardScreen(
          api: widget.session.api,
          vehicle: vehicle,
          sections: _vehicleSections,
          actions: _vehicleActions,
          onChanged: _vehiclesUpdated,
          onPlanRoute: _planWith,
        ),
      ));

  void _planWith(Map<String, dynamic> vehicle) {
    _planner.useVehicle('${vehicle['id']}');
    _open('route');
  }

  void _planRoute(RecentRoute? route) {
    if (route != null) _planner.openRoute(route);
    _open('route');
  }

  Future<void> _addVehicle() async {
    if (await openVehicleForm(context, widget.session.api) && mounted) _vehiclesUpdated();
  }

  List<_Page> get _pages {
    final l = context.l;
    final module = _moduleContext;
    return [
      _Page(
          'dashboard',
          l.menuDashboard,
          Icons.space_dashboard_outlined,
          (_) => DashboardScreen(
                key: ValueKey(('dashboard', _modules.length, _dashboardVersion)),
                api: widget.session.api,
                userName: _userName,
                memory: _plannerMemory,
                onPlanRoute: _planRoute,
                onOpenVehicle: _openVehicle,
                onAddVehicle: _addVehicle,
                onOpenPage: (id) {
                  if (id == 'inbox') _inboxChanged();
                  if (id == 'vehicles') _vehiclesShown.value++;
                  _open(id);
                },
                sections: [for (final m in _usable) ...m.dashboardSections(module)],
              )),
      _Page('route', l.menuRoute, Icons.route_outlined,
          (_) => PlannerScreen(
              api: widget.session.api,
              vehiclesChanged: _vehiclesChanged,
              memory: _plannerMemory,
              controller: _planner)),
      _Page(
          'vehicles',
          l.menuVehicles,
          Icons.local_shipping_outlined,
          (_) => VehiclesScreen(
                api: widget.session.api,
                onChanged: () => _vehiclesChanged.value++,
                refresh: _vehiclesShown,
                sections: _vehicleSections,
                actions: _vehicleActions,
                onPlanRoute: _planWith,
              )),
      _Page('bans', l.menuBans, Icons.block_outlined,
          (_) => CountryBansScreen(api: widget.session.api, standalone: false)),
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
    // Ostatnio używany ekran; gdy go nie ma (pierwsze uruchomienie, moduł bez dostępu) – pulpit.
    var selected = pages.indexWhere((page) => page.id == _selected);
    if (selected < 0) selected = 0;
    final current = pages[selected];
    void select(String id) {
      // Zapowiedziane funkcje kierowcy – ekran „W budowie”, bez zmiany bieżącego ekranu.
      final soon = {'tachograph': context.l.navTachograph, 'ecmr': context.l.navEcmr}[id];
      if (soon != null) {
        openUnderConstruction(context, soon);
        return;
      }
      if (id == 'inbox' && _selected != 'inbox') _inboxChanged();
      // Stan pojazdów zmienia się poza tym ekranem (serwis, nawigacja innych kierowców).
      if (id == 'vehicles') _vehiclesShown.value++;
      if (id == 'route') _vehiclesChanged.value++;
      if (id == 'dashboard' && _selected != 'dashboard') setState(() => _dashboardVersion++);
      _open(id);
    }

    final l = context.l;
    // Kierowca (w firmie albo jeżdżący sam) na telefonie: dolna nawigacja; funkcje jeszcze bez ekranu – wyłączone.
    final role = _company?['role'] as String?;
    final driver = role == null || role == 'driver';
    // Ekrany zostają w pamięci: po powrocie do planera trasa i mapa są tam, gdzie były.
    final body = IndexedStack(index: selected, children: [for (final page in pages) page.builder(context)]);
    return TruckShell(
      title: current.title,
      subtitle: _userName,
      selected: current.id,
      onSelect: select,
      items: [for (final page in pages) ShellItem(page.id, page.title, page.icon, badge: page.badge)],
      bottomItems: driver
          ? [
              ShellItem('route', l.menuRoute, Icons.route_outlined),
              ShellItem('tachograph', l.navTachograph, Icons.timer_outlined),
              ShellItem('ecmr', l.navEcmr, Icons.inventory_2_outlined),
              ShellItem('vehicles', l.navVehicle, Icons.local_shipping_outlined),
            ]
          : null,
      actions: [
        IconButton(
          tooltip: l.menuInbox,
          onPressed: () => select('inbox'),
          icon: _badged(Icons.mail_outline, _unread),
        ),
      ],
      footer: [
        ListTile(
          leading: const Icon(Icons.logout),
          title: Text(l.logout),
          onTap: widget.onLogout,
        ),
      ],
      body: body,
    );
  }
}
