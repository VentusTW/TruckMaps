import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/gestures.dart' show kBackMouseButton;
import 'package:flutter/material.dart';
import 'package:module_load/module_load.dart' show LoadPlanScreen;
import 'package:url_launcher/url_launcher.dart';

import 'account/common.dart' show managesCompany, roleLabel;
import 'auth.dart';
import 'dashboard/main_dashboard.dart';
import 'drivers/driver_edit.dart';
import 'drivers/drivers_screen.dart';
import 'fleet/fleet_screen.dart';
import 'fleet/vehicle_edit.dart';
import 'fleet/vehicle_screen.dart';
import 'service/analytics_screen.dart';
import 'service/repairs_screen.dart';
import 'service/tco_screen.dart';
import 'service/workshop_screen.dart';
import 'l10n.dart';
import 'under_construction.dart';
import 'updates.dart';

/// Ekran główny nowego GUI: menu boczne i górny pasek według projektu Stitch, pulpit główny,
/// a każda inna pozycja i każde kliknięcie – ekran „W budowie” (budujemy GUI od początku).
class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.session,
    required this.registry,
    required this.onLogout,
    this.onLanguage,
    this.openUrl,
  });

  final Session session;
  final ModuleRegistry registry;
  final VoidCallback onLogout;

  /// Język wybrany w koncie (`null` = język systemu).
  final ValueChanged<String?>? onLanguage;

  /// Pobranie aktualizacji (testy podmieniają); zwykle przeglądarka systemowa.
  final ValueChanged<Uri>? openUrl;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

/// Element ścieżki: ekran (`dashboard`, `fleet`, pozycja menu) albo kliknięty element (`wip`).
class _Crumb {
  const _Crumb(this.id, [this.title = '', this.arg]);

  final String id;

  /// Nazwa klikniętego elementu; dla pozycji menu – z bieżącego języka.
  final String title;

  /// Np. id kierowcy (profil, edycja).
  final String? arg;
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, dynamic> _settings = const {};
  List<Map<String, dynamic>> _companies = const [];

  /// Ścieżka do bieżącego ekranu (np. Pojazdy i Tabor › WI 4022P) i poprzednie ścieżki (przycisk „Cofnij”).
  List<_Crumb> _trail = const [_Crumb('dashboard')];
  final List<List<_Crumb>> _history = [];
  Map<String, dynamic>? _screen;

  @override
  void initState() {
    super.initState();
    _loadAccount();
    _checkUpdates();
  }

  Future<void> _loadAccount() async {
    try {
      final results =
          await Future.wait([widget.session.api.get('/api/me/settings'), widget.session.api.get('/api/companies')]);
      if (!mounted) return;
      final settings = results[0] as Map<String, dynamic>;
      final language = settings['language'] as String?;
      if (language != null) widget.onLanguage?.call(language);
      setState(() {
        _settings = settings;
        _companies = (results[1] as List<dynamic>).cast<Map<String, dynamic>>();
      });
    } catch (_) {
      // Bez konta z serwera pulpit pokazuje stany puste.
    }
  }

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

  /// Firma do pulpitu: najpierw ta, którą użytkownik zarządza.
  Map<String, dynamic>? get _company =>
      _companies.where((c) => managesCompany(c['role'] as String?)).firstOrNull ?? _companies.firstOrNull;

  String get _userName {
    final name = _settings['display_name'] as String? ?? '';
    return name.isEmpty ? widget.session.userName : name;
  }

  /// Przejście do ścieżki; poprzednia trafia do historii.
  void _go(List<_Crumb> trail) {
    if (trail.length == _trail.length && trail.last.id == _trail.last.id && trail.last.title == _trail.last.title) {
      return;
    }
    setState(() {
      _history.add(_trail);
      if (_history.length > 50) _history.removeAt(0);
      _trail = trail;
    });
  }

  void _back() {
    if (_history.isEmpty) return;
    setState(() => _trail = _history.removeLast());
  }

  /// Kliknięcie na bieżącym ekranie – głębiej w ścieżce.
  void _openWip(String title) => _go([..._trail, _Crumb('wip', title)]);

  /// Ikony górnego paska – osobny ekran od korzenia.
  void _openTop(String title) => _go([_Crumb('wip', title)]);

