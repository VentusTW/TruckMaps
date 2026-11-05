import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'screens.dart';
import 'texts.dart';

const _base = '/api/m/service';

String _title(Map<String, dynamic> o) {
  final plate = '${o['vehicle_plate'] ?? ''}';
  return plate.isEmpty ? '${o['vehicle_name']}' : '${o['vehicle_name']} · $plate';
}

/// „Zgłoś usterkę” z karty pojazdu – pojazd wybrany z góry.
Future<bool> reportFault(BuildContext context, CoreApi api, Vehicle vehicle) async {
  final sent = await Navigator.of(context)
      .push<dynamic>(MaterialPageRoute(builder: (_) => ReportScreen(api: api, vehicleId: '${vehicle['id']}')));
  return sent != null;
}

/// Sekcja karty pojazdu: otwarte zgłoszenia i koszty napraw z 12 miesięcy.
class ServiceVehicleSection extends StatefulWidget {
  const ServiceVehicleSection({super.key, required this.api, required this.vehicle});

  final CoreApi api;
  final Vehicle vehicle;

  @override
  State<ServiceVehicleSection> createState() => _ServiceVehicleSectionState();
}

class _ServiceVehicleSectionState extends State<ServiceVehicleSection> {
  late final _id = '${widget.vehicle['id']}';
  late Future<List<dynamic>> _data = _load();

  Future<List<dynamic>> _load() {
    final since = DateFormat('yyyy-MM-dd').format(DateTime.now().subtract(const Duration(days: 365)));
    return Future.wait([
      widget.api.get('$_base/orders?open_only=true&vehicle_id=$_id'),
      widget.api.get('$_base/costs?vehicle_id=$_id&date_from=$since').catchError((_) => <dynamic>[]),
    ]);
  }

  Future<void> _push(Widget screen) async {
    final changed = await Navigator.of(context).push<dynamic>(MaterialPageRoute(builder: (_) => screen));
    if (changed != null && mounted) {
      setState(() {
        _data = _load();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ServiceTexts.of(context);
    final theme = Theme.of(context);
    return SectionCard(
      title: t.sectionTitle,
      icon: Icons.build_outlined,
      action: TextButton(onPressed: () => _push(ReportScreen(api: widget.api, vehicleId: _id)), child: Text(t.report)),
      child: FutureBuilder<List<dynamic>>(
        future: _data,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}', style: theme.textTheme.bodySmall);
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final orders = (snapshot.data![0] as List<dynamic>).cast<Map<String, dynamic>>();
          final costs = (snapshot.data![1] as List<dynamic>).cast<Map<String, dynamic>>();
          final count = costs.fold<int>(0, (n, r) => n + (r['orders'] as int? ?? 0));
          final sum = costs
              .map((r) => t.amount(((r['total'] ?? r['parts_total']) as num).toDouble(), r['currency'] as String?))
              .join(' + ');
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (orders.isEmpty) Text(t.noOpenOrders, style: theme.textTheme.bodySmall),
            for (final o in orders)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: ServiceStatusIcon(order: o),
                title: Text('${o['description']}', maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text(t.status(o['status'] as String?)),
                onTap: () => _push(OrderScreen(api: widget.api, order: o)),
              ),
            if (count > 0)
              Padding(
                padding: const EdgeInsets.only(top: Gap.s),
                child: Row(children: [
                  Icon(Icons.payments_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: Gap.s),
                  Expanded(child: Text(t.repairCostsYear(sum, count))),
                ]),
              ),
          ]);
        },
      ),
    );
  }
}

/// Sekcja pulpitu: otwarte zgłoszenia usterek we wszystkich pojazdach, które obsługujesz.
class ServiceDashboardSection extends StatefulWidget {
  const ServiceDashboardSection({super.key, required this.api});

  final CoreApi api;

  @override
  State<ServiceDashboardSection> createState() => _ServiceDashboardSectionState();
}

class _ServiceDashboardSectionState extends State<ServiceDashboardSection> {
  late Future<dynamic> _orders = widget.api.get('$_base/orders?open_only=true');

  @override
  Widget build(BuildContext context) {
    final t = ServiceTexts.of(context);
    return SectionCard(
      title: t.dashboardTitle,
      icon: Icons.report_problem_outlined,
      accent: TruckColors.of(context).reported,
      child: FutureBuilder<dynamic>(
        future: _orders,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Text('${snapshot.error}');
          if (!snapshot.hasData) return const LinearProgressIndicator();
          final orders = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
          if (orders.isEmpty) return Text(t.noOpenOrders);
          // Najpierw pojazdy, które stoją.
          orders.sort((a, b) => (a['urgency'] == 'stopped' ? 0 : 1).compareTo(b['urgency'] == 'stopped' ? 0 : 1));
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final o in orders.take(5))
              AttentionTile(
                title: _title(o),
                subtitle: '${t.status(o['status'] as String?)} · ${o['description']}',
                overdue: o['urgency'] == 'stopped',
                icon: o['urgency'] == 'stopped' ? Icons.block : Icons.report_problem_outlined,
                onTap: () async {
                  final changed = await Navigator.of(context)
                      .push<dynamic>(MaterialPageRoute(builder: (_) => OrderScreen(api: widget.api, order: o)));
                  if (changed != null && mounted) {
                    setState(() {
                      _orders = widget.api.get('$_base/orders?open_only=true');
                    });
                  }
                },
              ),
            if (orders.length > 5) Text(t.moreOrders(orders.length - 5), style: Theme.of(context).textTheme.bodySmall),
          ]);
        },
      ),
    );
  }
}
