import 'dart:math' as math;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../navigation/corridor.dart' show distanceM;
import '../navigation/navigation_screen.dart';
import '../reports/report_sheet.dart';
import '../vehicles/vehicle_form.dart';
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
  const PlannerScreen({super.key, required this.api, this.vehiclesChanged});

  final CoreApi api;

  /// Zmiana listy pojazdów na innym ekranie – planer pobiera ją ponownie.
  final Listenable? vehiclesChanged;

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

  /// Zgłoszenia zrobione na tym ekranie (widoczne na mapie od razu, bez przeliczania trasy).
  final List<DriverReport> _myReports = [];

  /// Przeciągany punkt trasy (A, B albo pośredni) – mapa w tym czasie się nie przesuwa.
  _Drag? _drag;
  final _mapKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _loadVehicles();
    widget.vehiclesChanged?.addListener(_loadVehicles);
  }

  @override
  void dispose() {
    widget.vehiclesChanged?.removeListener(_loadVehicles);
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _loadVehicles() async {
    try {
      // Trasa tylko dla pojazdów jezdnych – naczepa ani przyczepa sama nie jedzie.
      final list = (await widget.api.get('/api/vehicles') as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .where(isDrivable)
          .toList();
      if (!mounted) return;
      setState(() {
        _vehicles = list;
        // Wybrany pojazd zostaje, jeśli nadal jest na liście (np. po zmianie wymiarów).
        // Pojazd w naprawie jest wyłączony z użytku – planer wybiera inny.
        final usable = [for (final v in list) if (v['in_repair'] != true) v];
        if (!usable.any((v) => v['id'] == _vehicleId)) {
          _vehicleId = usable.isEmpty ? null : usable.first['id'] as String;
        }
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

  String _isoLocal(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}T${_two(d.hour)}:${_two(d.minute)}';

  Future<void> _calculate() async {
    final vehicleId = _vehicleId, start = _start, end = _end;
    if (vehicleId == null) return setState(() => _error = context.l.addVehicleFirst);
    if (start == null || end == null) return setState(() => _error = context.l.chooseStartAndEnd);
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
            title: Text(context.l.routeFailedTitle),
            content: Text(error.message),
            actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.l.ok))],
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
      key: _mapKey,
      mapController: _map,
      options: MapOptions(
        initialCenter: const LatLng(52.1, 19.1),
        initialZoom: 6,
        interactionOptions: InteractionOptions(
          flags: _drag == null
              ? InteractiveFlag.all
              : InteractiveFlag.all & ~InteractiveFlag.drag & ~InteractiveFlag.flingAnimation,
        ),
        onTap: (_, point) => _onMapTap(point),
        onLongPress: (_, point) {
          if (_drag == null) _report(point);
        },
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
          if (result != null)
            for (final report in [...result.destinationPoints, ...result.driverReports]) _reportMarker(report),
          for (final report in _myReports) _reportMarker(report),
          if (_start != null) _stopMarker(_start!.point, 'A', const Color(0xFF185FA5), stop: -1),
          if (_end != null) _stopMarker(_end!.point, 'B', const Color(0xFFA32D2D), stop: -2),
          for (final (i, via) in _via.indexed)
            _stopMarker(via.point, '${i + 1}', const Color(0xFF5F5E5A), stop: i, onTap: () {
              setState(() => _via.removeAt(i));
              _calculate();
            }),
        ]),
        SimpleAttributionWidget(source: Text(context.l.mapAttribution)),
      ],
    );
  }

  /// Punkt trasy: [stop] -1 – start, -2 – cel, od 0 – punkt pośredni. Przeciągnięcie
  /// przesuwa punkt i liczy trasę od nowa; dotknięcie punktu pośredniego go usuwa.
  Marker _stopMarker(LatLng point, String label, Color color, {required int stop, VoidCallback? onTap}) => Marker(
        point: _drag?.stop == stop ? _drag!.point ?? point : point,
        width: 30,
        height: 30,
        child: Listener(
          onPointerDown: (event) => setState(() => _drag = _Drag(stop, event.position)),
          onPointerMove: (event) {
            final drag = _drag;
            if (drag == null || drag.stop != stop) return;
            if ((event.position - drag.downAt).distance > 6) drag.moved = true;
            if (drag.moved) setState(() => drag.point = _toLatLng(event.position));
          },
          onPointerUp: (_) => _endDrag(),
          onPointerCancel: (_) => setState(() => _drag = null),
          child: GestureDetector(
            onTap: onTap ?? () {},
            child: Tooltip(
              message: onTap == null ? context.l.stopDragHint(label) : context.l.viaTapToRemove(label),
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
        ),
      );

  LatLng _toLatLng(Offset global) {
    final box = _mapKey.currentContext!.findRenderObject()! as RenderBox;
    final local = box.globalToLocal(global);
    return _map.camera.pointToLatLng(math.Point(local.dx, local.dy));
  }

  /// Puszczony punkt: adres nowego miejsca i trasa od nowa.
  Future<void> _endDrag() async {
    final drag = _drag;
    setState(() => _drag = null);
    final point = drag?.point;
    if (drag == null || !drag.moved || point == null) return;
    final label = await _describe(point);
    if (!mounted) return;
    setState(() {
      if (drag.stop == -1) {
        _start = Place(label, point);
        _from.text = label;
      } else if (drag.stop == -2) {
        _end = Place(label, point);
        _to.text = label;
      } else if (drag.stop < _via.length) {
        _via[drag.stop] = Place(label, point);
      }
    });
    if (_start != null && _end != null) _calculate();
  }

  Future<void> _addVehicle() async {
    final saved = await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => VehicleFormScreen(api: widget.api)),
    );
    if (saved is Map && mounted) {
      await _loadVehicles();
      setState(() => _vehicleId = saved['id'] as String);
    }
  }

  Marker _reportMarker(DriverReport report) {
    final delivery = deliveryKinds.contains(report.kind);
    return Marker(
      point: report.point,
      width: 30,
      height: 30,
      child: Tooltip(
        message: report.message,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: delivery ? const Color(0xFF185FA5) : const Color(0xFFF08C00),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white, width: 2),
          ),
          child: Icon(reportIcon(report.kind), color: Colors.white, size: 18),
        ),
      ),
    );
  }

  /// Zgłoszenie w miejscu przytrzymania mapy; przy celu najpierw punkty dostawy.
  Future<void> _report(LatLng point) async {
    final end = _end;
    final nearEnd = end != null && distanceM(point, end.point) < 500;
    final saved = await showReportSheet(context, widget.api, point, deliveryFirst: nearEnd);
    if (saved == null || !mounted) return;
    setState(() => _myReports.add(saved));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.reportSaved(saved.message))));
  }

  /// Cel trasy w punkcie dostawy (np. przy rampie zamiast przy adresie firmy).
  void _driveTo(DriverReport point) {
    final end = _end;
    setState(() {
      _end = Place(end == null ? point.message : '${point.label} – ${end.label}', point.point);
      _to.text = _end!.label;
    });
    _calculate();
  }

  Future<void> _vote(DriverReport report, bool up) async {
    try {
      await voteReport(widget.api, report, up: up);
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(context.l.reportThanks)));
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Widget _reportTile(DriverReport report, {bool destination = false}) {
    final l = context.l;
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(reportIcon(report.kind)),
      title: Text(report.km != null ? l.placeAtKm(l.km(report.km!), report.message) : report.message),
      subtitle: Text([
        if (report.distanceM != null) l.distanceMeters(report.distanceM!.round()),
        l.reportConfirmations(report.score),
      ].join(' · ')),
      onTap: () => _map.move(report.point, 17),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (destination && report.kind != 'hours')
          TextButton(onPressed: () => _driveTo(report), child: Text(l.reportDriveHere)),
        if (!report.mine) ...[
          IconButton(
            tooltip: l.reportStillValid,
            icon: const Icon(Icons.thumb_up_outlined, size: 18),
            onPressed: () => _vote(report, true),
          ),
          IconButton(
            tooltip: l.reportOutdated,
            icon: const Icon(Icons.thumb_down_outlined, size: 18),
            onPressed: () => _vote(report, false),
          ),
        ],
      ]),
    );
  }

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
    final l = context.l;
    final result = _result;
    final shown = _shown;
    return ListView(controller: scroll, padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _vehicleId,
            decoration: InputDecoration(labelText: l.vehicle, isDense: true, border: const OutlineInputBorder()),
            items: [
              for (final v in _vehicles)
                DropdownMenuItem(
                  value: v['id'] as String,
                  enabled: v['in_repair'] != true,
                  child: Text(
                      [
                            v['plate'] == null ? '${v['name']}' : '${v['name']} · ${v['plate']}',
                            if (v['trailer_name'] != null) '${v['trailer_name']}',
                          ].join(' + ') +
                          (v['in_repair'] == true ? ' · ${l.vehicleInRepair}' : ''),
                      style: v['in_repair'] == true ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) {
              setState(() => _vehicleId = id);
              if (_result != null) _calculate();
            },
          ),
        ),
        IconButton(tooltip: l.vehicleAdd, icon: const Icon(Icons.add), onPressed: _addVehicle),
      ]),
      const SizedBox(height: 12),
      PlaceField(
        api: widget.api,
        label: l.fromLabel,
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
        label: l.toLabel,
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
            tooltip: l.removeVia,
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
          label: Text(_departure == null ? l.departureNow : l.departureAt(l.when(_departure!))),
        ),
        FilterChip(
          label: Text(l.addViaOnMap),
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
        title: Text(l.avoidDifficult),
      ),
      Row(children: [
        Expanded(
          child: FilledButton(
            onPressed: _busy ? null : _calculate,
            child: Text(_busy ? l.calculating : l.calculateRoute),
          ),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: _clear, child: Text(l.clear)),
      ]),
      if (_start == null || _end == null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(l.plannerHint, style: theme.textTheme.bodySmall),
        ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(l.reportLongPressHint, style: theme.textTheme.bodySmall),
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
    final l = context.l;
    return [
      const Divider(height: 32),
      Text(shown.summary(l), style: theme.textTheme.titleMedium),
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
        label: Text(l.navigateWithAlarm),
      ),
      if (shown.cost != null) Text(l.costEstimate, style: theme.textTheme.bodySmall),
      const SizedBox(height: 8),
      Chip(
        avatar: CircleAvatar(backgroundColor: levelColor(shown.level), radius: 8),
        label: Text(l.level(shown.level)),
      ),
      for (final issue in result.issues)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(issue, style: theme.textTheme.bodySmall)),
      if (result.timeBans.isNotEmpty || result.arrival != null) ...[
        const SizedBox(height: 12),
        Text(l.timeBansTitle, style: theme.textTheme.titleSmall),
        for (final ban in result.timeBans) _placeTile(ban, leading: const Text('⛔', style: TextStyle(fontSize: 18))),
        if (result.arrival != null)
          Text(
              result.waitMin > 0
                  ? l.arrivalWithWait(l.when(result.arrival!), result.waitMin ~/ 60, result.waitMin % 60)
                  : l.arrival(l.when(result.arrival!)),
              style: theme.textTheme.bodySmall),
        if (result.freeDeparture != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: OutlinedButton(
              onPressed: () {
                setState(() => _departure = result.freeDeparture);
                _calculate();
              },
              child: Text(l.departWithoutWaiting(l.when(result.freeDeparture!))),
            ),
          ),
      ],
      if (result.destinationPoints.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.atDestinationTitle, style: theme.textTheme.titleSmall),
        for (final point in result.destinationPoints) _reportTile(point, destination: true),
      ],
      if (result.driverReports.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.driverReportsTitle, style: theme.textTheme.titleSmall),
        for (final report in result.driverReports) _reportTile(report),
      ],
      if (shown.warnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.onRouteTitle, style: theme.textTheme.titleSmall),
        for (final w in shown.warnings)
          _placeTile(w, leading: CircleAvatar(radius: 6, backgroundColor: levelColor(w.level))),
      ],
      if (result.alternatives.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.routesTitle, style: theme.textTheme.titleSmall),
        _routeChoice(result.route, null),
        for (final (i, alt) in result.alternatives.indexed) _routeChoice(alt, i),
      ],
    ];
  }

  Widget _placeTile(RoutePlace place, {required Widget leading}) => ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: SizedBox(width: 24, child: Center(child: leading)),
        title: Text(context.l.placeAtKm(context.l.km(place.km), place.message)),
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
        title: Text(index == null
            ? context.l.routeProposed(route.summary(context.l))
            : context.l.routeAlternative(index + 1, route.summary(context.l))),
      );
}

String _two(int n) => n.toString().padLeft(2, '0');

class _Drag {
  _Drag(this.stop, this.downAt);

  final int stop;
  final Offset downAt;
  bool moved = false;
  LatLng? point;
}
