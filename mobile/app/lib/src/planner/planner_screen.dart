import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../navigation/navigation_screen.dart';
import 'place_field.dart';
import 'route.dart';

/// Podkład mapy: kafelki OSM jak w planerze w przeglądarce (testy podmieniają na puste).
Widget Function() mapTiles = () => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'pl.truckmaps.truckmaps_app',
    );

/// Planowanie trasy: start, cel i punkty pośrednie (adres, GPS albo kliknięcie na mapie),
/// pojazd, godzina wyjazdu; trasa w kolorach ryzyka z ostrzeżeniami, zakazami ruchu
/// w czasie, kosztem i alternatywami – to samo API co planer w przeglądarce.
class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key, required this.api});

  final CoreApi api;

  @override
  State<PlannerScreen> createState() => _PlannerScreenState();
}

class _PlannerScreenState extends State<PlannerScreen> {
  final _map = MapController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  List<Map<String, dynamic>> _vehicles = const [];
  String? _vehicleId;
  Place? _start;
  Place? _end;
  final List<Place> _via = [];
  bool _viaMode = false;
  bool _avoid = true;
  DateTime? _departure;
  RouteResult? _result;
  int? _alternative;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadVehicles();
  }

  @override
  void dispose() {
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _loadVehicles() async {
    try {
      final list = (await widget.api.get('/api/vehicles') as List<dynamic>).cast<Map<String, dynamic>>();
      setState(() {
        _vehicles = list;
        _vehicleId = list.isEmpty ? null : list.first['id'] as String;
      });
    } catch (error) {
      setState(() => _error = '$error');
    }
  }

  Future<String> _describe(LatLng point) async {
    try {
      final place = await widget.api.get('/api/geocode/reverse?lat=${point.latitude}&lon=${point.longitude}');
      if (place is Map && place['label'] != null) return place['label'] as String;
    } catch (_) {}
    return 'GPS ${point.latitude.toStringAsFixed(5)}, ${point.longitude.toStringAsFixed(5)}';
  }

  Future<void> _onMapTap(LatLng point) async {
    final label = await _describe(point);
    setState(() {
      if (_start == null) {
        _start = Place(label, point);
        _from.text = label;
      } else if (_end == null) {
        _end = Place(label, point);
        _to.text = label;
      } else if (_viaMode) {
        _via.add(Place(label, point));
        _viaMode = false;
      } else {
        return;
      }
    });
    if (_start != null && _end != null) _calculate();
  }

  Map<String, double> _json(Place place) => {'lat': place.point.latitude, 'lon': place.point.longitude};

  String _isoLocal(DateTime d) =>
      '${d.year}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}';

  Future<void> _calculate() async {
    final vehicleId = _vehicleId, start = _start, end = _end;
    if (vehicleId == null) return setState(() => _error = 'Najpierw dodaj pojazd.');
    if (start == null || end == null) return setState(() => _error = 'Wybierz start (A) i cel (B).');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final body = await widget.api.post('/api/routes', {
        'origin': _json(start),
        'destination': _json(end),
        'via': [for (final v in _via) _json(v)],
        'vehicle_id': vehicleId,
        'avoid_difficult': _avoid,
        if (_departure != null) 'departure': _isoLocal(_departure!),
      }) as Map<String, dynamic>;
      final result = RouteResult.fromJson(body);
      setState(() {
        _result = result;
        _alternative = null;
      });
      _fit(result.route.points);
    } on ApiException catch (error) {
      // Nieaktualna trasa nie może zostać na mapie – wyglądałoby, że nic się nie zmieniło.
      setState(() => _result = null);
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Nie da się wyznaczyć trasy'),
            content: Text(error.message),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('OK'))],
          ),
        );
      }
    } catch (error) {
      setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _fit(List<LatLng> points) {
    if (points.length < 2) return;
    _map.fitCamera(CameraFit.bounds(bounds: LatLngBounds.fromPoints(points), padding: const EdgeInsets.all(48)));
  }

  void _clear() => setState(() {
        _start = _end = _result = null;
        _via.clear();
        _from.clear();
        _to.clear();
      });

  Future<void> _pickDeparture() async {
    final now = DateTime.now();
    final initial = _departure ?? now;
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(initial));
    if (time == null) return;
    setState(() => _departure = DateTime(day.year, day.month, day.day, time.hour, time.minute));
    if (_result != null) _calculate();
  }

  PlannedRoute? get _shown {
    final result = _result;
    if (result == null) return null;
    return _alternative == null ? result.route : result.alternatives[_alternative!];
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final map = _buildMap();
    if (wide) {
      return Row(children: [
        SizedBox(width: 380, child: _buildPanel()),
        const VerticalDivider(width: 1),
        Expanded(child: map),
      ]);
    }
    return Stack(children: [
      map,
      DraggableScrollableSheet(
        initialChildSize: 0.35,
        minChildSize: 0.12,
        builder: (context, scroll) => Material(
          elevation: 8,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: _buildPanel(scroll: scroll),
        ),
      ),
    ]);
  }

  Widget _buildMap() {
    final shown = _shown;
    final result = _result;
    final others = [
      if (result != null && _alternative != null) result.route,
      if (result != null)
        for (final (i, alt) in result.alternatives.indexed)
          if (i != _alternative) alt,
    ];
    return FlutterMap(
      mapController: _map,
      options: MapOptions(
        initialCenter: const LatLng(52.1, 19.1),
        initialZoom: 6,
        onTap: (_, point) => _onMapTap(point),
      ),
      children: [
        mapTiles(),
        PolylineLayer(polylines: [
          for (final alt in others)
            Polyline(points: alt.points, strokeWidth: 5, color: levelColor(alt.level).withOpacity(0.45)),
          if (shown != null)
            for (final (points, level) in shown.coloredParts)
              Polyline(
                points: points,
                strokeWidth: level == 'red' ? 7 : 5,
                color: levelColor(level),
                borderStrokeWidth: 2,
                borderColor: Colors.white,
              ),
        ]),
        MarkerLayer(markers: [
          if (shown != null)
            for (final w in shown.warnings.where((w) => w.limit != null || w.level == 'orange' || w.level == 'red'))
              _placeMarker(w),
          if (result != null)
            for (final ban in result.timeBans) _placeMarker(ban),
          if (_start != null) _stopMarker(_start!.point, 'A', const Color(0xFF185FA5)),
          if (_end != null) _stopMarker(_end!.point, 'B', const Color(0xFFA32D2D)),
          for (final (i, via) in _via.indexed)
            _stopMarker(via.point, '${i + 1}', const Color(0xFF5F5E5A), onTap: () {
              setState(() => _via.removeAt(i));
              _calculate();
            }),
        ]),
        const SimpleAttributionWidget(source: Text('© współtwórcy OpenStreetMap')),
      ],
    );
  }

  Marker _stopMarker(LatLng point, String label, Color color, {VoidCallback? onTap}) => Marker(
        point: point,
        width: 30,
        height: 30,
        child: GestureDetector(
          onTap: onTap,
          child: Tooltip(
            message: onTap == null ? label : 'Punkt pośredni $label – dotknij, żeby usunąć',
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [BoxShadow(blurRadius: 3, color: Colors.black38)],
              ),
              child: Center(
                child: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ),
      );

  Marker _placeMarker(RoutePlace place) {
    final ban = place.level == 'ban';
    return Marker(
      point: place.point,
      width: ban ? 28 : 40,
      height: ban ? 28 : 40,
      child: Tooltip(
        message: place.message,
        child: ban
            ? const Text('⛔', style: TextStyle(fontSize: 22))
            : DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  border: Border.all(color: levelColor(place.level), width: 4),
                ),
                child: Center(
                  child: Text(place.limit ?? '!',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700), textAlign: TextAlign.center),
                ),
              ),
      ),
    );
  }

  Widget _buildPanel({ScrollController? scroll}) {
    final theme = Theme.of(context);
    final result = _result;
    final shown = _shown;
    return ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
      DropdownButtonFormField<String>(
        value: _vehicleId,
        decoration: const InputDecoration(labelText: 'Pojazd', isDense: true, border: OutlineInputBorder()),
        items: [
          for (final v in _vehicles)
            DropdownMenuItem(value: v['id'] as String, child: Text('${v['name']}', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (id) {
          setState(() => _vehicleId = id);
          if (_result != null) _calculate();
        },
      ),
      const SizedBox(height: 12),
      PlaceField(
        api: widget.api,
        label: 'Skąd – adres, miejscowość, GPS',
        icon: Icons.trip_origin,
        controller: _from,
        near: _start?.point,
        onSelected: (place) {
          setState(() => _start = place);
          if (_end != null) _calculate();
        },
      ),
      const SizedBox(height: 8),
      PlaceField(
        api: widget.api,
        label: 'Dokąd – adres, miejscowość, GPS',
        icon: Icons.place_outlined,
        controller: _to,
        near: _start?.point,
        onSelected: (place) {
          setState(() => _end = place);
          if (_start != null) _calculate();
        },
      ),
      for (final (i, via) in _via.indexed)
        ListTile(
          dense: true,
          leading: CircleAvatar(radius: 12, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
          title: Text(via.label, maxLines: 2, overflow: TextOverflow.ellipsis),
          trailing: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Usuń punkt pośredni',
            onPressed: () {
              setState(() => _via.removeAt(i));
              _calculate();
            },
          ),
        ),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(
          onPressed: _pickDeparture,
          icon: const Icon(Icons.schedule),
          label: Text(_departure == null ? 'Wyjazd: teraz' : 'Wyjazd: ${_when(_departure!)}'),
        ),
        FilterChip(
          label: const Text('+ punkt pośredni na mapie'),
          selected: _viaMode,
          onSelected: _start == null || _end == null ? null : (on) => setState(() => _viaMode = on),
        ),
      ]),
      CheckboxListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        value: _avoid,
        onChanged: (on) {
          setState(() => _avoid = on ?? true);
          if (_result != null) _calculate();
        },
        title: const Text('Omijaj trudne drogi (pomarańczowe i czerwone), jeśli jest rozsądny objazd'),
      ),
      Row(children: [
        Expanded(
          child: FilledButton(
            onPressed: _busy ? null : _calculate,
            child: Text(_busy ? 'Liczę trasę…' : 'Wyznacz trasę'),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: _clear, child: const Text('Wyczyść')),
      ]),
      if (_start == null || _end == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('Wpisz adresy albo dotknij mapy: najpierw start (A), potem cel (B).',
              style: theme.textTheme.bodySmall),
        ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ),
      if (result != null && shown != null) ..._resultWidgets(result, shown),
    ]);
  }

  List<Widget> _resultWidgets(RouteResult result, PlannedRoute shown) {
    final theme = Theme.of(context);
    return [
      const Divider(height: 32),
      Text(shown.summary, style: theme.textTheme.titleMedium),
      const SizedBox(height: 8),
      FilledButton.icon(
        onPressed: _end == null || _vehicleId == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => NavigationScreen(
                    api: widget.api,
                    request: NavigationRequest(
                      vehicleId: _vehicleId!,
                      route: shown,
                      destination: _end!.point,
                      via: [for (final v in _via) v.point],
                      avoidDifficult: _avoid,
                    ),
                  ),
                )),
        icon: const Icon(Icons.navigation_outlined),
        label: const Text('Jedź – nawigacja z alarmem'),
      ),
      if (shown.cost != null) Text('koszt szacunkowo', style: theme.textTheme.bodySmall),
      const SizedBox(height: 8),
      Chip(
        avatar: CircleAvatar(backgroundColor: levelColor(shown.level), radius: 8),
        label: Text(levelTexts[shown.level] ?? 'Bez oceny'),
      ),
      for (final issue in result.issues)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(issue, style: theme.textTheme.bodySmall)),
      if (result.timeBans.isNotEmpty || result.arrival != null) ...[
        const SizedBox(height: 12),
        Text('Zakazy ruchu w czasie', style: theme.textTheme.titleSmall),
        for (final ban in result.timeBans)
          _placeTile(ban, leading: const Text('⛔', style: TextStyle(fontSize: 18))),
        if (result.arrival != null)
          Text('Przyjazd ok. ${_when(result.arrival!)}'
              '${result.waitMin > 0 ? ', w tym postój ${result.waitMin ~/ 60} h ${result.waitMin % 60} min' : ''}'
              ' (czas jazdy bez przerw kierowcy).', style: theme.textTheme.bodySmall),
        if (result.freeDeparture != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton(
              onPressed: () {
                setState(() => _departure = result.freeDeparture);
                _calculate();
              },
              child: Text('Wyjedź ${_when(result.freeDeparture!)} – bez postoju'),
            ),
          ),
      ],
      if (shown.warnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Na trasie', style: theme.textTheme.titleSmall),
        for (final w in shown.warnings)
          _placeTile(w, leading: CircleAvatar(radius: 6, backgroundColor: levelColor(w.level))),
      ],
      if (result.alternatives.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('Trasy', style: theme.textTheme.titleSmall),
        _routeChoice(result.route, null),
        for (final (i, alt) in result.alternatives.indexed) _routeChoice(alt, i),
      ],
    ];
  }

  Widget _placeTile(RoutePlace place, {required Widget leading}) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(width: 24, child: Center(child: leading)),
        title: Text('km ${place.km.toStringAsFixed(1).replaceAll('.', ',')} – ${place.message}'),
        onTap: () => _map.move(place.point, 15),
      );

  Widget _routeChoice(PlannedRoute route, int? index) => RadioListTile<int?>(
        dense: true,
        contentPadding: EdgeInsets.zero,
        value: index,
        groupValue: _alternative,
        onChanged: (value) {
          setState(() => _alternative = value);
          _fit(route.points);
        },
        secondary: CircleAvatar(radius: 6, backgroundColor: levelColor(route.level)),
        title: Text(index == null ? 'Proponowana: ${route.summary}' : 'Alternatywa ${index + 1}: ${route.summary}'),
      );
}

String _two(int n) => n.toString().padLeft(2, '0');

const _weekdays = ['pon.', 'wt.', 'śr.', 'czw.', 'pt.', 'sob.', 'niedz.'];

String _when(DateTime d) => '${_weekdays[d.weekday - 1]} ${_two(d.day)}.${_two(d.month)} ${_two(d.hour)}:${_two(d.minute)}';
