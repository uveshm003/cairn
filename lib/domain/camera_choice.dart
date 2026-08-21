/// Which lens to record with.
///
/// A journal is often pointed at yourself — `requirements.md` §3 lists "keep a
/// private video diary" alongside "record my guitar practice", so both lenses
/// are first-class and the choice has to be one tap and remembered.
///
/// Pure functions, deliberately: the selection rules (what to do with a device
/// that has no front camera, an external webcam, or several back lenses) are
/// where the bugs live, and none of that needs a real camera to test.
library;

import 'package:camera/camera.dart';

extension LensLabel on CameraLensDirection {
  /// For the flip button's tooltip and accessibility label.
  String get label => switch (this) {
        CameraLensDirection.front => 'Front camera',
        CameraLensDirection.back => 'Back camera',
        CameraLensDirection.external => 'External camera',
      };

  /// Persisted in settings, so it must be stable across builds.
  String get storageKey => name;

  static CameraLensDirection? fromStorage(String? raw) => switch (raw) {
        'front' => CameraLensDirection.front,
        'back' => CameraLensDirection.back,
        'external' => CameraLensDirection.external,
        _ => null,
      };
}

/// Picks a camera matching [preferred], falling back sensibly.
///
/// Order: the preferred lens, then the opposite one, then anything at all. A
/// tablet with only a front camera, or a desktop with only an external webcam,
/// still gets a working capture screen rather than an error.
///
/// Returns null only when the device genuinely has no camera.
CameraDescription? pickCamera(
  List<CameraDescription> cameras, {
  required CameraLensDirection preferred,
}) {
  if (cameras.isEmpty) return null;

  for (final direction in [
    preferred,
    // The obvious second choice is the other user-facing lens.
    preferred == CameraLensDirection.front
        ? CameraLensDirection.back
        : CameraLensDirection.front,
  ]) {
    final match = cameras.where((c) => c.lensDirection == direction);
    // `first` rather than a "best" heuristic: on phones with several back
    // lenses (wide, ultrawide, tele) the platform lists the default one first,
    // and second-guessing that produces worse framing, not better.
    if (match.isNotEmpty) return match.first;
  }
  return cameras.first;
}

/// The lens to switch to when the flip button is tapped.
///
/// Cycles through the distinct lens directions the device actually has, so a
/// device with front + back + external does not get stuck between two of them.
/// Returns null when there is nothing to switch to.
CameraLensDirection? nextLens(
  List<CameraDescription> cameras, {
  required CameraLensDirection current,
}) {
  final available = <CameraLensDirection>[];
  for (final camera in cameras) {
    if (!available.contains(camera.lensDirection)) {
      available.add(camera.lensDirection);
    }
  }
  if (available.length < 2) return null;

  final index = available.indexOf(current);
  // An unknown current lens starts the cycle rather than failing.
  if (index < 0) return available.first;
  return available[(index + 1) % available.length];
}

/// Whether to offer a flip control at all. Hidden on single-camera devices,
/// where a disabled button is just clutter.
bool canFlipCamera(List<CameraDescription> cameras) =>
    nextLens(cameras, current: CameraLensDirection.back) != null ||
    nextLens(cameras, current: CameraLensDirection.front) != null;
