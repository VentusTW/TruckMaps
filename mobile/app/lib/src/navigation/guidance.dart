import '../l10n.dart';
import '../planner/route.dart';

/// Kiedy mówić: zapowiedź daleka (ok. 1 km, na długim odcinku), bliska (ok. 300 m)
/// i tuż przed manewrem. Odległości liczone po linii trasy.
const farAlertM = 1000.0;
const nearAlertM = 300.0;
const preM = 60.0;

/// Po manewrze „jedź prosto przez …” tylko przed długim odcinkiem.
const postMinKm = 2.0;

/// Manewr minięty o tyle – nie mówimy już o nim (np. przeskok symulacji, przeliczona trasa).
const passedM = 30.0;

/// „Jedź prosto przez …” mówimy do tej odległości za manewrem.
const postWindowM = 300.0;

/// Następny manewr i odległość do niego.
class NextManeuver {
  const NextManeuver(this.maneuver, this.distanceM);

  final Maneuver maneuver;
  final double distanceM;
}

/// Prowadzenie po manewrach trasy: co pokazać i co powiedzieć przy danej pozycji na trasie.
///
/// [scale] przelicza kilometry Valhalli na metry linii trasy, po której liczona jest
/// pozycja (długości mogą się nieco różnić po dopasowaniu linii do mapy).
class Guidance {
  Guidance(this.maneuvers, {this.scale = 1});

  final List<Maneuver> maneuvers;
  final double scale;
  final _spoken = <(int, String)>{};

  double alongOf(int i) => maneuvers[i].km * 1000 * scale;

  /// Pierwszy manewr przed pozycją (pomijając start).
  NextManeuver? next(double alongM) {
    for (var i = 1; i < maneuvers.length; i++) {
      final distance = alongOf(i) - alongM;
      if (distance > -passedM) return NextManeuver(maneuvers[i], distance < 0 ? 0 : distance);
    }
    return null;
  }

  /// Komunikaty do powiedzenia teraz (każdy najwyżej raz).
  List<String> announce(double alongM, AppLocalizations l) {
    final out = <String>[];
    void say(int i, String kind, String? text) {
      if (text != null && text.isNotEmpty && _spoken.add((i, kind))) out.add(text);
    }

    if (maneuvers.isEmpty) return out;
    // Start trasy: kierunek jazdy, póki pierwszy manewr jest jeszcze przed nami.
    if (maneuvers.length < 2 || alongM < alongOf(1) - preM) say(0, 'pre', maneuvers.first.pre);
    for (var i = 1; i < maneuvers.length; i++) {
      final m = maneuvers[i], distance = alongOf(i) - alongM;
      final before = alongOf(i) - alongOf(i - 1);
      if (distance < 0) {
        // Minięty: o nim już nie mówimy; przed długim odcinkiem – „jedź prosto przez …”.
        _spoken.addAll([(i, 'far'), (i, 'near'), (i, 'pre')]);
        if (distance > -postWindowM && m.lengthKm >= postMinKm) say(i, 'post', m.post);
        continue;
      }
      if (distance <= preM) {
        _spoken.addAll([(i, 'far'), (i, 'near')]);
        say(i, 'pre', m.pre ?? m.instruction);
      } else if (distance <= nearAlertM && before > nearAlertM * 2) {
        _spoken.add((i, 'far'));
        say(i, 'near', l.voiceIn(_distance(l, distance), _lower(m.alert ?? m.instruction)));
      } else if (distance <= farAlertM && distance > nearAlertM * 2 && before > farAlertM * 2) {
        say(i, 'far', l.voiceIn(_distance(l, distance), _lower(m.alert ?? m.instruction)));
      }
      if (distance > farAlertM) break;
    }
    return out;
  }

  static String _lower(String text) => text.isEmpty ? text : text[0].toLowerCase() + text.substring(1);

  /// Odległość do powiedzenia: do 1 km co 50 m, dalej w kilometrach co 0,5 km.
  static String _distance(AppLocalizations l, double meters) {
    if (meters < 950) return l.distanceMeters((meters / 50).round() * 50);
    return l.distanceKm(l.number((meters / 500).round() / 2, decimals: 1));
  }

  /// Odległość do pokazania przy manewrze: metry co 10 m, od 1 km z jednym miejscem po przecinku.
  static String display(AppLocalizations l, double meters) {
    if (meters < 1000) return l.distanceMeters((meters / 10).round() * 10);
    return l.distanceKm(l.number(meters / 1000, decimals: 1));
  }
}
