import 'dart:math' as math;

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../navigation/corridor.dart' show distanceM;
import '../reports/report_sheet.dart';
import '../vehicles/vehicle_form.dart';
import '../vehicles/vehicle_state.dart' show vehicleHeadline;
import 'clusters.dart';
import 'country_bans_screen.dart';
import 'place_field.dart';
import 'route.dart';
import '../vehicles/permits_screen.dart';
import 'recent.dart';
import '../live/send_route.dart';
import 'route_review.dart';
import '../navigation/navigation_screen.dart';

/// Podkład mapy: kafelki OSM jak w planerze w przeglądarce (testy podmieniają na puste).
Widget Function() mapTiles = () => TileLayer(
      urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
      userAgentPackageName: 'pl.truckmaps.truckmaps_app',
    );

/// Podkład nocny (mapa wektorowa w ciemnych kolorach); `null` – nawigacja przyciemnia [mapTiles].
Widget Function()? nightMapTiles;

/// Planowanie trasy: start, cel i punkty pośrednie (adres, GPS albo kliknięcie na mapie),
/// pojazd, godzina wyjazdu; trasa w kolorach ryzyka z ostrzeżeniami, zakazami ruchu
/// w czasie, kosztem i alternatywami – to samo API co planer w przeglądarce.
/// Polecenia dla planera z innych ekranów: „zaplanuj tym pojazdem”, „powtórz ostatnią trasę”.
class PlannerController extends ChangeNotifier {
  String? _vehicleId;
  RecentRoute? _route;

  void useVehicle(String id) {
    _vehicleId = id;
    notifyListeners();
  }

  void openRoute(RecentRoute route) {
    _route = route;
    notifyListeners();
  }

  ({String? vehicleId, RecentRoute? route}) _take() {
    final taken = (vehicleId: _vehicleId, route: _route);
    _vehicleId = null;
    _route = null;
    return taken;
  }
}

class PlannerScreen extends StatefulWidget {
  const PlannerScreen({super.key, required this.api, this.vehiclesChanged, this.memory, this.controller});

  final CoreApi api;

  /// Zmiana listy pojazdów na innym ekranie – planer pobiera ją ponownie.
  final Listenable? vehiclesChanged;

  /// Ostatnie trasy i pojazd (domyślnie w pamięci – testy; aplikacja podaje magazyn urządzenia).
  final PlannerMemory? memory;
  final PlannerController? controller;

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

  /// Zaznaczone zezwolenia na przejazd; `null` – wszystkie ważne w dniu wyjazdu.
  Set<String>? _permitIds;

  /// Trasa (pojazd, start, cel), dla której już zapytano o zezwolenie – bez pytania w kółko.
  String? _permitAskedFor;
  RouteResult? _result;
  int? _alternative;
  bool _busy = false;
  String? _error;

  /// Zgłoszenia zrobione na tym ekranie (widoczne na mapie od razu, bez przeliczania trasy).
  final List<DriverReport> _myReports = [];

  /// Przeciągany punkt trasy (A, B albo pośredni) – mapa w tym czasie się nie przesuwa.
  _Drag? _drag;
  final _mapKey = GlobalKey();

  late final PlannerMemory _memory = widget.memory ?? PlannerMemory();

  /// Bazy firm użytkownika – szybki wybór startu i celu.
  List<Place> _bases = const [];

  @override
  void initState() {
    super.initState();
    _memory.addListener(_memoryChanged);
    _memory.load().then((_) => _loadVehicles());
    _loadBases();
    widget.vehiclesChanged?.addListener(_loadVehicles);
    widget.controller?.addListener(_command);
  }

  void _memoryChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadBases() async {
    try {
      final data = await widget.api.get('/api/bases');
      if (!mounted || data is! List) return;
      final bases = data.cast<Map<String, dynamic>>();
      setState(() => _bases = [
            for (final b in bases)
              Place('${b['name']}', LatLng((b['lat'] as num).toDouble(), (b['lon'] as num).toDouble())),
          ]);
    } catch (_) {
      // Bez baz – tylko ostatnie miejsca.
    }
  }

