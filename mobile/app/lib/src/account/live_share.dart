import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import '../l10n.dart';
import '../navigation/live_presence.dart';
import '../navigation/live_sharing.dart';
import 'common.dart';

/// Konto: udostępnianie pozycji firmie także bez nawigacji (Centrala & Live Map) – wybór
/// pojazdu firmy i przełącznik. Działa, dopóki działa aplikacja; po ponownym uruchomieniu wyłączone.
class LiveShareSection extends StatefulWidget {
  const LiveShareSection({super.key, required this.api, this.consent, this.presence});

  final CoreApi api;
  final LiveConsentStore? consent;
  final LivePresence? presence;

  @override
  State<LiveShareSection> createState() => _LiveShareSectionState();
}

class _LiveShareSectionState extends State<LiveShareSection> {
  late final LivePresence _presence = widget.presence ?? LivePresence.instance;
  List<(String, String)> _vehicles = const [];
  String? _vehicle;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _vehicle = _presence.vehicleId;
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await widget.api.get('/api/vehicles') as List<dynamic>;
      final vehicles = [
        for (final v in list.cast<Map<String, dynamic>>())
          if (v['company_id'] != null && v['kind'] != 'semitrailer' && v['kind'] != 'trailer')
            ('${v['id']}', [v['name'], v['plate']].whereType<String>().join(' · ')),
      ];
      if (!mounted) return;
      setState(() {
        _vehicles = vehicles;
        _vehicle ??= vehicles.isEmpty ? null : vehicles.first.$1;
      });
    } catch (_) {
      // Bez listy pojazdów sekcja pokazuje tylko podpowiedź.
    }
  }

  Future<bool> _ask() async {
    final l = context.l;
    final allowed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.liveConsentTitle),
        content: Text(l.liveShareConsentText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.liveConsentDeny)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.liveConsentAllow)),
        ],
      ),
    );
    return allowed ?? false;
  }

  Future<void> _toggle(bool on) async {
    final l = context.l;
    final vehicle = _vehicle;
    if (vehicle == null) return;
    setState(() => _busy = true);
    try {
      if (!on) {
        await _presence.stop();
        return;
      }
      final consent = widget.consent ?? const SecureLiveConsentStore();
      // Wyłączenie w koncie po wcześniejszym „Nie teraz” – pytamy jeszcze raz.
      if (await consent.read() == false) await consent.write(await _ask());
      if (!mounted) return;
      final result = await _presence.start(
        widget.api,
        vehicle,
        ask: _ask,
        consent: consent,
        notificationTitle: l.liveShareNotificationTitle,
        notificationText: l.liveShareNotificationText,
      );
      if (!mounted || result == LiveStart.ok) return;
      final message = switch (result) {
        LiveStart.gpsDisabled => l.gpsDisabled,
        LiveStart.gpsDenied => l.gpsDenied,
        _ => l.liveShareNotShared,
      };
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final on = _presence.vehicleId != null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionHeader(l.liveShareTitle),
      const SizedBox(height: 8),
      if (_vehicles.isEmpty)
        Text(l.liveShareNoVehicles, style: Theme.of(context).textTheme.bodySmall)
      else ...[
        DropdownButtonFormField<String>(
          value: _vehicle,
          decoration: field(l.liveShareVehicle),
          items: [for (final (id, label) in _vehicles) DropdownMenuItem(value: id, child: Text(label))],
          onChanged: on || _busy ? null : (id) => setState(() => _vehicle = id),
        ),
        SwitchListTile(
          key: const Key('live-share'),
          contentPadding: EdgeInsets.zero,
          value: on,
          onChanged: _busy || _vehicle == null ? null : _toggle,
          title: Text(l.liveShareSwitch),
          subtitle: Text(l.liveShareHint),
        ),
      ],
    ]);
  }
}
