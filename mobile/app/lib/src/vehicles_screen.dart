import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';

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
                child: const Text('Spróbuj ponownie'),
              ),
            ]),
          );
        }
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
        final vehicles = (snapshot.data as List<dynamic>).cast<Map<String, dynamic>>();
        if (vehicles.isEmpty) {
          return const Center(child: Text('Brak pojazdów. Dodaj pojazd w planerze trasy.'));
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

  String _num(Object? value) => '$value'.replaceAll('.', ',');

  @override
  Widget build(BuildContext context) {
    final v = vehicle;
    final company = v['company_id'] != null;
    return Card(
      child: ListTile(
        leading: Icon(company ? Icons.business_outlined : Icons.person_outline),
        title: Text('${v['name']}'),
        subtitle: Text('wys. ${_num(v['height_m'])} m · szer. ${_num(v['width_m'])} m · '
            'dł. ${_num(v['length_m'])} m · ${_num(v['weight_t'])} t (DMC ${_num(v['gvw_t'])} t) · '
            'nacisk osi ${_num(v['axle_load_t'])} t${v['hazmat'] == true ? ' · ADR' : ''}'),
        trailing: v['can_edit'] == false ? const Tooltip(message: 'Pojazd firmy – tylko do odczytu', child: Icon(Icons.lock_outline)) : null,
      ),
    );
  }
}
