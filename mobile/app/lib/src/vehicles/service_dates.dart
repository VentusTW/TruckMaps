import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';

/// Rodzaje z zabudową (plandeka, chłodnia, cysterna…) – jak na serwerze.
const bodyKinds = {'combination', 'rigid', 'van', 'semitrailer', 'trailer'};

/// Rodzaje z tachografem (dostawczy do 3,5 t go nie ma) – jak na serwerze.
const tachographKinds = {'combination', 'rigid', 'tractor', 'bus'};

/// Terminy przeglądów i badań (pola na serwerze), w kolejności na ekranie.
const serviceDateKeys = [
  'last_inspection',
  'inspection_until',
  'insurance_until',
  'tachograph_until',
  'tdt_until',
  'adr_until',
];

/// Ile dni przed terminem pokazujemy ostrzeżenie.
const dueSoonDays = 30;

String serviceDateLabel(AppLocalizations l, String key) => switch (key) {
      'last_inspection' => l.vehicleLastInspection,
      'inspection_until' => l.vehicleInspectionUntil,
      'insurance_until' => l.vehicleInsuranceUntil,
      'tachograph_until' => l.vehicleTachographUntil,
      'tdt_until' => l.vehicleTdtUntil,
      _ => l.vehicleAdrUntil,
    };

/// Które terminy dotyczą pojazdu: tachograf – pojazdy z tachografem, TDT – cysterny, ADR – z ADR.
bool serviceDateApplies(String key, {required String kind, required String body, required bool hazmat}) =>
    switch (key) {
      'tachograph_until' => tachographKinds.contains(kind),
      'tdt_until' => bodyKinds.contains(kind) && body == 'tanker',
      'adr_until' => hazmat,
      _ => true,
    };

DateTime? parseDate(Object? value) => value is String ? DateTime.tryParse(value) : null;

String isoDate(DateTime day) => DateFormat('yyyy-MM-dd').format(day);

/// Najpilniejszy termin „ważny do” pojazdu: po terminie albo w ciągu [dueSoonDays] dni.
({String key, DateTime day, bool overdue})? mostUrgent(Map<String, dynamic> vehicle, {DateTime? today}) {
  final now = DateUtils.dateOnly(today ?? DateTime.now());
  ({String key, DateTime day, bool overdue})? found;
  for (final key in serviceDateKeys.skip(1)) {
    final day = parseDate(vehicle[key]);
    if (day == null || day.difference(now).inDays > dueSoonDays) continue;
    if (found == null || day.isBefore(found.day)) found = (key: key, day: day, overdue: day.isBefore(now));
  }
  return found;
}

/// Pole daty z kalendarzem i przyciskiem wyczyszczenia.
class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChanged});

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    Future<void> pick() async {
      final now = DateTime.now();
      final chosen = await showDatePicker(
        context: context,
        initialDate: value ?? now,
        firstDate: DateTime(now.year - 30),
        lastDate: DateTime(now.year + 15),
      );
      if (chosen != null) onChanged(chosen);
    }

    return InkWell(
      onTap: pick,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
          isDense: true,
          suffixIcon: value == null
              ? const Icon(Icons.event_outlined)
              : IconButton(tooltip: l.vehicleDateClear, icon: const Icon(Icons.clear), onPressed: () => onChanged(null)),
        ),
        child: Text(value == null ? l.vehicleDateNone : DateFormat.yMd(l.localeName).format(value!)),
      ),
    );
  }
}

/// Same terminy przeglądów i badań – dla mechanika (i każdego, kto może je zmieniać).
class ServiceDatesScreen extends StatefulWidget {
  const ServiceDatesScreen({super.key, required this.api, required this.vehicle});

  final CoreApi api;
  final Map<String, dynamic> vehicle;

  @override
  State<ServiceDatesScreen> createState() => _ServiceDatesScreenState();
}

class _ServiceDatesScreenState extends State<ServiceDatesScreen> {
  late final Map<String, DateTime?> _dates = {for (final k in serviceDateKeys) k: parseDate(widget.vehicle[k])};
  bool _busy = false;
  String? _error;

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await widget.api.put('/api/vehicles/${widget.vehicle['id']}/service', {
        for (final e in _dates.entries) e.key: e.value == null ? null : isoDate(e.value!),
      });
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final v = widget.vehicle;
    final keys = [
      for (final k in serviceDateKeys)
        if (serviceDateApplies(k,
            kind: '${v['kind']}', body: '${v['trailer_type']}', hazmat: v['hazmat'] == true))
          k,
    ];
    return Scaffold(
      appBar: AppBar(title: Text(l.vehicleDatesTitle('${v['name']}'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final key in keys)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: DateField(
              label: serviceDateLabel(l, key),
              value: _dates[key],
              onChanged: (day) => setState(() => _dates[key] = day),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        FilledButton.icon(
          onPressed: _busy ? null : _save,
          icon: const Icon(Icons.save_outlined),
          label: Text(_busy ? l.saving : l.save),
        ),
      ]),
    );
  }
}
