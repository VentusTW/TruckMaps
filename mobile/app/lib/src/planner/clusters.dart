import 'dart:math' as math;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Punkty bliżej siebie niż [cellPx] pikseli przy danym przybliżeniu → jedna grupa
/// (siatka w pikselach Web Mercator; grupy jako indeksy punktów, w kolejności pierwszego punktu).
List<List<int>> clusterIndices(List<LatLng> points, double zoom, {double cellPx = 56}) {
  final scale = 256 * math.pow(2, zoom);
  final cells = <(int, int), List<int>>{};
  for (final (i, p) in points.indexed) {
    final x = (p.longitude + 180) / 360 * scale;
    final lat = p.latitude.clamp(-85.0, 85.0) * math.pi / 180;
    final y = (1 - math.log(math.tan(lat) + 1 / math.cos(lat)) / math.pi) / 2 * scale;
    cells.putIfAbsent(((x / cellPx).floor(), (y / cellPx).floor()), () => []).add(i);
  }
  return cells.values.toList();
}

/// Znaczniki skupiane na małym przybliżeniu: koło z liczbą (dotknięcie przybliża mapę);
/// od [maxZoom] – wszystkie osobno.
class ClusteredMarkerLayer extends StatelessWidget {
  const ClusteredMarkerLayer(
      {super.key, required this.markers, this.maxZoom = 14, this.color = TruckPalette.start});

  final List<Marker> markers;
  final double maxZoom;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (camera.zoom >= maxZoom || markers.length < 2) return MarkerLayer(markers: markers);
    final groups = clusterIndices([for (final m in markers) m.point], camera.zoom);
    return MarkerLayer(markers: [
      for (final group in groups)
        if (group.length == 1)
          markers[group.first]
        else
          Marker(
            point: _center([for (final i in group) markers[i].point]),
            width: 34,
            height: 34,
            child: GestureDetector(
              onTap: () => MapController.of(context).fitCamera(CameraFit.bounds(
                bounds: LatLngBounds.fromPoints([for (final i in group) markers[i].point]),
                padding: const EdgeInsets.all(64),
                maxZoom: maxZoom + 1,
              )),
              child: CircleAvatar(
                backgroundColor: color,
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: Colors.white,
                  child: Text('${group.length}', style: TextStyle(color: color, fontWeight: FontWeight.w800)),
                ),
              ),
            ),
          ),
    ]);
  }

  static LatLng _center(List<LatLng> points) => LatLng(
        points.map((p) => p.latitude).reduce((a, b) => a + b) / points.length,
        points.map((p) => p.longitude).reduce((a, b) => a + b) / points.length,
      );
}
