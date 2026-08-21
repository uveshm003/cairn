import 'package:cairn/domain/camera_choice.dart';
import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lens selection has to behave on devices that are not a normal phone: a
/// tablet with only a front camera, a desktop with only a webcam, a phone with
/// three back lenses. None of that needs a real camera to test, and all of it is
/// where the bugs would be.
CameraDescription cam(String name, CameraLensDirection direction) =>
    CameraDescription(
      name: name,
      lensDirection: direction,
      sensorOrientation: 90,
    );

void main() {
  final front = cam('front', CameraLensDirection.front);
  final back = cam('back', CameraLensDirection.back);
  final backTele = cam('back-tele', CameraLensDirection.back);
  final backWide = cam('back-wide', CameraLensDirection.back);
  final external = cam('usb', CameraLensDirection.external);

  group('pickCamera', () {
    test('honours the preferred lens', () {
      expect(
        pickCamera([back, front], preferred: CameraLensDirection.front),
        front,
      );
      expect(
        pickCamera([back, front], preferred: CameraLensDirection.back),
        back,
      );
    });

    test('order in the list does not change the answer', () {
      for (final list in [
        [front, back],
        [back, front],
      ]) {
        expect(pickCamera(list, preferred: CameraLensDirection.front), front);
      }
    });

    test('falls back to the opposite lens when the preferred one is absent',
        () {
      // A tablet with only a front camera must still open capture.
      expect(
        pickCamera([front], preferred: CameraLensDirection.back),
        front,
      );
      expect(
        pickCamera([back], preferred: CameraLensDirection.front),
        back,
      );
    });

    test('falls back to anything at all rather than failing', () {
      // A desktop with only a USB webcam.
      expect(
        pickCamera([external], preferred: CameraLensDirection.front),
        external,
      );
    });

    test('takes the first of several lenses in the same direction', () {
      // Phones list the default back lens first; picking a "better" one by
      // heuristic gives worse framing, not better.
      expect(
        pickCamera([back, backTele, backWide],
            preferred: CameraLensDirection.back),
        back,
      );
    });

    test('returns null only when there is genuinely no camera', () {
      expect(pickCamera([], preferred: CameraLensDirection.back), isNull);
    });
  });

  group('nextLens', () {
    test('flips between front and back', () {
      expect(
        nextLens([back, front], current: CameraLensDirection.back),
        CameraLensDirection.front,
      );
      expect(
        nextLens([back, front], current: CameraLensDirection.front),
        CameraLensDirection.back,
      );
    });

    test('is null when there is nothing to flip to', () {
      expect(nextLens([back], current: CameraLensDirection.back), isNull);
      // Several lenses, but all facing the same way, is still nothing to flip.
      expect(
        nextLens([back, backTele, backWide], current: CameraLensDirection.back),
        isNull,
      );
      expect(nextLens([], current: CameraLensDirection.back), isNull);
    });

    test('cycles through three directions without getting stuck', () {
      final cameras = [back, front, external];
      var lens = CameraLensDirection.back;
      final visited = <CameraLensDirection>[lens];
      for (var i = 0; i < 3; i++) {
        lens = nextLens(cameras, current: lens)!;
        visited.add(lens);
      }
      // Visits all three, then returns to the start.
      expect(visited.toSet(), {
        CameraLensDirection.back,
        CameraLensDirection.front,
        CameraLensDirection.external,
      });
      expect(visited.last, CameraLensDirection.back);
    });

    test('a current lens that is not present starts the cycle', () {
      // Can happen if the remembered lens was removed (unplugged webcam).
      expect(
        nextLens([back, front], current: CameraLensDirection.external),
        isNotNull,
      );
    });
  });

  group('canFlipCamera', () {
    test('true only when two directions exist', () {
      expect(canFlipCamera([back, front]), isTrue);
      expect(canFlipCamera([back, external]), isTrue);
      expect(canFlipCamera([back]), isFalse);
      expect(canFlipCamera([back, backTele]), isFalse);
      expect(canFlipCamera([]), isFalse);
    });
  });

  group('persistence', () {
    test('round-trips through storage', () {
      for (final lens in CameraLensDirection.values) {
        expect(LensLabel.fromStorage(lens.storageKey), lens);
      }
    });

    test('unknown or missing stored values fall back to null', () {
      // A value written by a different build must not crash startup.
      expect(LensLabel.fromStorage(null), isNull);
      expect(LensLabel.fromStorage(''), isNull);
      expect(LensLabel.fromStorage('periscope'), isNull);
    });

    test('every direction has a human label', () {
      for (final lens in CameraLensDirection.values) {
        expect(lens.label, isNotEmpty);
        expect(lens.label, isNot(contains('CameraLensDirection')));
      }
    });
  });
}
