/// Optional location capture (requirements.md S4 lists it in the MVP; S5 makes
/// "location off by default" a non-negotiable).
///
/// Everything here is gated on the user having explicitly turned the setting on.
/// Nothing asks for a location permission, or touches the GPS, until then — for
/// a product whose pitch is privacy, that ordering is the feature.
///
/// A failure is never fatal. An entry without coordinates is fine; an entry that
/// refused to save because the GPS was slow is not.
library;

import 'package:geolocator/geolocator.dart';

class Coordinates {
  const Coordinates(this.latitude, this.longitude);

  final double latitude;
  final double longitude;
}

class LocationService {
  /// How long to wait before giving up and saving without coordinates.
  ///
  /// Short on purpose: the user is waiting on a save, and a fix that takes
  /// longer than this is not worth the delay.
  static const timeout = Duration(seconds: 6);

  /// Returns coordinates, or null for any reason at all — permission refused,
  /// services off, timeout, platform error.
  ///
  /// [enabled] is passed in rather than read here so the call site makes the
  /// opt-in explicit and this class stays testable.
  static Future<Coordinates?> tryFix({required bool enabled}) async {
    if (!enabled) return null;

    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        // Asked at first use, in context, rather than up front (S10.4).
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          // A journal entry needs "roughly where", not lane-level accuracy, and
          // a lower target returns much faster.
          accuracy: LocationAccuracy.medium,
          timeLimit: timeout,
        ),
      );
      return Coordinates(position.latitude, position.longitude);
    } catch (_) {
      // Includes the timeout. Saving without coordinates is the right outcome.
      return null;
    }
  }
}
