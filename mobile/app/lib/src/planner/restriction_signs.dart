import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Od tego przybliżenia mapa pokazuje znaki ograniczeń (serwer i tak oddaje tylko mały obszar).
const signsMinZoom = 10.0;

/// Znak ograniczenia z bazy (`GET /api/map/signs`).
class RestrictionSign {
  const RestrictionSign(this.kind, this.value, this.point);

  factory RestrictionSign.fromJson(Map<String, dynamic> json) => RestrictionSign(
        json['kind'] as String,
        (json['value'] as num).toDouble(),
        LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
      );

  final String kind;
  final double value;
  final LatLng point;

  /// Tekst na znaku: „12t”, „3,5m”, „11,5t” (nacisk osi).
  String get label {
    final number =
        value == value.roundToDouble() ? value.toStringAsFixed(0) : value.toStringAsFixed(1).replaceAll('.', ',');
    return switch (kind) {
      'height' || 'width' => '${number}m',
      _ => '${number}t',
    };
  }
}

/// Warstwa mapy: znaki ograniczeń masy, nacisku osi, wysokości i szerokości także poza trasą
/// (czerwone koło jak znak drogowy). Wczytuje widoczny fragment po zatrzymaniu przesuwania.
class RestrictionSignsLayer extends StatefulWidget {
  const RestrictionSignsLayer({super.key, required this.api});

  final CoreApi api;

  @override
  State<RestrictionSignsLayer> createState() => _RestrictionSignsLayerState();
}

class _RestrictionSignsLayerState extends State<RestrictionSignsLayer> {
  List<RestrictionSign> _signs = const [];
  LatLngBounds? _loaded;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _schedule(LatLngBounds visible) {
    final loaded = _loaded;
    if (loaded != null && loaded.contains(visible.northWest) && loaded.contains(visible.southEast)) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () => _load(visible));
  }

  Future<void> _load(LatLngBounds visible) async {
    // Z zapasem dookoła – małe przesunięcia nie pytają serwera ponownie.
    final dLat = (visible.north - visible.south) * 0.25, dLon = (visible.east - visible.west) * 0.25;
    final area = LatLngBounds(
        LatLng(visible.south - dLat, visible.west - dLon), LatLng(visible.north + dLat, visible.east + dLon));
    try {
      final list = await widget.api.get('/api/map/signs?min_lat=${area.south}&min_lon=${area.west}'
          '&max_lat=${area.north}&max_lon=${area.east}') as List<dynamic>;
      if (!mounted) return;
      setState(() {
        _signs = [for (final s in list) RestrictionSign.fromJson(s as Map<String, dynamic>)];
        _loaded = area;
      });
    } catch (_) {
      // Bez sieci – mapa bez znaków.
    }
  }

  @override
  Widget build(BuildContext context) {
    final camera = MapCamera.of(context);
    if (camera.zoom < signsMinZoom) return const SizedBox.shrink();
    _schedule(camera.visibleBounds);
    return MarkerLayer(markers: [
      for (final sign in _signs) Marker(point: sign.point, width: 38, height: 38, child: RestrictionSignIcon(sign)),
    ]);
  }
}

/// Znak drogowy: białe koło z czerwoną obwódką i wartością.
class RestrictionSignIcon extends StatelessWidget {
  const RestrictionSignIcon(this.sign, {super.key});

  final RestrictionSign sign;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: sign.label,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFD32F2F), width: 4),
            boxShadow: const [BoxShadow(color: Color(0x40000000), blurRadius: 3)],
          ),
          alignment: Alignment.center,
          child: FittedBox(
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Text(sign.label,
                  style: const TextStyle(fontWeight: FontWeight.w800, color: Color(0xFF111111), fontSize: 13)),
            ),
          ),
        ),
      );
}
