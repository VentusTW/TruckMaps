import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

import 'l10n.dart';
import 'vehicles/vehicle_form.dart';

/// Profile pojazdów konta (prywatne i firmowe) – wymiary, według których liczona jest trasa.
/// Dodawanie, zmiana i usuwanie; pojazd firmy zmieniają właściciel i dyspozytorzy.
class VehiclesScreen extends StatefulWidget {
  const VehiclesScreen({super.key, required this.api, this.onChanged});

  final CoreApi api;

  /// Po każdej zmianie listy (np. planer odświeża wybór pojazdu).
  final VoidCallback? onChanged;

  @override
  State<VehiclesScreen> createState() => _VehiclesScreenState();
}

class _VehiclesScreenState extends State<VehiclesScreen> {
  late Future<dynamic> _vehicles = widget.api.get('/api/vehicles');

  void _reload() {
    final vehicles = widget.api.get('/api/vehicles');
    setState(() {
      _vehicles = vehicles;
    });
    widget.onChanged?.call();
  }

  Future<void> _open([Map<String, dynamic>? vehicle]) async {
    final saved = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => VehicleFormScreen(api: widget.api, vehicle: vehicle)),
    );
    if (saved != null && mounted) _reload();
  }

  Future<void> _delete(Map<String, dynamic> vehicle) async {
    final l = context.l;
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.vehicleDeleteTitle),
        content: Text(l.vehicleDeleteQuestion('${vehicle['name']}')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.delete)),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      await widget.api.delete('/api/vehicles/${vehicle['id']}');
      _reload();
    } catch (error) {
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'add-vehicle',
        onPressed: _open,
        icon: const Icon(Icons.add),
        label: Text(l.vehicleAdd),
      ),
      body: FutureBuilder<dynamic>(
        future: _vehicles,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text('${snapshot.error}'),
                TextButton(onPressed: _reload, child: Text(l.retry)),
              ]),
            );
          }
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final vehicles = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
          if (vehicles.isEmpty) return Center(child: Text(l.vehiclesEmpty));
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
            itemCount: vehicles.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, i) => _VehicleCard(
              vehicle: vehicles[i],
              onEdit: () => _open(vehicles[i]),
              onDelete: () => _delete(vehicles[i]),
            ),
          );
        },
      ),
    );
  }
}

class _VehicleCard extends StatelessWidget {
  const _VehicleCard({required this.vehicle, required this.onEdit, required this.onDelete});

  final Map<String, dynamic> vehicle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final l = context.l;
    final company = v['company_id'] != null;
    final editable = v['can_edit'] != false;
    String n(Object? value) => value is num ? l.number(value) : '–';
    final plate = v['plate'] as String?;
    return Card(
      child: ListTile(
        leading: Icon(company ? Icons.business_outlined : Icons.person_outline),
        title: Text(plate == null ? '${v['name']}' : '${v['name']} · $plate'),
        subtitle: Text(l.vehicleSummary(n(v['height_m']), n(v['width_m']), n(v['length_m']), n(v['weight_t']),
                n(v['gvw_t']), n(v['axle_load_t'])) +
            (v['hazmat'] == true ? ' · ADR' : '')),
        onTap: editable ? onEdit : null,
        trailing: editable
            ? PopupMenuButton<String>(
                onSelected: (action) => action == 'edit' ? onEdit() : onDelete(),
                itemBuilder: (context) => [
                  PopupMenuItem(value: 'edit', child: Text(l.edit)),
                  PopupMenuItem(value: 'delete', child: Text(l.delete)),
                ],
              )
            : Tooltip(message: l.vehicleReadOnly, child: const Icon(Icons.lock_outline)),
      ),
    );
  }
}
