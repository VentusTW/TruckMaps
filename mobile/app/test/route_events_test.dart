import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/l10n.dart';
import 'package:truckmaps_app/src/navigation/guidance.dart';
import 'package:truckmaps_app/src/navigation/route_events.dart';
import 'package:truckmaps_app/src/planner/route.dart';

void main() {
  final pl = lookupAppLocalizations(const Locale('pl'));
  // Linia na wschód: 0,01° długości na 50° ≈ 715 m.
  final line = [for (var i = 0; i <= 4; i++) LatLng(50, 20 + i * 0.01)];

  test('ograniczenia prędkości po metrach trasy i zapowiedź zmiany', () {
    final limits = SpeedLimits(line, const [SpeedLimit(0, 2, 90, posted: 90), SpeedLimit(2, 4, 50, posted: 50)]);
    expect(limits.at(100)?.kmh, 90);
    expect(limits.at(1500)?.kmh, 50);
    final change = limits.nextChange(1000)!;
    expect(change.$1, 50);
    expect(change.$2, closeTo(430, 5));
    expect(limits.nextChange(500), isNull); // zmiana dalej niż 500 m
    expect(overLimit(54, 50), isTrue);
    expect(overLimit(52, 50), isFalse);
  });

  test('prędkość z kolejnych pozycji', () {
    final meter = SpeedMeter();
    final start = DateTime(2026, 11, 2, 12);
    expect(meter.add(line[0], start), isNull);
    // 715 m w 30 s ≈ 86 km/h.
    expect(meter.add(line[1], start.add(const Duration(seconds: 30))), closeTo(85.8, 1));
  });

  test('zmrok: noc o północy, dzień w południe, ciemno po zachodzie', () {
    const warsaw = LatLng(52.23, 21.01);
    expect(isDark(DateTime.utc(2026, 11, 2, 23), warsaw), isTrue);
    expect(isDark(DateTime.utc(2026, 11, 2, 11), warsaw), isFalse);
    // 2 listopada słońce zachodzi w Warszawie ok. 15:20 UTC.
    expect(isDark(DateTime.utc(2026, 11, 2, 16, 30), warsaw), isTrue);
    expect(isDark(DateTime.utc(2026, 11, 2, 14), warsaw), isFalse);
  });

  test('zdarzenia na trasie po kolei, odcinki i punkty pośrednie', () {
    final route = PlannedRoute.fromJson({
      'distance_km': 2.9,
      'duration_min': 4.0,
      'geometry': [
        for (final p in line) [p.longitude, p.latitude],
      ],
      'analysis': null,
      'road_events': [
        {'kind': 'no_overtaking', 'km': 0.2, 'end_km': 1.0, 'lat': 50, 'lon': 20.003},
        {'kind': 'speed_camera', 'km': 1.5, 'lat': 50, 'lon': 20.021, 'speed_kmh': 70},
      ],
    });
    final events = navEvents(
      route: route,
      lengthM: 2860,
      via: [line[3]],
      destination: line.last,
      alongOf: (p) => (p.longitude - 20) / 0.01 * 715,
    );
    expect([for (final e in events) e.kind], ['no_overtaking', 'speed_camera', 'via', 'destination']);
    expect(events.first.covers(500), isTrue);
    expect([for (final e in upcoming(events, 1200, withinM: 1000)) e.kind], ['speed_camera', 'via']);
  });

  test('numer drogi na tarczy i nazwa ulicy', () {
    const m = Maneuver(
      type: 10,
      instruction: 'Skręć w prawo',
      km: 1,
      lengthKm: 1,
      point: LatLng(50, 20),
      streetNames: ['DK 94', 'Krakowska'],
    );
    expect(roadRef(m), 'DK94');
    expect(streetName(m), 'Krakowska');
  });

  test('zapowiedzi wcześniej przy większej prędkości', () {
    final guidance = Guidance(const [
      Maneuver(type: 1, instruction: 'Start', pre: 'Start', km: 0, lengthKm: 5, point: LatLng(50, 20)),
      Maneuver(type: 10, instruction: 'Zjedź', alert: 'Zjedź', km: 5, lengthKm: 1, point: LatLng(50, 20)),
      Maneuver(type: 4, instruction: 'Cel', km: 6, lengthKm: 0, point: LatLng(50, 20)),
    ]);
    guidance.announce(0, pl);
    // 90 km/h: daleka zapowiedź już 1,5 km przed manewrem (przy 50 km/h dopiero od 1 km).
    expect(guidance.announce(3500, pl, speedKmh: 90), ['Za 1,5 km zjedź']);
    expect(speedFactor(null), 1);
    expect(speedFactor(20), minSpeedFactor);
  });
}
