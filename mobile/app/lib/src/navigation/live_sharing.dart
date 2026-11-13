import 'dart:async';

import 'package:core_sdk/core_sdk.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Zgoda kierowcy na udostępnianie pozycji firmie w trakcie jazdy – zapisana na urządzeniu.
abstract class LiveConsentStore {
  /// `null` – jeszcze nie pytano.
  Future<bool?> read();
  Future<void> write(bool allowed);
}

class SecureLiveConsentStore implements LiveConsentStore {
  const SecureLiveConsentStore([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;
  static const _key = 'truckmaps.live.consent';

  @override
  Future<bool?> read() async {
    try {
      final value = await _storage.read(key: _key);
      return value == null ? null : value == 'yes';
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(bool allowed) async {
    try {
      await _storage.write(key: _key, value: allowed ? 'yes' : 'no');
    } catch (_) {
      // Bez magazynu zapytamy przy następnej jeździe.
    }
  }
}

class MemoryLiveConsentStore implements LiveConsentStore {
  MemoryLiveConsentStore([this.value]);

  bool? value;

  @override
  Future<bool?> read() async => value;

  @override
  Future<void> write(bool allowed) async => value = allowed;
}

/// Pozycja do wysłania centrali.
class LiveFix {
  const LiveFix({
    required this.lat,
    required this.lon,
    this.speedKmh,
    this.heading,
    this.destination,
    this.remainingKm,
    this.eta,
  });

  final double lat, lon;
  final double? speedKmh, heading, remainingKm;
  final String? destination;
  final DateTime? eta;

  Map<String, dynamic> toJson({required bool driving}) => {
        'lat': lat,
        'lon': lon,
        if (speedKmh != null) 'speed_kmh': double.parse(speedKmh!.clamp(0, 250).toStringAsFixed(1)),
        if (heading != null) 'heading': heading! % 360,
        if (destination != null && destination!.isNotEmpty) 'destination': destination,
        if (remainingKm != null) 'remaining_km': double.parse(remainingKm!.toStringAsFixed(1)),
        if (eta != null) 'eta': eta!.toUtc().toIso8601String(),
        'driving': driving,
      };
}

/// Centrala & Live Map: w trakcie nawigacji pojazdem firmy aplikacja co [interval] wysyła
/// pozycję (`POST /api/vehicles/{id}/position`) – tylko za zgodą kierowcy ([ask] pyta raz,
/// odpowiedź zostaje w [consent]). Pojazd prywatny – nic nie jest wysyłane.
class LiveSharing {
  LiveSharing({
    required this.api,
    required this.vehicleId,
    required this.consent,
    required this.ask,
    required this.current,
    this.interval = const Duration(seconds: 30),
  });

  final CoreApi api;
  final String vehicleId;
  final LiveConsentStore consent;
  final Future<bool> Function() ask;
  final LiveFix? Function() current;
  final Duration interval;

  Timer? _timer;
  bool _active = false;

  bool get active => _active;

  /// Sprawdza pojazd i zgodę; `true` – pozycje są wysyłane.
  Future<bool> start() async {
    try {
      final vehicle = await api.get('/api/vehicles/$vehicleId');
      if (vehicle is! Map || vehicle['company_id'] == null) return false;
    } catch (_) {
      return false;
    }
    var allowed = await consent.read();
    if (allowed == null) {
      allowed = await ask();
      await consent.write(allowed);
    }
    if (!allowed) return false;
    _active = true;
    await send();
    _timer = Timer.periodic(interval, (_) => send());
    return true;
  }

  Future<void> send({bool driving = true}) async {
    final fix = current();
    if (!_active || fix == null) return;
    try {
      await api.post('/api/vehicles/$vehicleId/position', fix.toJson(driving: driving));
    } catch (_) {
      // Brak sieci – kolejna pozycja za [interval].
    }
  }

  /// Koniec jazdy: ostatnia pozycja z „zakończył jazdę”.
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    if (_active) await send(driving: false);
    _active = false;
  }
}
