import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';

/// Profile pojazdów konta (prywatne i firmowe) – wymiary, według których liczona jest trasa.
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  late Future<dynamic> _vehicles = widget.api.get('/api/vehicles');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<dynamic>(
      future: _vehicles,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text('${snapshot.error}'),
              TextButton(
                onPressed: () => setState(() => _vehicles = widget.api.get('/api/vehicles')),
                child: Text(context.l.retry),
              ),
            ]),
          );
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final vehicles = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
        if (vehicles.isEmpty) {
          return Center(child: Text(context.l.vehiclesEmpty));
        }
        return ListView.separated(
          padding: const EdgeInsets.all(12),
          itemCount: vehicles.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, i) => _VehicleCard(vehicle: vehicles[i]),
        );
      },
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({required this.vehicle});

  final Map<String, dynamic> vehicle;

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final l = context.l;
    String n(Object? value) => value is num ? l.number(value) : '–';
    final company = v['company_id'] != null;
    return Card(
      child: ListTile(
        leading: Icon(company ? Icons.business_outlined : Icons.person_outline),
        title: Text('${v['name']}'),
        subtitle: Text(l.vehicleSummary(n(v['height_m']), n(v['width_m']), n(v['length_m']), n(v['weight_t']),
                n(v['gvw_t']), n(v['axle_load_t'])) +
            (v['hazmat'] == true ? ' · ADR' : '')),
        trailing: v['can_edit'] == false
            ? Tooltip(message: l.vehicleReadOnly, child: const Icon(Icons.lock_outline))
            : null,
      ),
    );
  }
}
