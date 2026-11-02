import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../l10n.dart';
import '../navigation/navigation_screen.dart';
import 'planner_screen.dart' show mapTiles;
import 'route.dart';

/// Przegląd trasy przed jazdą: warianty z czasem i km na mapie, podsumowanie (dystans,
/// czas jazdy, przyjazd, opóźnienie), kraje z przejściami granicznymi, zakazy ruchu
/// w każdym kraju i „Rozpocznij jazdę”.
class RouteReviewScreen extends StatefulWidget {
  const RouteReviewScreen({
    super.key,
    required this.api,
    required this.result,
    required this.vehicleId,
    required this.destination,
    this.vehicleHeadline,
    this.via = const [],
    this.avoidDifficult = true,
    this.alternative,
  });

  final CoreApi api;
  final RouteResult result;
  final String vehicleId;
  final LatLng destination;
  final List<LatLng> via;
  final bool avoidDifficult;

  /// Np. „MAN TGX + Firanka · 40 t · 4 m”.
  final String? vehicleHeadline;

  /// Wybrany wariant: `null` – trasa proponowana, inaczej numer alternatywy.
  final int? alternative;

  @override
  State<RouteReviewScreen> createState() => _RouteReviewScreenState();
}

class _RouteReviewScreenState extends State<RouteReviewScreen> {
  late int? _alternative = widget.alternative;

  RouteResult get _result => widget.result;

  PlannedRoute get _shown => _alternative == null ? _result.route : _result.alternatives[_alternative!];

  List<(int?, PlannedRoute)> get _variants => [
        (null, _result.route),
        for (final (i, alt) in _result.alternatives.indexed) (i, alt),
      ];

  String _duration(AppLocalizations l, double minutes) => l.hoursMinutes(minutes ~/ 60, (minutes % 60).round());