  /// Polecenie z innego ekranu (pulpit, karta pojazdu).
  void _command() {
    final (:vehicleId, :route) = widget.controller!._take();
    if (vehicleId != null && _vehicles.any((v) => v['id'] == vehicleId)) {
      setState(() => _vehicleId = vehicleId);
      _memory.setVehicle(vehicleId);
      if (_result != null) _calculate();
    }
    if (route != null) _useRoute(route);
  }

  void _useRoute(RecentRoute route) {
    setState(() {
      _start = route.from;
      _end = route.to;
      _from.text = route.from.label;
      _to.text = route.to.label;
      _via.clear();
      final usable = _vehicles.any((v) => v['id'] == route.vehicleId && v['in_repair'] != true);
      if (usable) _vehicleId = route.vehicleId;
    });
    _calculate();
  }

  /// Szybki wybór miejsca: puste „Skąd” – start, inaczej cel; z obydwoma – od razu trasa.
  void _usePlace(Place place) {
    setState(() {
      if (_start == null) {
        _start = place;
        _from.text = place.label;
      } else {
        _end = place;
        _to.text = place.label;
      }
    });
    if (_start != null && _end != null) _calculate();
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_command);
    _memory.removeListener(_memoryChanged);
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
        // Domyślnie: przydzielony mi pojazd, potem ostatnio używany, potem pierwszy sprawny.
        final usable = [for (final v in list) if (v['in_repair'] != true) v];
        if (!usable.any((v) => v['id'] == _vehicleId)) {
          final preferred = usable.where((v) => v['assigned_to_me'] == true).firstOrNull ??
              usable.where((v) => v['id'] == _memory.vehicleId).firstOrNull ??
              usable.firstOrNull;
          _vehicleId = preferred?['id'] as String?;
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
        if (_permitIds != null) 'permit_ids': _permitIds!.toList(),
      }) as Map<String, dynamic>;
      final result = RouteResult.fromJson(body);
      setState(() {
        _result = result;
        _alternative = null;
      });
      _memory.addRoute(RecentRoute(
        from: start,
        to: end,
        vehicleId: vehicleId,
        vehicleName: _vehicles.where((v) => v['id'] == vehicleId).map((v) => '${v['name']}').firstOrNull,
      ));
      _fit(result.route.points);
      _askAboutPermit(result, '$vehicleId|${start.point}|${end.point}');
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

  /// Trasa omija albo przecina miejsca z ograniczeniami pojazdu (masa, wysokość…), a żadne
  /// zezwolenie nie zostało użyte ani wybrane: pytanie „Masz zezwolenie?” – raz dla trasy.
  Future<void> _askAboutPermit(RouteResult result, String key) async {
    if (_permitIds != null || result.permitsUsed.isNotEmpty || _permitAskedFor == key) return;
    // Znaki z mapy (masa, wysokość…); na zgłoszenia kierowców nie wydaje się zezwoleń.
    bool signed(RoutePlace w) => w.limit != null && w.kind != 'reported';
    final restricted = [
      ...result.avoidedWarnings.where(signed),
      ...result.route.warnings.where((w) => signed(w) && (w.level == 'red' || w.level == 'orange')),
    ];
    if (restricted.isEmpty || !mounted) return;
    _permitAskedFor = key;
    final l = context.l;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.permitAskTitle),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(result.avoidedWarnings.isNotEmpty ? l.permitAskAvoided : l.permitAskThrough),
          const SizedBox(height: 8),
          for (final w in restricted.take(4)) Text('• ${w.message}'),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(l.permitAskNo)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(l.permitAskYes)),
        ],
      ),
    );
    if (yes == true && mounted) {
      await _pickPermits();
      if (mounted) await _calculate();
    }
  }

  /// „Mam zezwolenia”: ważne w dniu wyjazdu dla wybranego pojazdu, domyślnie wszystkie zaznaczone.
  Future<void> _pickPermits() async {
    final l = context.l;
    final day = (_departure ?? DateTime.now()).toIso8601String().substring(0, 10);
    final List<Map<String, dynamic>> permits;
    try {
      permits = (await widget.api.get('/api/permits?vehicle_id=$_vehicleId&day=$day') as List<dynamic>)
          .cast<Map<String, dynamic>>();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
      return;
    }
    if (!mounted) return;
    final chosen = {..._permitIds ?? {for (final p in permits) '${p['id']}'}};
    final result = await showDialog<Set<String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(l.permitsHave),
          content: SizedBox(
            width: 420,
            child: ListView(shrinkWrap: true, children: [
              if (permits.isEmpty) Text(l.permitsNoneValid),
              for (final p in permits)
                CheckboxListTile(
                  value: chosen.contains('${p['id']}'),
                  onChanged: (on) => setLocal(() => on == true ? chosen.add('${p['id']}') : chosen.remove('${p['id']}')),
                  title: Text('${p['number']}'),
                  subtitle: Text(permitSummary(l, p)),
                ),
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(context);
                  await Navigator.of(this.context)
                      .push(MaterialPageRoute<void>(builder: (_) => PermitsScreen(api: widget.api)));
                  if (mounted) setState(() => _permitIds = null);
                },
                icon: const Icon(Icons.edit_note),
                label: Text(l.permitsManage),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(l.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, chosen), child: Text(l.save)),
          ],
        ),
      ),
    );
    if (result == null || !mounted) return;
    setState(() => _permitIds = result.length == permits.length ? null : result);
    if (_start != null && _end != null) _calculate();
  }

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
        // Ograniczenia, zakazy i zgłoszenia: na małym przybliżeniu skupione w koła z liczbą.
        ClusteredMarkerLayer(markers: [
          if (shown != null)
            for (final w in shown.warnings.where((w) => w.limit != null || w.level == 'orange' || w.level == 'red'))
              _placeMarker(w),
          if (result != null)
            for (final ban in result.timeBans) _placeMarker(ban),
          if (result != null && _alternative == null)
            for (final w in result.avoidedWarnings) _placeMarker(w, avoided: true),
          if (result != null)
            for (final report in [...result.destinationPoints, ...result.driverReports]) _reportMarker(report),
          for (final report in _myReports) _reportMarker(report),
        ]),
        MarkerLayer(markers: [
          if (_start != null) _stopMarker(_start!.point, 'A', TruckPalette.start, stop: -1),
          if (_end != null) _stopMarker(_end!.point, 'B', TruckPalette.end, stop: -2),
          for (final (i, via) in _via.indexed)
            _stopMarker(via.point, '${i + 1}', TruckPalette.via, stop: i, onTap: () {
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

  void _startDriving(RouteResult result) => Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => NavigationScreen(
          api: widget.api,
          request: navigationRequest(
            result: result,
            alternative: _alternative,
            vehicleId: _vehicleId!,
            destination: _end!.point,
            via: [for (final v in _via) v.point],
            viaNames: [for (final v in _via) v.label],
            avoidDifficult: _avoid,
          ),
        ),
      ));

  /// Ostatnie trasy, bazy firmy i ostatnie miejsca – jedno kliknięcie zamiast wpisywania adresu.
  Widget _quickPicks(AppLocalizations l) {
    final routes = _memory.routes.take(3).toList();
    final places = [
      for (final b in _bases) (b, Icons.warehouse_outlined),
      for (final p in _memory.places)
        if (!_bases.any((b) => b.label == p.label)) (p, Icons.history),
    ].take(8).toList();
    if (routes.isEmpty && places.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final r in routes)
          ActionChip(
            avatar: const Icon(Icons.replay, size: 18),
            label: Text('${_short(r.from.label)} → ${_short(r.to.label)}'),
            onPressed: () => _useRoute(r),
          ),
        for (final (place, icon) in places)
          ActionChip(
            avatar: Icon(icon, size: 18),
            label: Text(_short(place.label)),
            tooltip: place.label,
            onPressed: () => _usePlace(place),
          ),
      ]),
    );
  }

  static String _short(String label) {
    final first = label.split(',').first.trim();
    return first.length > 28 ? '${first.substring(0, 27)}…' : first;
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
            color: delivery ? TruckPalette.start : TruckPalette.pickup,
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

  /// Znak na mapie; pod spodem dopisek „ominięto” (objazd) albo „zgłoszenie kierowców”.
  Marker _placeMarker(RoutePlace place, {bool avoided = false}) {
    final ban = place.level == 'ban';
    final note = avoided ? context.l.avoidedMark : (place.reported ? context.l.reportedMark : null);
    final sign = ban
        ? const Text('⛔', style: TextStyle(fontSize: 22))
        : SizedBox(width: 40, height: 40, child: _sign(place, dashed: avoided));
    return Marker(
      point: place.point,
      width: ban ? 28 : (note == null ? 40 : 120),
      height: ban ? 28 : (note == null ? 40 : 58),
      child: Tooltip(
        message: place.message,
        child: note == null
            ? sign
            : Column(mainAxisSize: MainAxisSize.min, children: [
                sign,
                Container(
                  margin: const EdgeInsets.only(top: 2),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
                  child: Text(note, style: const TextStyle(fontSize: 10, color: Colors.white)),
                ),
              ]),
      ),
    );
  }

  Widget _sign(RoutePlace place, {bool dashed = false}) => Opacity(
        opacity: dashed ? 0.85 : 1,
        child: DecoratedBox(
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
      );

  Widget _buildPanel({ScrollController? scroll}) {
    final theme = Theme.of(context);
    final l = context.l;
    final result = _result;
    final shown = _shown;
    return ListView(controller: scroll, padding: const EdgeInsets.all(Gap.l), children: [
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: _vehicleId,
            decoration: InputDecoration(labelText: l.vehicle, isDense: true),
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
                          (v['in_repair'] == true ? ' · ${l.vehicleInRepair}' : '') +
                          (v['assigned_to_me'] == true ? ' · ${l.plannerAssignedToYou}' : ''),
                      style: v['in_repair'] == true ? TextStyle(color: Theme.of(context).colorScheme.error) : null,
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (id) {
              setState(() => _vehicleId = id);
              _memory.setVehicle(id);
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
      if (_result == null) _quickPicks(l),
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
        OutlinedButton.icon(
          onPressed: _vehicleId == null ? null : _pickPermits,
          icon: const Icon(Icons.verified_outlined),
          label: Text(_permitIds == null ? l.permitsChoose : l.permitsChosen(_permitIds!.length)),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => CountryBansScreen(api: widget.api))),
          icon: const Icon(Icons.event_busy_outlined),
          label: Text(l.menuBans),
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
      const SizedBox(height: Gap.l),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(Gap.l),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (_vehicles.where((v) => v['id'] == _vehicleId).firstOrNull case final vehicle?)
              Padding(
                padding: const EdgeInsets.only(bottom: Gap.s),
                child: Row(children: [
                  const IconSquare(icon: Icons.local_shipping_outlined, size: 32),
                  const SizedBox(width: Gap.s),
                  Expanded(child: Text(vehicleHeadline(l, vehicle), style: theme.textTheme.labelLarge)),
                ]),
              ),
            Text(shown.summary(l), style: theme.textTheme.titleMedium),
            const SizedBox(height: Gap.s),
            Align(
              alignment: Alignment.centerLeft,
              child: StatusChip(label: l.level(shown.level), tone: _levelTone(shown.level), uppercase: false),
            ),
          ]),
        ),
      ),
      const SizedBox(height: Gap.m),
      // Od razu w drogę – przegląd trasy jest obok, nie jest obowiązkowym krokiem.
      FilledButton.icon(
        key: const Key('planner-start'),
        onPressed: _end == null || _vehicleId == null ? null : () => _startDriving(result),
        icon: const Icon(Icons.navigation_outlined),
        label: Text(l.startDriving),
      ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: _end == null || _vehicleId == null
            ? null
            : () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => RouteReviewScreen(
                    api: widget.api,
                    result: result,
                    vehicleId: _vehicleId!,
                    vehicleHeadline: _vehicles
                        .where((v) => v['id'] == _vehicleId)
                        .map((v) => vehicleHeadline(l, v))
                        .firstOrNull,
                    destination: _end!.point,
                    via: [for (final v in _via) v.point],
                    viaNames: [for (final v in _via) v.label],
                    avoidDifficult: _avoid,
                    alternative: _alternative,
                  ),
                )),
        icon: const Icon(Icons.fact_check_outlined),
        label: Text(l.routeReviewShort),
      ),
      if (_vehicles.where((v) => v['id'] == _vehicleId).firstOrNull?['company_id'] case final String companyId) ...[
        const SizedBox(height: 8),
        OutlinedButton.icon(
          key: const Key('planner-send-driver'),
          onPressed: _start == null || _end == null
              ? null
              : () => sendRouteToDriver(
                    context,
                    api: widget.api,
                    companyId: companyId,
                    vehicleId: _vehicleId!,
                    start: _start!,
                    end: _end!,
                    via: _via,
                    route: shown,
                    avoidDifficult: _avoid,
                  ),
          icon: const Icon(Icons.send_outlined),
          label: Text(l.livePlanSend),
        ),
      ],
      if (shown.cost != null) ...[
        Text([l.costEstimate, if (shown.cost!.summaryParts(l) case final parts?) parts].join(' · '),
            style: theme.textTheme.bodySmall),
        for (final line in shown.cost!.countryLines(l)) Text(line, style: theme.textTheme.bodySmall),
      ],
      for (final issue in result.issues)
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(issue, style: theme.textTheme.bodySmall)),
      if (result.timeBans.isNotEmpty || result.arrival != null) ...[
        const SizedBox(height: 12),
        Text(l.timeBansTitle, style: theme.textTheme.titleSmall),
        if (result.timeBans.isNotEmpty)
          Text(l.bansOnRoute, style: theme.textTheme.bodySmall?.copyWith(color: levelColor('red'))),
        for (final ban in result.timeBans) _placeTile(ban, leading: const Text('⛔', style: TextStyle(fontSize: 18))),
        Wrap(spacing: 8, children: [
          for (final country in result.banCountries)
            TextButton.icon(
              icon: const Icon(Icons.event_busy_outlined, size: 18),
              label: Text(l.bansShowCountry(country)),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => CountryBansScreen(api: widget.api, country: country))),
            ),
        ]),
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
      if (result.avoidedWarnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.avoidedTitle, style: theme.textTheme.titleSmall),
        for (final w in result.avoidedWarnings)
          _placeTile(w, leading: CircleAvatar(radius: 6, backgroundColor: levelColor(w.level))),
      ],
      if (result.driverWarnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.driverWarningsTitle, style: theme.textTheme.titleSmall),
        for (final w in result.driverWarnings)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.badge_outlined, color: theme.colorScheme.error),
            title: Text(w),
          ),
      ],
      if (shown.warnings.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text(l.onRouteTitle, style: theme.textTheme.titleSmall),
        for (final w in shown.warnings)
          _placeTile(w, leading: CircleAvatar(radius: 6, backgroundColor: placeColor(w))),
        if (identical(shown, result.route) && result.permitsUsed.isNotEmpty)
          Text(l.permitsUsed(result.permitsUsed.join(', ')),
              style: theme.textTheme.bodySmall?.copyWith(color: permittedColor)),
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

/// Ocena trasy jako znaczenie chipa stanu.
StatusTone _levelTone(String? level) => switch (level) {
      'green' || 'lime' => StatusTone.ok,
      'yellow' || 'orange' => StatusTone.warning,
      'red' => StatusTone.error,
      _ => StatusTone.neutral,
    };
