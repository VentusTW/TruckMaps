import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import 'auth.dart';
import 'l10n.dart';
import 'login.dart';
import 'planner/planner_screen.dart';

/// Aplikacja bez zalogowania: powitanie z logowaniem i sama mapa (bez serwera);
/// pozostałe pozycje menu widać, ale są wyłączone do zalogowania.
class GuestScreen extends StatefulWidget {
  const GuestScreen({super.key, required this.serverUrl, required this.login, required this.onLoggedIn});

  final String serverUrl;
  final BrowserLogin login;
  final ValueChanged<Session> onLoggedIn;

  @override
  State<GuestScreen> createState() => _GuestScreenState();
}

class _GuestScreenState extends State<GuestScreen> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final open = [(l.menuWelcome, Icons.waving_hand_outlined), (l.menuMap, Icons.map_outlined)];
    final locked = [
      (l.menuRoute, Icons.route_outlined),
      (l.menuVehicles, Icons.local_shipping_outlined),
      (l.menuBans, Icons.block_outlined),
      (l.menuCompany, Icons.business_outlined),
      (l.menuInbox, Icons.mail_outline),
      (l.menuModules, Icons.extension_outlined),
      (l.menuAccount, Icons.person_outline),
    ];
    final drawer = NavigationDrawer(
      selectedIndex: _selected,
      onDestinationSelected: (index) {
        setState(() => _selected = index);
        if (!wide) Navigator.of(context).maybePop();
      },
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 16, 16, 8),
          child: Text('TruckMaps', style: Theme.of(context).textTheme.titleSmall),
        ),
        for (final (title, icon) in open) NavigationDrawerDestination(icon: Icon(icon), label: Text(title)),
        for (final (title, icon) in locked)
          NavigationDrawerDestination(icon: Icon(icon), label: Text(title), enabled: false),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 8, 16, 16),
          child: Text(l.guestLocked, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
    );
    final body = IndexedStack(index: _selected, children: [
      LoginScreen(serverUrl: widget.serverUrl, login: widget.login, onLoggedIn: widget.onLoggedIn),
      FlutterMap(
        options: const MapOptions(initialCenter: LatLng(52.1, 19.1), initialZoom: 6),
        children: [mapTiles()],
      ),
    ]);
    return Scaffold(
      appBar: AppBar(title: Text(open[_selected].$1)),
      drawer: wide ? null : drawer,
      body: wide ? Row(children: [SizedBox(width: 280, child: drawer), Expanded(child: body)]) : body,
    );
  }
}