  void _start() => Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
        builder: (_) => NavigationScreen(
          api: widget.api,
          request: NavigationRequest(
            vehicleId: widget.vehicleId,
            route: _shown,
            destination: widget.destination,
            via: widget.via,
            avoidDifficult: widget.avoidDifficult,
          ),
        ),
      ));

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(l.routeReviewTitle),
          if (widget.vehicleHeadline != null)
            Text(widget.vehicleHeadline!, style: Theme.of(context).textTheme.bodySmall),
        ]),
      ),
      body: LayoutBuilder(builder: (context, size) {
        final panel = _buildPanel();
        if (size.maxWidth >= 900) {
          return Row(children: [
            SizedBox(width: 400, child: panel),
            const VerticalDivider(width: 1),
            Expanded(child: _buildMap()),
          ]);
        }
        return Column(children: [
          SizedBox(height: size.maxHeight * 0.4, child: _buildMap()),
          Expanded(child: panel),
        ]);
      }),
    );
  }

  Widget _buildMap() {
    final l = context.l;
    final all = [for (final p in _result.route.points) p, for (final a in _result.alternatives) ...a.points];
    return FlutterMap(
      options: MapOptions(
        initialCenter: all.isEmpty ? const LatLng(52.1, 19.1) : all.first,
        initialZoom: 6,
        initialCameraFit: all.length < 2
            ? null
            : CameraFit.bounds(bounds: LatLngBounds.fromPoints(all), padding: const EdgeInsets.all(56)),
      ),
      children: [
        mapTiles(),
        PolylineLayer(polylines: [
          for (final (i, route) in _variants)
            if (i != _alternative)
              Polyline(points: route.points, strokeWidth: 5, color: levelColor(route.level).withOpacity(0.45)),
          for (final (points, level) in _shown.coloredParts)
            Polyline(
              points: points,
              strokeWidth: 6,
              color: levelColor(level),
              borderStrokeWidth: 2,
              borderColor: Colors.white,
            ),
        ]),
        MarkerLayer(markers: [
          for (final c in _result.countries.where((c) => c.border))
            Marker(
              point: c.point,
              width: 36,
              height: 24,
              child: Tooltip(
                message: c.name,
                child: Container(
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: Colors.black54),
                  ),
                  child: Text(c.country, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                ),
              ),
            ),
          for (final (i, route) in _variants)
            if (route.points.isNotEmpty)
              Marker(
                point: route.points[route.points.length ~/ 2],
                width: 150,
                height: 30,
                child: GestureDetector(
                  onTap: () => setState(() => _alternative = i),
                  child: Card(
                    margin: EdgeInsets.zero,
                    color: i == _alternative ? Theme.of(context).colorScheme.primaryContainer : Colors.white,
                    child: Center(
                      child: Text(
                        l.routeSummary(
                            route.distanceKm.round(), route.durationMin ~/ 60, (route.durationMin % 60).round()),
                        style: const TextStyle(fontSize: 12, color: Colors.black87),
                      ),
                    ),
                  ),
                ),
              ),
        ]),
        SimpleAttributionWidget(source: Text(l.mapAttribution)),
      ],
    );
  }

  Widget _buildPanel() {
    final l = context.l;
    final theme = Theme.of(context);
    final shown = _shown;
    final proposed = _alternative == null;
    final departure = _result.departure;
    final arrival = proposed ? _result.arrival : departure?.add(Duration(seconds: (shown.durationMin * 60).round()));
    final delay = !proposed
        ? l.reviewDelayUnknown
        : _result.waitMin > 0
            ? _duration(l, _result.waitMin.toDouble())
            : l.reviewNoDelay;
    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            Flexible(child: Text(value, textAlign: TextAlign.end, style: theme.textTheme.titleSmall)),
          ]),
        );
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (_variants.length > 1) ...[
        Text(l.routesTitle, style: theme.textTheme.titleSmall),
        for (final (i, route) in _variants)
          RadioListTile<int?>(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: i,
            groupValue: _alternative,
            onChanged: (value) => setState(() => _alternative = value),
            secondary: CircleAvatar(radius: 6, backgroundColor: levelColor(route.level)),
            title: Text(i == null ? l.routeProposed(route.summary(l)) : l.routeAlternative(i + 1, route.summary(l))),
          ),
        const Divider(height: 24),
      ],
      row(l.reviewDistance, '${shown.distanceKm.round()} km'),
      row(l.reviewDriveTime, _duration(l, shown.durationMin)),
      if (arrival != null) row(l.reviewArrival, l.when(arrival)),
      row(l.reviewDelay, delay),
      Text(l.reviewTimesNote, style: theme.textTheme.bodySmall),
      const SizedBox(height: 8),
      Chip(
        avatar: CircleAvatar(backgroundColor: levelColor(shown.level), radius: 8),
        label: Text(l.level(shown.level)),
      ),
      if (_result.countries.isNotEmpty) ...[
        const Divider(height: 24),
        Text(l.countriesTitle, style: theme.textTheme.titleSmall),
        if (!proposed) Text(l.countriesForProposed, style: theme.textTheme.bodySmall),
        for (final c in _result.countries)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(radius: 14, child: Text(c.country, style: const TextStyle(fontSize: 11))),
            title: Text(c.name),
            subtitle:
                Text(c.border ? l.borderAt(l.km(c.km), c.enterAt == null ? '–' : l.when(c.enterAt!)) : l.countryStart),
          ),
        const SizedBox(height: 8),
        Text(l.bansByCountryTitle, style: theme.textTheme.titleSmall),
        for (final c in _result.countries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(children: [
              SizedBox(width: 28, child: Text(_banIcon(c.bans), style: const TextStyle(fontSize: 16))),
              Expanded(
                child: Text(
                  l.countryBanSummary(c.name, c.summary),
                  style: c.bans == 'ban' ? TextStyle(color: theme.colorScheme.error) : null,
                ),
              ),
            ]),
          ),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _start,
        icon: const Icon(Icons.navigation_outlined),
        label: Text(l.startDriving),
      ),
    ]);
  }
}

String _banIcon(String bans) => switch (bans) {
      'ban' => '⛔',
      'no_data' => '❔',
      _ => '✅',
    };
