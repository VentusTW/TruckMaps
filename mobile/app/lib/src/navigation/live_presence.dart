import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:latlong2/latlong.dart';

import 'corridor.dart' show bearingDeg, distanceM;
import 'live_sharing.dart';
import 'navigation_screen.dart' show GpsPositions, GpsProblem, PositionSource;

/// Wynik włączenia: działa, GPS wyłączony, brak zgody na lokalizację, pojazd prywatny / bez zgody kierowcy.
enum LiveStart { ok, gpsDisabled, gpsDenied, notShared }

/// Udostępnianie pozycji firmie także bez nawigacji: zalogowany kierowca włącza je w koncie
/// dla pojazdu firmy, a aplikacja co [interval] wysyła pozycję z GPS – dopóki działa (na Androidzie
/// także w tle, z powiadomieniem usługi lokalizacji). Jedno na całą aplikację.
class LivePresence {
  LivePresence._();

  static final instance = LivePresence._();

  static const interval = Duration(minutes: 1);

  LiveSharing? _sharing;
  PositionSource? _source;
  StreamSubscription<LatLng>? _subscription;
  String? _vehicleId;
  LatLng? _last, _previous;
  DateTime? _lastAt, _previousAt;

  /// Pojazd, którego pozycja jest udostępniana; `null` – wyłączone.
  String? get vehicleId => _vehicleId;

  /// Włącza udostępnianie pozycji pojazdu [vehicleId].
  Future<LiveStart> start(
    CoreApi api,
    String vehicleId, {
    required Future<bool> Function() ask,
    required String notificationTitle,
    required String notificationText,
    LiveConsentStore consent = const SecureLiveConsentStore(),
    PositionSource? source,
  }) async {
    await stop();
    final PositionSource positions;
    if (source != null) {
      positions = source;
    } else {
      final gps = GpsPositions();
      final problem = await gps.start(notificationTitle: notificationTitle, notificationText: notificationText);
      if (problem != null) {
        await gps.dispose();
        return problem == GpsProblem.disabled ? LiveStart.gpsDisabled : LiveStart.gpsDenied;
      }
      positions = gps;
    }
    _source = positions;
    _subscription = positions.positions.listen(_onPosition);
    final sharing = LiveSharing(
      api: api,
      vehicleId: vehicleId,
      consent: consent,
      ask: ask,
      current: _fix,
      interval: interval,
    );
    _sharing = sharing;
    if (!await sharing.start()) {
      await stop();
      return LiveStart.notShared;
    }
    _vehicleId = vehicleId;
    return LiveStart.ok;
  }

  void _onPosition(LatLng position) {
    final now = DateTime.now();
    if (_last case final last? when distanceM(last, position) >= 8) {
      _previous = last;
      _previousAt = _lastAt;
    }
    _last = position;
    _lastAt = now;
    // Pierwsza pozycja po włączeniu – od razu do centrali.
    if (_previous == null) _sharing?.send();
  }

  LiveFix? _fix() {
    final last = _last;
    if (last == null) return null;
    final previous = _previous, previousAt = _previousAt, lastAt = _lastAt;
    double? speed;
    double? heading;
    if (previous != null && previousAt != null && lastAt != null) {
      final seconds = lastAt.difference(previousAt).inMilliseconds / 1000;
      if (seconds > 0 && seconds < 600) speed = distanceM(previous, last) / seconds * 3.6;
      heading = bearingDeg(previous, last);
    }
    return LiveFix(lat: last.latitude, lon: last.longitude, speedKmh: speed, heading: heading);
  }

  Future<void> stop() async {
    await _sharing?.stop();
    _sharing = null;
    await _subscription?.cancel();
    _subscription = null;
    await _source?.dispose();
    _source = null;
    _vehicleId = null;
    _last = _previous = null;
    _lastAt = _previousAt = null;
  }
}
