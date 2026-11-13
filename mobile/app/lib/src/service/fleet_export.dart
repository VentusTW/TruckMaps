import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:url_launcher/url_launcher.dart';

import '../l10n.dart';
import 'service_data.dart';

/// Wiersze raportu floty: pojazd, przejazdy, km, godziny, puste km, postój, koszty z przejazdów
/// (w każdej walucie) i koszty serwisu – te same dane, które pokazują Raporty i TCO.
List<List<String>> fleetReportRows(AppLocalizations l, FleetData data, double Function(String vehicleId) serviceCost) {
  final currencies = <String>{
    for (final v in data.power)
      ...((data.stats['${v['id']}']?['costs'] as Map?)?.keys.map((k) => '$k') ?? const <String>[]),
  }.toList()
    ..sort();
  String n(num? value, [int decimals = 1]) => value == null ? '' : value.toStringAsFixed(decimals).replaceAll('.', ',');
  return [
    [
      l.csvVehicle, l.csvPlate, 'VIN', l.csvTrips, 'km', l.csvHours, l.csvEmptyKm, l.csvIdle, //
      for (final c in currencies) l.csvTripCost(c),
      for (final c in currencies) l.csvCostPerKm(c),
      l.csvServiceCost,
    ],
    for (final v in data.power)
      () {
        final s = data.stats['${v['id']}'];
        final costs = (s?['costs'] as Map?) ?? const {};
        final perKm = (s?['cost_per_km'] as Map?) ?? const {};
        return [
          '${v['name'] ?? ''}',
          '${v['plate'] ?? ''}',
          '${v['vin'] ?? ''}',
          '${s?['trips'] ?? 0}',
          n(s?['distance_km'] as num?),
          n(s?['hours'] as num?),
          n(s?['empty_km'] as num?),
          n(s?['idle_hours'] as num?),
          for (final c in currencies) n(costs[c] as num?, 2),
          for (final c in currencies) n(perKm[c] as num?, 2),
          n(serviceCost('${v['id']}'), 2),
        ];
      }(),
  ];
}

/// CSV (średnik, UTF-8 z BOM – Excel w polskich ustawieniach otwiera poprawnie).
String toCsv(List<List<String>> rows) {
  String cell(String v) => v.contains(RegExp(r'[;"\n]')) ? '"${v.replaceAll('"', '""')}"' : v;
  return '﻿${rows.map((r) => r.map(cell).join(';')).join('\r\n')}\r\n';
}

/// Zapis do pliku tymczasowego i otwarcie w programie systemu (Excel, LibreOffice).
Future<bool> openCsv(String csv, String name) async {
  if (kIsWeb) return false;
  final stamp = DateTime.now().toIso8601String().substring(0, 10);
  final file = File('${Directory.systemTemp.path}${Platform.pathSeparator}truckmaps-$name-$stamp.csv');
  await file.writeAsString(csv);
  return launchUrl(Uri.file(file.path));
}
