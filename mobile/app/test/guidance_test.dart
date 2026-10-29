import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:truckmaps_app/src/l10n.dart';
import 'package:truckmaps_app/src/navigation/guidance.dart';
import 'package:truckmaps_app/src/planner/route.dart';

Maneuver maneuver(int type, double km, double lengthKm, String text, {String? post}) => Maneuver(
      type: type,
      instruction: text,
      alert: text,
      pre: text,
      post: post,
      km: km,
      lengthKm: lengthKm,
      point: const LatLng(50, 21),
    );

final route = [
  maneuver(1, 0, 3, 'Jedź na wschód.'),
  maneuver(10, 3, 0.3, 'Skręć w prawo w DK94.', post: 'Podążaj prosto przez 2 km.'),
  maneuver(26, 3.3, 2.5, 'Wjedź na rondo i zjedź trzecim zjazdem.', post: 'Podążaj prosto przez 2,5 km.'),
  maneuver(4, 5.8, 0, 'Dotarłeś do celu.'),
];

void main() {
  final pl = lookupAppLocalizations(const Locale('pl'));

  test('zapowiedzi: daleko, blisko, tuż przed, po manewrze – każda raz', () {
    final guidance = Guidance(route);
    List<String> at(double m) => guidance.announce(m, pl);

    expect(at(0), ['Jedź na wschód.']);
    expect(at(100), isEmpty);
    expect(at(2000), ['Za 1 km skręć w prawo w DK94.']);
    expect(at(2100), isEmpty);
    expect(at(2710), ['Za 300 m skręć w prawo w DK94.']);
    // Rondo tuż za skrętem: bez osobnych zapowiedzi, Valhalla mówi o nim w „Następnie…”.
    expect(at(2960), ['Skręć w prawo w DK94.']);
    expect(at(3050), isEmpty);  // za skrętem, ale odcinek do ronda krótki – bez „jedź prosto”
    expect(at(3260), ['Wjedź na rondo i zjedź trzecim zjazdem.']);
    expect(at(3400), ['Podążaj prosto przez 2,5 km.']);
    expect(at(4800), ['Za 1 km dotarłeś do celu.']);
    expect(at(5500), ['Za 300 m dotarłeś do celu.']);
    expect(at(5780), ['Dotarłeś do celu.']);
    expect(at(5800), isEmpty);
  });

  test('przeskok za kilka manewrów – bez zaległych komunikatów', () {
    final guidance = Guidance(route);
    guidance.announce(0, pl);

    expect(guidance.announce(5000, pl), ['Za 800 m dotarłeś do celu.']);
  });

  test('następny manewr i odległość na ekranie', () {
    final guidance = Guidance(route, scale: 1.01);

    expect(guidance.next(0)!.maneuver.type, 10);
    expect(guidance.next(0)!.distanceM, closeTo(3030, 0.1));
    expect(guidance.next(3040)!.maneuver.type, 10);  // tuż za manewrem – jeszcze pokazany
    expect(guidance.next(3070)!.maneuver.type, 26);
    expect(guidance.next(6000), isNull);
    expect(Guidance.display(pl, 2440), '2,4 km');
    expect(Guidance.display(lookupAppLocalizations(const Locale('en')), 2440), '2.4 km');
    expect(Guidance.display(pl, 287), '290 m');
  });
}
