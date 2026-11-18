import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Numer domu przy końcu trasy (`house_numbers` w odpowiedzi `/api/routes`) – serwer podaje
/// tylko kilkaset metrów przy starcie i celu, gdzie numeracja bywa nieregularna.
class HouseNumber {
  const HouseNumber(this.point, this.number, {this.street, this.atDestination = true});

  factory HouseNumber.fromJson(Map<String, dynamic> json) => HouseNumber(
        LatLng((json['lat'] as num).toDouble(), (json['lon'] as num).toDouble()),
        '${json['number']}',
        street: json['street'] as String?,
        atDestination: json['end'] != 'start',
      );

  final LatLng point;
  final String number;
  final String? street;
  final bool atDestination;
}

/// Numery domów jako małe etykiety – dopiero z bliska ([minZoom]), żeby nie zasłaniały mapy.
class HouseNumberLayer extends StatelessWidget {
  const HouseNumberLayer(this.numbers, {super.key, this.minZoom = 16});

  final List<HouseNumber> numbers;
  final double minZoom;

  @override
  Widget build(BuildContext context) {
    if (numbers.isEmpty || MapCamera.of(context).zoom < minZoom) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final style =
        Theme.of(context).textTheme.labelSmall?.copyWith(color: scheme.onSurface, fontWeight: FontWeight.w600);
    return MarkerLayer(markers: [
      for (final h in numbers)
        Marker(
          point: h.point,
          width: 48,
          height: 20,
          child: Tooltip(
            message: [h.street, h.number].whereType<String>().join(' '),
            child: Center(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Text(h.number, style: style, maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ),
            ),
          ),
        ),
    ]);
  }
}
