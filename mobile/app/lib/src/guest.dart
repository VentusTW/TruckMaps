import 'package:core_sdk/core_sdk.dart';
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
    final body = IndexedStack(index: _selected, children: [
      LoginScreen(serverUrl: widget.serverUrl, login: widget.login, onLoggedIn: widget.onLoggedIn),
      FlutterMap(
        options: const MapOptions(initialCenter: LatLng(52.1, 19.1), initialZoom: 6),
        children: [mapTiles()],
      ),
    ]);
    return TruckShell(
      title: open[_selected].$1,
      selected: '$_selected',
      onSelect: (id) => setState(() => _selected = int.parse(id)),
      items: [
        for (final (i, (title, icon)) in open.indexed) ShellItem('$i', title, icon),
        for (final (i, (title, icon)) in locked.indexed) ShellItem('locked-$i', title, icon, enabled: false),
      ],
      footer: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(l.guestLocked, style: Theme.of(context).textTheme.bodySmall),
        ),
      ],
      body: body,
    );
  }
}
