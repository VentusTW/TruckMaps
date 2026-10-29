import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

class Place {
  const Place(this.label, this.point);

  final String label;
  final LatLng point;
}

/// Współrzędne GPS wpisane w pole adresu, np. "50.0131, 21.0214" (z częścią dziesiętną).
Place? parseCoords(String text) {
  final match = RegExp(r'^\s*(-?\d{1,2}\.\d+)\s*[,; ]\s*(-?\d{1,3}\.\d+)\s*$').firstMatch(text);
  if (match == null) return null;
  final lat = double.parse(match.group(1)!), lon = double.parse(match.group(2)!);
  if (lat.abs() > 90 || lon.abs() > 180) return null;
  return Place('GPS $lat, $lon', LatLng(lat, lon));
}

/// Pole adresu z podpowiedziami z wyszukiwarki (`/api/geocode`) i obsługą GPS.
class PlaceField extends StatefulWidget {
  const PlaceField({
    super.key,
    required this.api,
    required this.label,
    required this.icon,
    required this.controller,
    required this.onSelected,
    this.near,
  });

  final CoreApi api;
  final String label;
  final IconData icon;
  final TextEditingController controller;
  final ValueChanged<Place> onSelected;
  final LatLng? near;

  @override
  State<PlaceField> createState() => _PlaceFieldState();
}

class _PlaceFieldState extends State<PlaceField> {
  final _focus = FocusNode();
  Timer? _debounce;

  Future<List<Place>> _search(String text) async {
    if (parseCoords(text) case final coords?) return [coords];
    if (text.trim().length < 2) return const [];
    final completer = Completer<List<Place>>();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        final near = widget.near;
        final query = Uri(queryParameters: {
          'q': text.trim(),
          if (near != null) 'lat': '${near.latitude}',
          if (near != null) 'lon': '${near.longitude}',
        }).query;
        final found = await widget.api.get('/api/geocode?$query') as List<dynamic>;
        completer.complete([
          for (final p in found.cast<Map<String, dynamic>>())
            Place(p['label'] as String, LatLng((p['lat'] as num).toDouble(), (p['lon'] as num).toDouble())),
        ]);
      } catch (_) {
        completer.complete(const []);
      }
    });
    return completer.future;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<Place>(
      textEditingController: widget.controller,
      focusNode: _focus,
      displayStringForOption: (place) => place.label,
      optionsBuilder: (value) => _search(value.text),
      onSelected: widget.onSelected,
      fieldViewBuilder: (context, controller, focusNode, onSubmitted) => TextField(
        controller: controller,
        focusNode: focusNode,
        decoration: InputDecoration(
          labelText: widget.label,
          prefixIcon: Icon(widget.icon),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => onSubmitted(),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260, maxWidth: 360),
            child: ListView(shrinkWrap: true, padding: EdgeInsets.zero, children: [
              for (final place in options)
                ListTile(dense: true, title: Text(place.label), onTap: () => onSelected(place)),
            ]),
          ),
        ),
      ),
    );
  }
}
