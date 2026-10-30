import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';
import 'list_screen.dart';
import 'sections.dart';

/// Ekran główny: kto jest zalogowany (rola administratora) i listy danych.
/// Konto bez roli administratora albo bez drugiego składnika dostaje komunikat serwera.
class AdminHome extends StatefulWidget {
  const AdminHome({super.key, required this.api, required this.onLogout});

  final CoreApi api;
  final VoidCallback onLogout;

  @override
  State<AdminHome> createState() => _AdminHomeState();
}

class _AdminHomeState extends State<AdminHome> {
  late Future<dynamic> _me = widget.api.get('/api/admin/me');
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return FutureBuilder<dynamic>(
      future: _me,
      builder: (context, snapshot) {
        if (snapshot.hasError) return _refused(l, snapshot.error!);
        if (!snapshot.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
        final me = snapshot.data as Map<String, dynamic>;
        final section = sections[_selected];
        return Scaffold(
          appBar: AppBar(
            title: Text(l.appTitle),
            actions: [
              Center(child: Text(l.signedInAs('${me['name'] == '' ? me['subject'] : me['name']}', l.adminRole(me['role'] as String?)))),
              IconButton(tooltip: l.logout, onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
            ],
          ),
          body: Row(children: [
            NavigationRail(
              selectedIndex: _selected,
              labelType: NavigationRailLabelType.all,
              onDestinationSelected: (i) => setState(() => _selected = i),
              destinations: [
                for (final s in sections) NavigationRailDestination(icon: Icon(s.icon), label: Text(s.title(l))),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: ListScreen(key: ValueKey(section.id), api: widget.api, section: section)),
          ]),
        );
      },
    );
  }

  Widget _refused(AdminLocalizations l, Object error) => Scaffold(
        body: Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.lock_outline, size: 48),
            const SizedBox(height: 12),
            Text('$error', textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Wrap(spacing: 12, children: [
              OutlinedButton(
                onPressed: () {
                  final me = widget.api.get('/api/admin/me');
                  setState(() {
                    _me = me;
                  });
                },
                child: Text(l.retry),
              ),
              FilledButton(onPressed: widget.onLogout, child: Text(l.logout)),
            ]),
          ]),
        ),
      );
}
