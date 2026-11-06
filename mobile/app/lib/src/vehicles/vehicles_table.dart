import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:intl/intl.dart';

import '../l10n.dart';
import 'service_dates.dart';
import 'vehicle_state.dart';
import 'vehicle_form.dart';

/// Wybrany widok listy pojazdów, zapamiętany na urządzeniu.
abstract class VehiclesViewStore {
  Future<bool> readTable();
  Future<void> writeTable(bool table);
}

class SecureVehiclesViewStore implements VehiclesViewStore {
  const SecureVehiclesViewStore([this._storage = const FlutterSecureStorage()]);

  static const _key = 'truckmaps.vehicles.view';
  final FlutterSecureStorage _storage;

  // Bez dostępu do magazynu (np. w testach) – zostają kafelki.
  @override
  Future<bool> readTable() async {
    try {
      return await _storage.read(key: _key) == 'table';
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> writeTable(bool table) async {
    try {
      await _storage.write(key: _key, value: table ? 'table' : 'cards');
    } catch (_) {}
  }
}

/// Najbliższy termin pojazdu (bez progu 30 dni – do kolumny tabeli).
({String key, DateTime day})? nextServiceDate(Map<String, dynamic> vehicle) {
  ({String key, DateTime day})? found;
  for (final key in serviceDateKeys.skip(1)) {
    final day = parseDate(vehicle[key]);
    if (day != null && (found == null || day.isBefore(found.day))) found = (key: key, day: day);
  }
  return found;
}

/// Pasuje do wyszukiwania po nazwie albo tablicy (bez wielkości liter i spacji w tablicy).
bool matchesVehicle(Map<String, dynamic> vehicle, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  final plate = '${vehicle['plate'] ?? ''}'.toLowerCase();
  return '${vehicle['name'] ?? ''}'.toLowerCase().contains(q) ||
      plate.contains(q) ||
      plate.replaceAll(' ', '').contains(q.replaceAll(' ', ''));
}

/// Kolumna tabeli: nagłówek, wartość do sortowania, komórka.
class _Column {
  const _Column(this.label, this.sortKey, this.cell, {this.numeric = false});

  final String label;
  final Comparable<dynamic>? Function(Map<String, dynamic>)? sortKey;
  final Widget Function(Map<String, dynamic>) cell;
  final bool numeric;
}

/// Tabela pojazdów (z napędem albo naczep i przyczep) z sortowaniem po kliknięciu nagłówka.
class VehiclesTable extends StatefulWidget {
  const VehiclesTable({
    super.key,
    required this.vehicles,
    required this.towed,
    required this.byId,
    required this.onOpen,
    required this.actions,
    required this.coupling,
  });

  final List<Map<String, dynamic>> vehicles;

  /// Naczepy i przyczepy (inne kolumny niż pojazdy z napędem).
  final bool towed;
  final Map<Object?, Map<String, dynamic>> byId;

  /// Dotknięcie wiersza (`null` – wiersz tylko do odczytu).
  final VoidCallback? Function(Map<String, dynamic>) onOpen;
  final Widget Function(Map<String, dynamic>) actions;

  /// Komórka podpięcia pojazdu z napędem.
  final Widget Function(Map<String, dynamic>) coupling;

  @override
  State<VehiclesTable> createState() => _VehiclesTableState();
}

class _VehiclesTableState extends State<VehiclesTable> {
  int _sortColumn = 0;
  bool _ascending = true;

  List<_Column> _columns(BuildContext context, {required bool narrow}) {
    final l = context.l;
    final scheme = Theme.of(context).colorScheme;
    String n(Object? value) => value is num ? l.number(value) : '–';
    num? number(Map<String, dynamic> v, String key) => v[key] is num ? v[key] as num : null;
    String text(Object? value) => value == null || '$value'.isEmpty ? '–' : '$value';

    final theme = Theme.of(context);
    // Pojazd: ikona w kolorze stanu, nazwa, a pod nią tablica i podpięta naczepa.
    final name = _Column(l.vehicleName, (v) => '${v['name'] ?? ''}'.toLowerCase(), (v) {
      final details = [
        if (v['plate'] != null) '${v['plate']}',
        if (v['trailer_name'] != null) '+ ${v['trailer_name']}',
      ];
      return Row(mainAxisSize: MainAxisSize.min, children: [
        IconSquare(
          icon: kindIcon(v['kind'] as String?),
          color: stateColor(context, vehicleState(v)) ?? scheme.primary,
          size: 36,
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text(v['name']), overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
            if (details.isNotEmpty)
              Text(details.join('  '),
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
        ),
      ]);
    });
    // Stan jako chip: wolny – miętowy, w użyciu – niebieski, usterka – bursztyn, naprawa – czerwony.
    final status = _Column(l.vehiclesColState, (v) => vehicleState(v).index, (v) {
      final state = vehicleState(v);
      return StatusChip(
        label: stateText(l, v) ?? l.vehicleStateFree,
        uppercase: false,
        tone: switch (state) {
          VehicleState.repair => StatusTone.error,
          VehicleState.reported => StatusTone.warning,
          VehicleState.inUse => StatusTone.info,
          VehicleState.free => StatusTone.ok,
        },
      );
    });
    // Kierowca i baza w jednej kolumnie.
    final crew = _Column(l.vehiclesColDriverBase, (v) => '${v['base_name'] ?? '~'}'.toLowerCase(), (v) {
      final driver = v['assigned_driver_name'] ?? v['driver_name'];
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.person_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text(driver), style: theme.textTheme.labelMedium),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.warehouse_outlined, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(text(v['base_name']), style: theme.textTheme.bodySmall),
        ]),
      ]);
    });
    final plate =
        _Column(l.vehiclesColPlate, (v) => '${v['plate'] ?? ''}'.toLowerCase(), (v) => Text(text(v['plate'])));
    final kind = _Column(
        l.vehicleKind, (v) => kindLabel(l, v['kind'] as String?), (v) => Text(kindLabel(l, v['kind'] as String?)));
    final next = _Column(l.vehiclesColNextDate, (v) => nextServiceDate(v)?.day, (v) {
      final date = nextServiceDate(v);
      if (date == null) return const Text('–');
      final days = date.day.difference(DateUtils.dateOnly(DateTime.now())).inDays;
      final color = days < 0 ? scheme.error : (days <= dueSoonDays ? scheme.tertiary : null);
      return Tooltip(
        message: serviceDateLabel(l, date.key),
        child: Text(DateFormat.yMd(l.localeName).format(date.day), style: TextStyle(color: color)),
      );
    });
    final actions = _Column('', null, widget.actions);
    if (narrow) return [name, plate, kind, next, actions];

    final dimensions = _Column(l.vehiclesColDimensions, (v) => number(v, 'height_m'),
        (v) => Text('${n(v['height_m'])} × ${n(v['width_m'])} × ${n(v['length_m'])}'));
    final gvw = _Column(l.vehiclesColGvw, (v) => number(v, 'gvw_t'), (v) => Text(n(v['gvw_t'])), numeric: true);
    final owner = _Column(l.vehicleOwner, (v) => v['company_id'] == null ? 0 : 1,
        (v) => Text(v['company_id'] == null ? l.vehiclePrivate : l.vehicleOfCompany));

    if (widget.towed) {
      final body = _Column(l.vehicleBody, (v) => trailerLabel(l, '${v['trailer_type']}'),
          (v) => Text(trailerLabel(l, '${v['trailer_type']}')));
      return [name, plate, kind, crew, status, body, dimensions, gvw, owner, next, actions];
    }
    final coupled = _Column(
        l.vehiclesColCoupling, (v) => '${widget.byId[v['trailer_id']]?['name'] ?? ''}'.toLowerCase(), widget.coupling);
    return [name, plate, kind, crew, status, dimensions, gvw, owner, coupled, next, actions];
  }

  @override
  Widget build(BuildContext context) {
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final columns = _columns(context, narrow: narrow);
    final column = _sortColumn < columns.length ? _sortColumn : 0;
    final sortKey = columns[column].sortKey;
    final rows = [...widget.vehicles];
    if (sortKey != null) {
      // Puste wartości zawsze na końcu.
      rows.sort((a, b) {
        final x = sortKey(a), y = sortKey(b);
        if (x == null || y == null) return x == null ? (y == null ? 0 : 1) : -1;
        return _ascending ? x.compareTo(y) : y.compareTo(x);
      });
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: 88),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          sortColumnIndex: column,
          sortAscending: _ascending,
          showCheckboxColumn: false,
          columnSpacing: 24,
          dataRowMinHeight: 60,
          dataRowMaxHeight: 72,
          headingRowColor: MaterialStatePropertyAll(TruckColors.of(context).surfaceLow),
          headingTextStyle: Theme.of(context).textTheme.labelSmall,
          columns: [
            for (final (i, c) in columns.indexed)
              DataColumn(
                label: Text(c.label),
                numeric: c.numeric,
                onSort: c.sortKey == null
                    ? null
                    : (_, ascending) => setState(() {
                          _sortColumn = i;
                          _ascending = ascending;
                        }),
              ),
          ],
          rows: [
            for (final v in rows)
              DataRow(
                color: switch (stateTint(context, vehicleState(v))) {
                  final tint? => MaterialStatePropertyAll(tint),
                  null => null,
                },
                onSelectChanged: switch (widget.onOpen(v)) { final open? => (_) => open(), null => null },
                cells: [for (final c in columns) DataCell(c.cell(v))],
              ),
          ],
        ),
      ),
    );
  }
}
