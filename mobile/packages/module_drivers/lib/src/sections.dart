import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'screens.dart';
import 'texts.dart';

const _base = '/api/m/drivers';

List<Map<String, dynamic>> _list(dynamic data) => (data as List<dynamic>).cast<Map<String, dynamic>>();

/// Sekcja karty pojazdu: kierowcy z kartoteki przydzieleni do pojazdu i ich terminy.
class DriversVehicleSection extends StatefulWidget {
  const DriversVehicleSection({super.key, required this.api, required this.vehicle});

  final CoreApi api;
  final Vehicle vehicle;

  @override
  State<DriversVehicleSection> createState() => _DriversVehicleSectionState();
}

class _DriversVehicleSectionState extends State<DriversVehicleSection> {
  late Future<dynamic> _drivers = widget.api.get('$_base/drivers');

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    final theme = Theme.of(context);
    final id = '${widget.vehicle['id']}';
    return SectionCard(
      title: t.vehicleSectionTitle,
      icon: Icons.badge_outlined,
      child: FutureBuilder<dynamic>(
        future: _drivers,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}', style: theme.textTheme.bodySmall);
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final drivers = [
            for (final d in _list(snapshot.data))
              if (_list(d['vehicles']).any((v) => '${v['vehicle_id']}' == id)) d,
          ];
          if (drivers.isEmpty) return Text(t.vehicleSectionEmpty, style: theme.textTheme.bodySmall);
          return Column(children: [
            for (final d in drivers) _tile(context, t, d),
          ]);
        },
      ),
    );
  }

  Widget _tile(BuildContext context, DriversTexts t, Map<String, dynamic> d) {
    final dues = _list(d['dues']);
    final overdue = dues.where((x) => x['state'] == 'overdue').length;
    final soon = dues.where((x) => x['state'] == 'soon').length;
    final colors = TruckColors.of(context);
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.person_outline),
      title: Text('${d['name']}'),
      subtitle: overdue + soon > 0
          ? Text(t.dueSummary(overdue, soon),
              style: TextStyle(color: overdue > 0 ? Theme.of(context).colorScheme.error : colors.warning))
          : Text(t.allValid),
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        await Navigator.of(context)
            .push<void>(MaterialPageRoute(builder: (_) => DriverScreen(api: widget.api, driverId: '${d['id']}')));
        if (mounted) {
          setState(() {
            _drivers = widget.api.get('$_base/drivers');
          });
        }
      },
    );
  }
}

/// Sekcja pulpitu: kwalifikacje kierowców po terminie albo bliskie terminu.
class DriversDashboardSection extends StatefulWidget {
  const DriversDashboardSection({super.key, required this.api});

  final CoreApi api;

  @override
  State<DriversDashboardSection> createState() => _DriversDashboardSectionState();
}

class _DriversDashboardSectionState extends State<DriversDashboardSection> {
  late final Future<dynamic> _drivers = widget.api.get('$_base/drivers');

  @override
  Widget build(BuildContext context) {
    final t = DriversTexts.of(context);
    return SectionCard(
      title: t.dashboardTitle,
      icon: Icons.badge_outlined,
      child: FutureBuilder<dynamic>(
        future: _drivers,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final items = [
            for (final d in _list(snapshot.data))
              for (final due in _list(d['dues']))
                if (due['state'] == 'overdue' || due['state'] == 'soon') (d, due),
          ]..sort((a, b) => '${a.$2['day']}'.compareTo('${b.$2['day']}'));
          if (items.isEmpty) return Text(t.dashboardOk);
          return Column(children: [
            for (final (d, due) in items.take(6))
              AttentionTile(
                title: '${d['name']}',
                subtitle: [
                  t.field('${due['field']}'),
                  if (DateTime.tryParse('${due['day']}') case final day?) t.date(day),
                ].join(' · '),
                overdue: due['state'] == 'overdue',
                icon: Icons.badge_outlined,
                onTap: () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => DriverScreen(api: widget.api, driverId: '${d['id']}'))),
              ),
          ]);
        },
      ),
    );
  }
}