  void _select(String id) => _go([_Crumb(id)]);

  /// Profil kierowcy (z listy – po id, z innych ekranów – po imieniu i nazwisku).
  void _openDriver(String? id, String name) => _go([const _Crumb('drivers'), _Crumb('driver', name, id)]);

  /// Profil pojazdu.
  void _openVehicle(String id, String name) => _go([const _Crumb('fleet'), _Crumb('vehicle', name, id)]);

  /// Odświeżenie ekranów kierowców po zapisie profilu.
  int _driversVersion = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final screen = _screen;
    final company = _company;
    final group = l.mainMenuGroup;
    final items = [
      ShellItem('dashboard', l.mainMenuDashboard, Icons.grid_view_outlined, group: group),
      ShellItem('fleet', l.mainMenuFleet, Icons.rv_hookup_outlined, group: group),
      ShellItem('live', l.mainMenuLive, Icons.location_on_outlined, group: group, tag: 'LIVE', tagLive: true),
      ShellItem('orders', l.mainMenuOrders, Icons.inventory_2_outlined, group: group),
      ShellItem('load3d', l.mainMenuLoad3d, Icons.view_in_ar_outlined, group: group, tag: '3D'),
      ShellItem('drivers', l.mainMenuDrivers, Icons.timer_outlined, group: group, tag: '561/2006', tagLive: true),
      ShellItem('service', l.mainMenuService, Icons.build_outlined, group: l.mainMenuGroupService),
      ShellItem('repairs', l.mainSubRepairs, Icons.assignment_outlined, group: l.mainMenuGroupService, sub: true),
      ShellItem('parts', l.mainSubParts, Icons.inventory_2_outlined, group: l.mainMenuGroupService, sub: true),
      ShellItem('reports', l.mainMenuReports, Icons.query_stats_outlined, group: l.mainMenuGroupAnalysis),
      ShellItem('tco', l.mainSubTco, Icons.payments_outlined, group: l.mainMenuGroupAnalysis, sub: true),
      ShellItem('eco', l.mainSubEco, Icons.eco_outlined, group: l.mainMenuGroupAnalysis, sub: true),
    ];
    String label(_Crumb c) =>
        c.id == 'wip' ? c.title : (items.where((i) => i.id == c.id).firstOrNull?.label ?? c.title);
    final current = _trail.last;
    final title = label(current);
    final page = switch (current.id) {
      'dashboard' => 0,
      'fleet' => 1,
      'drivers' || 'driver' => 2,
      'driver-edit' => 3,
      'vehicle' => 4,
      'vehicle-edit' => 5,
      'service' => 6,
      'repairs' || 'order' => 7,
      'reports' => 8,
      'tco' => 9,
      'orders' || 'load3d' => 10,
      _ => 11,
    };
    final order = _trail.where((c) => c.id == 'order').lastOrNull;
    final companyName = (company?['name'] as String?) ?? '';
    void openOrder(String id, String no) => _go(
        [_trail.first.id == 'service' ? const _Crumb('service') : const _Crumb('repairs'), _Crumb('order', no, id)]);
    final vehicle = _trail.where((c) => c.id == 'vehicle').lastOrNull;
    final profile = _trail.where((c) => c.id == 'driver').lastOrNull;
    final narrow = MediaQuery.sizeOf(context).width < 720;
    final backButton = IconButton(
      key: const Key('main-back'),
      tooltip: l.mainBack,
      onPressed: _history.isEmpty ? null : _back,
      icon: const Icon(Icons.arrow_back),
    );
    final crumbStyle = theme.textTheme.labelLarge;
    final path = Row(mainAxisSize: MainAxisSize.min, children: [
      backButton,
      Container(
          width: 1, height: 24, margin: const EdgeInsets.symmetric(horizontal: Gap.xs), color: scheme.outlineVariant),
      IconButton(
        key: const Key('crumb-home'),
        tooltip: l.mainMenuDashboard,
        onPressed: () => _go(const [_Crumb('dashboard')]),
        icon: Icon(Icons.home_outlined, color: scheme.onSurfaceVariant),
      ),
      for (final (i, c) in _trail.indexed)
        if (!(i == 0 && c.id == 'dashboard')) ...[
          Icon(Icons.chevron_right, size: 18, color: scheme.outline),
          Flexible(
            child: i == _trail.length - 1
                ? Padding(
                    padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                    child: Text(label(c),
                        key: Key('crumb-$i'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: crumbStyle?.copyWith(color: scheme.onSurface)),
                  )
                : TextButton(
                    key: Key('crumb-$i'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: Gap.s),
                      minimumSize: const Size(0, 36),
                    ),
                    onPressed: () => _go(_trail.sublist(0, i + 1)),
                    child: Text(label(c),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: crumbStyle?.copyWith(color: scheme.primary, fontWeight: FontWeight.w500)),
                  ),
          ),
        ],
    ]);
    final role =
        (screen?['user_title'] as String?) ?? (company == null ? null : roleLabel(l, company['role'] as String?));
    Widget dot(Color color) => Positioned(
          right: 0,
          top: 0,
          child: Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        );
    Widget iconButton(String key, String tooltip, IconData icon, {Color? marker}) => IconButton(
          key: Key(key),
          tooltip: tooltip,
          onPressed: () => _openTop(tooltip),
          icon: Stack(
              clipBehavior: Clip.none,
              children: [Icon(icon, color: scheme.onSurfaceVariant), if (marker != null) dot(marker)]),
        );
    final marks = (screen?['notifications'] as Map<String, dynamic>?) ?? const {};
    // Boczny przycisk myszy „wstecz” – jak w przeglądarce.
    return Listener(
      onPointerDown: (event) {
        if (event.buttons & kBackMouseButton != 0) _back();
      },
      child: TruckShell(
        title: title,
        leading: narrow ? null : path,
        subtitle: (screen?['edition_note'] as String?) ?? l.mainEditionNote(appVersion),
        version: (screen?['edition'] as String?) ?? 'v$appVersion',
        search: ShellSearch(hint: l.mainSearchHint),
        selected: _trail.first.id,
        onSelect: _select,
        items: items,
        status: TelemetryCard(screen: screen),
        context: InkWell(
          key: const Key('main-base'),
          borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
          onTap: () => _openTop(l.mainBase),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: Gap.m, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: TruckColors.of(context).surfaceHigh),
              borderRadius: BorderRadius.circular(TruckTheme.smallRadius),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.warehouse_outlined, size: 20, color: scheme.onSurfaceVariant),
              const SizedBox(width: Gap.s),
              Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                Text(l.mainBase, style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
                Text((screen?['base'] as String?) ?? (company?['name'] as String? ?? '–'),
                    style: theme.textTheme.labelMedium),
              ]),
              const SizedBox(width: Gap.m),
              Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
            ]),
          ),
        ),
        actions: [
          if (narrow) backButton,
          iconButton('main-alerts', l.mainAlertsIcon, Icons.warning_amber_outlined,
              marker: marks['alerts'] == true ? scheme.error : null),
          iconButton('main-notifications', l.mainNotifications, Icons.notifications_outlined,
              marker: marks['notifications'] == true ? scheme.primaryContainer : null),
          iconButton('main-chat', l.mainChat, Icons.forum_outlined),
        ],
        account: PopupMenuButton<String>(
          key: const Key('main-account'),
          tooltip: l.menuAccount,
          onSelected: (id) => id == 'logout' ? widget.onLogout() : _openTop(l.menuAccount),
          itemBuilder: (_) => [
            PopupMenuItem(value: 'account', child: Text(l.menuAccount)),
            PopupMenuItem(value: 'logout', child: Text(l.logout)),
          ],
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.end, mainAxisSize: MainAxisSize.min, children: [
              Text(_userName, style: theme.textTheme.labelLarge),
              if (role != null) Text(role, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            ]),
            const SizedBox(width: Gap.m),
            CircleAvatar(
              radius: 16,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.person_outline, size: 18, color: scheme.onPrimaryContainer),
            ),
          ]),
        ),
        footer: [
          if (narrow) ListTile(leading: const Icon(Icons.logout), title: Text(l.logout), onTap: widget.onLogout),
        ],
        body: IndexedStack(index: page, children: [
          MainDashboard(
            key: ValueKey(company?['id']),
            api: widget.session.api,
            companyId: company?['id'] as String?,
            userName: _userName,
            onOpen: _openWip,
            onDrivers: () => _select('drivers'),
            onScreen: (s) => setState(() => _screen = s),
          ),
          FleetScreen(
            key: ValueKey(('fleet', company?['id'], _driversVersion)),
            api: widget.session.api,
            companyId: company?['id'] as String?,
            onOpen: _openWip,
            onOpenDriver: (name) => _openDriver(null, name),
            onOpenVehicle: _openVehicle,
          ),
          DriversScreen(
            key: ValueKey(('drivers', company?['id'], _driversVersion)),
            api: widget.session.api,
            companyId: company?['id'] as String?,
            driverId: profile?.arg,
            driverName: profile?.title,
            onOpen: _openWip,
            onOpenDriver: (id, name) => _openDriver(id, name),
            onOpenVehicle: _openVehicle,
            onEdit: (id, name) => _go([
              const _Crumb('drivers'),
              _Crumb('driver', name, id),
              _Crumb('driver-edit', l.drvEditCrumb, id),
            ]),
          ),
          if (current.id == 'driver-edit')
            DriverEditScreen(
              key: ValueKey(('driver-edit', current.arg)),
              api: widget.session.api,
              companyId: company?['id'] as String?,
              driverId: current.arg ?? '',
              onOpen: _openWip,
              onDone: (saved) {
                if (saved) _driversVersion++;
                _back();
              },
            )
          else
            const SizedBox(),
          if (vehicle?.arg case final String id)
            VehicleScreen(
              key: ValueKey(('vehicle', id, _driversVersion)),
              api: widget.session.api,
              vehicleId: id,
              onOpen: _openWip,
              onOpenVehicle: _openVehicle,
              onOpenDriver: (name) => _openDriver(null, name),
              onEdit: (id, name) => _go([
                const _Crumb('fleet'),
                _Crumb('vehicle', name, id),
                _Crumb('vehicle-edit', l.vehEditCrumb, id),
              ]),
            )
          else
            const SizedBox(),
          if (current.id == 'vehicle-edit')
            VehicleEditScreen(
              key: ValueKey(('vehicle-edit', current.arg)),
              api: widget.session.api,
              vehicleId: current.arg ?? '',
              onOpen: _openWip,
              onDone: (saved) {
                if (saved) _driversVersion++;
                _back();
              },
            )
          else
            const SizedBox(),
          if (page == 6)
            WorkshopScreen(
              key: ValueKey(('service', company?['id'], _driversVersion)),
              api: widget.session.api,
              companyId: company?['id'] as String?,
              companyName: companyName,
              onOpen: _openWip,
              onOpenOrder: openOrder,
              onOpenRepairs: () => _select('repairs'),
              onOpenTco: () => _select('tco'),
            )
          else
            const SizedBox(),
          if (page == 7)
            RepairsScreen(
              key: ValueKey(('repairs', company?['id'])),
              api: widget.session.api,
              companyId: company?['id'] as String?,
              orderId: order?.arg,
              onOpen: _openWip,
              onOpenOrder: openOrder,
              onOpenVehicle: _openVehicle,
              onClearOrder: () => _go([const _Crumb('repairs')]),
            )
          else
            const SizedBox(),
          if (page == 8)
            AnalyticsScreen(
              key: ValueKey(('reports', company?['id'])),
              api: widget.session.api,
              companyId: company?['id'] as String?,
              companyName: companyName,
              onOpen: _openWip,
              onOpenVehicle: _openVehicle,
            )
          else
            const SizedBox(),
          if (page == 9)
            TcoScreen(
              key: ValueKey(('tco', company?['id'])),
              api: widget.session.api,
              companyId: company?['id'] as String?,
              onOpen: _openWip,
              onOpenDriver: (id, name) => _openDriver(id, name),
            )
          else
            const SizedBox(),
          // Zlecenia i załadunek oraz symulator 3D – jeden ekran.
          if (page == 10)
            LoadPlanScreen(key: ValueKey(('orders', company?['id'])), api: widget.session.api)
          else
            const SizedBox(),
          UnderConstructionScreen(
            title: title,
            icon: items.where((i) => i.id == current.id).firstOrNull?.icon ?? Icons.construction_outlined,
            onBack: () => _go(const [_Crumb('dashboard')]),
          ),
        ]),
      ),
    );
  }
}
