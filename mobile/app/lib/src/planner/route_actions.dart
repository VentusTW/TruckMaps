import 'package:core_sdk/core_sdk.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import 'place_field.dart';
import 'route.dart';

/// Akcje trasy z aktywnych modułów (np. „Dokument” z modułu Dokumenty). Puste – brak modułów
/// z akcjami albo brak dostępu; planer i panel wysyłki trasy pokazują wtedy tylko swoje przyciski.
final routeActions = ValueNotifier<List<RouteAction>>(const []);

/// Akcje trasy modułów, do których konto ma dostęp (`GET /api/me/modules`).
Future<void> loadRouteActions(CoreApi api, ModuleRegistry registry) async {
  try {
    final server = [
      for (final m in await api.get('/api/me/modules') as List<dynamic>)
        ServerModule.fromJson(m as Map<String, dynamic>),
    ];
    final context = ModuleContext(api: api, userName: '');
    routeActions.value = [
      for (final access in registry.resolve(server))
        if (access.usable) ...access.module!.routeActions(context),
    ];
  } catch (_) {
    routeActions.value = const [];
  }
}

/// Trasa dla akcji modułów (zob. [RouteData]). Kraj przystanku – kraj na trasie w miejscu przystanku
/// (z [countries]); ETA – odjazd plus część czasu przejazdu do przystanku, cel – [arrival].
RouteData routeData({
  required String companyId,
  required String? vehicleId,
  required Place start,
  required Place end,
  required List<Place> via,
  required PlannedRoute route,
  List<CountryOnRoute> countries = const [],
  DateTime? departure,
  DateTime? arrival,
}) {
  final km = _kmAlong(route.points);
  final from = departure ?? DateTime.now();
  // Km punktów trasy w skali dystansu z serwera (w tej samej skali są wjazdy do krajów).
  final scale = km.isEmpty || km.last <= 0 ? 1.0 : route.distanceKm / km.last;
  double stopKm(Place p) {
    if (km.isEmpty) return 0;
    const distance = Distance();
    var best = 0;
    var bestM = double.infinity;
    for (var i = 0; i < route.points.length; i++) {
      final m = distance.as(LengthUnit.Meter, p.point, route.points[i]);
      if (m < bestM) (best, bestM) = (i, m);
    }
    return km[best] * scale;
  }

  String? country(double at) {
    String? found;
    for (final c in countries) {
      if (c.km <= at + 0.5) found = c.country;
    }
    return found;
  }

  Map<String, dynamic> stop(Place p, String type, double at, DateTime? eta) => {
        'label': p.label,
        if (country(at) case final c?) 'country': c,
        if (eta != null) 'at': eta.toUtc().toIso8601String(),
        'type': type,
      };
  DateTime eta(double at) => from.add(
      Duration(minutes: route.distanceKm <= 0 ? 0 : (route.durationMin * (at / route.distanceKm).clamp(0, 1)).round()));

  final cargo = currentCargo.value;
  final cost = route.cost;
  return {
    'company_id': companyId,
    'vehicle_id': vehicleId,
    'route': {
      'stops': [
        stop(start, 'loading', 0, from),
        for (final v in via) stop(v, 'via', stopKm(v), eta(stopKm(v))),
        stop(end, 'unloading', route.distanceKm, arrival ?? from.add(Duration(minutes: route.durationMin.round()))),
      ],
      'distance_km': route.distanceKm,
      'duration_min': route.durationMin,
      if (cost != null) 'cost_amount': cost.amount,
      if (cost != null) 'cost_currency': cost.currency,
    },
    // Plan załadunku tego pojazdu (albo bez pojazdu) – ładunek do dokumentu.
    if (cargo != null && (cargo['vehicle_id'] == null || cargo['vehicle_id'] == vehicleId))
      'cargo': {
        for (final e in cargo.entries)
          if (e.key != 'vehicle_id') e.key: e.value,
      },
  };
}

/// Km od startu w każdym punkcie trasy.
List<double> _kmAlong(List<LatLng> points) {
  const distance = Distance();
  final km = <double>[];
  var sum = 0.0;
  for (var i = 0; i < points.length; i++) {
    if (i > 0) sum += distance.as(LengthUnit.Meter, points[i - 1], points[i]) / 1000;
    km.add(sum);
  }
  return km;
}

/// Przyciski akcji trasy z modułów; nic, gdy brak akcji.
class RouteActionButtons extends StatelessWidget {
  const RouteActionButtons({super.key, required this.data});

  /// Dane trasy liczone w chwili kliknięcia.
  final RouteData Function() data;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<List<RouteAction>>(
        valueListenable: routeActions,
        builder: (context, actions, _) => actions.isEmpty
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final a in actions)
                    OutlinedButton.icon(
                      key: Key('route-action-${a.id}'),
                      onPressed: () => a.run(context, data()),
                      icon: Icon(a.icon),
                      label: Text(a.label(Localizations.localeOf(context))),
                    ),
                ]),
              ),
      );
}
