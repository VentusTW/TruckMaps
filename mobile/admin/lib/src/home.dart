import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'grants.dart';
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

  /// Prośby i dostępy tego administratora; zegar co sekundę pilnuje ostrzeżeń i odliczania.
  List<Map<String, dynamic>> _grants = const [];
  final _warned = <String>{};
  Timer? _clock;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    _loadGrants();
    _refresh = Timer.periodic(const Duration(seconds: 30), (_) => _loadGrants());
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _clock?.cancel();
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _loadGrants() async {
    try {
      final grants = (await widget.api.get('/api/admin/grants') as List<dynamic>).cast<Map<String, dynamic>>();
      if (!mounted) return;
      setState(() => _grants = [
            for (final g in grants)
              if (g['state'] == 'pending' || g['state'] == 'active') g
          ]);
      _tick();
    } catch (_) {
      // Konto bez dostępu widzi komunikat z /api/admin/me; tu nic do pokazania.
    }
  }

  void _tick() {
    final now = DateTime.now();
    final active = _grants.where((g) => g['state'] == 'active').toList();
    if (active.isEmpty || !mounted) return;
    // Po terminie – stan z serwera (wygasł albo przedłużony).
    if (active.any((g) => leftOf(g, now) <= Duration.zero)) {
      _loadGrants();
      return;
    }
    setState(() {});
    for (final grant in active) {
      final warning = warningFor(leftOf(grant, now));
      // Przedłużenie zmienia termin, więc ostrzeżenia wracają przy nowym końcu.
      final key = '${grant['id']}@${grant['expires_at']}@${warning?.inMinutes}';
      if (warning != null && _warned.add(key)) _warn(grant);
    }
  }

  Future<void> _warn(Map<String, dynamic> grant) async {
    final l = context.l;
    final action = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.timer_outlined),
        title: Text(l.grantEndingTitle),
        content:
            Text(l.grantEndingText('${grant['company_name']}', (leftOf(grant, DateTime.now()).inSeconds / 60).ceil())),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, 'close'), child: Text(l.grantClose)),
          TextButton(onPressed: () => Navigator.pop(context, 'extend'), child: Text(l.grantRequestExtension)),
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(l.ok)),
        ],
      ),
    );
    if (action == 'extend') await _extend(grant);
    if (action == 'close') await _close(grant);
  }

  Future<void> _extend(Map<String, dynamic> grant) => _call(
        () => widget.api.post('/api/admin/grants/${grant['id']}/extension-request', {'minutes': 30}),
        context.l.grantExtensionSent,
      );

  Future<void> _close(Map<String, dynamic> grant) =>
      _call(() => widget.api.post('/api/admin/grants/${grant['id']}/close', null));

  Future<void> _call(Future<dynamic> Function() request, [String? done]) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await request();
      if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
      await _loadGrants();
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

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
              Center(
                  child: Text(l.signedInAs(
                      '${me['name'] == '' ? me['subject'] : me['name']}', l.adminRole(me['role'] as String?)))),
              IconButton(tooltip: l.logout, onPressed: widget.onLogout, icon: const Icon(Icons.logout)),
            ],
          ),
          body: Column(children: [
            for (final grant in _grants)
              GrantBar(
                grant: grant,
                now: DateTime.now(),
                onExtend: () => _extend(grant),
                onClose: () => _close(grant),
              ),
            Expanded(
                child: Row(children: [
              // Dziesięć list nie mieści się w niskim oknie – menu przewija się.
              LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: constraints.maxHeight),
                    child: IntrinsicHeight(
                      child: NavigationRail(
                        selectedIndex: _selected,
                        labelType: NavigationRailLabelType.all,
                        onDestinationSelected: (i) => setState(() => _selected = i),
                        destinations: [
                          for (final s in sections)
                            NavigationRailDestination(icon: Icon(s.icon), label: Text(s.title(l))),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: ListScreen(
                  key: ValueKey(section.id),
                  api: widget.api,
                  section: section,
                  fullAdmin: me['role'] == 'full',
                  onRequested: _loadGrants,
                ),
              ),
            ])),
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
