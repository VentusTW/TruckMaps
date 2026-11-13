import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../planner/route.dart';
import '../planner/route_review.dart';

/// Skąd kierowca rusza z trasą od dyspozytora.
enum AssignedStart { planned, myPosition }

/// Punkty trasy do wyznaczenia: od startu z trasy albo od pozycji kierowcy z dojazdem do
/// startu (start staje się pierwszym punktem „Jedź przez”).
(Map<String, dynamic>, List<Map<String, dynamic>>, List<String>) assignedStops(
    Map<String, dynamic> assignment, AssignedStart start,
    {LatLng? position}) {
  final origin = assignment['origin'] as Map<String, dynamic>;
  final via = [for (final v in assignment['via'] as List<dynamic>) v as Map<String, dynamic>];
  Map<String, dynamic> point(Map<String, dynamic> s) => {'lat': s['lat'], 'lon': s['lon']};
  if (start == AssignedStart.myPosition && position != null) {
    final stops = [origin, ...via];
    return (
      {'lat': position.latitude, 'lon': position.longitude},
      [for (final s in stops) point(s)],
      [for (final s in stops) '${s['label']}'],
    );
  }
  return (point(origin), [for (final s in via) point(s)], [for (final s in via) '${s['label']}']);
}

/// Otwiera trasę od dyspozytora: kierowca wybiera start, aplikacja wyznacza trasę jego pojazdem
/// i pokazuje przegląd z „Rozpocznij jazdę”. Trasa dostaje stan „kierowca otworzył”.
Future<void> openAssignedRoute(BuildContext context, CoreApi api, String assignmentId,
    {Future<LatLng?> Function()? locate}) async {
  final l = context.l;
  final messenger = ScaffoldMessenger.maybeOf(context);
  final navigator = Navigator.of(context);
  try {
    final assignment = await api.get('/api/route-assignments/$assignmentId') as Map<String, dynamic>;
    if (!context.mounted) return;
    final origin = assignment['origin'] as Map<String, dynamic>;
    final choice = await showDialog<AssignedStart>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l.assignedChooseStart),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, AssignedStart.planned),
            child: ListTile(
              leading: const Icon(Icons.trip_origin),
              title: Text(l.assignedFromPlanned),
              subtitle: Text('${origin['label']}'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, AssignedStart.myPosition),
            child: ListTile(
              leading: const Icon(Icons.my_location),
              title: Text(l.assignedFromMyPosition),
              subtitle: Text(l.assignedFromMyPositionHint),
            ),
          ),
        ],
      ),
    );
    if (choice == null) return;
    LatLng? position;
    if (choice == AssignedStart.myPosition) {
      position = await (locate ?? _currentPosition)();
      if (position == null) {
        messenger?.showSnackBar(SnackBar(content: Text(l.assignedNoPosition)));
        return;
      }
    }
    final (from, via, viaNames) = assignedStops(assignment, choice, position: position);
    final destination = assignment['destination'] as Map<String, dynamic>;
    final body = await api.post('/api/routes', {
      'origin': from,
      'destination': {'lat': destination['lat'], 'lon': destination['lon']},
      'via': via,
      'vehicle_id': assignment['vehicle_id'],
      'avoid_difficult': assignment['avoid_difficult'] ?? true,
    }) as Map<String, dynamic>;
    await api.post('/api/route-assignments/$assignmentId/state', {'state': 'accepted'});
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => RouteReviewScreen(
        api: api,
        result: RouteResult.fromJson(body),
        vehicleId: '${assignment['vehicle_id']}',
        vehicleHeadline: [assignment['vehicle_name'], assignment['plate']].whereType<String>().join(' · '),
        destination: LatLng((destination['lat'] as num).toDouble(), (destination['lon'] as num).toDouble()),
        via: [for (final v in via) LatLng((v['lat'] as num).toDouble(), (v['lon'] as num).toDouble())],
        viaNames: viaNames,
        avoidDifficult: assignment['avoid_difficult'] as bool? ?? true,
      ),
    ));
  } catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text('$error')));
  }
}

Future<LatLng?> _currentPosition() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) return null;
    final p = await Geolocator.getCurrentPosition().timeout(const Duration(seconds: 15));
    return LatLng(p.latitude, p.longitude);
  } catch (_) {
    return null;
  }
}
