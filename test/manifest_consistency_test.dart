import 'dart:io';

import 'package:cairn/domain/encoding_profile.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards a pair of settings that live in two different files and *must* agree.
///
/// The bug this exists to prevent was real and severe: the manifest stripped
/// `FOREGROUND_SERVICE` while `EncodingProfile.videoConfig` set
/// `keepAliveInBackground: true`. `flutter_compress`'s guide says a stripped
/// permission "does not crash the encode" — on Android 14+ that is wrong. Its
/// service calls `startForeground()` unconditionally, the resulting
/// `SecurityException` propagates out of `onStartCommand`, and the app dies on
/// **every video save**. Nothing but a real recording on a real device found it,
/// which is exactly why it deserves a cheap static check.
void main() {
  final manifest =
      File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  /// True when the manifest removes [permission] via `tools:node="remove"`.
  ///
  /// Matches across the line break the formatter inserts between the name and
  /// the tools attribute.
  bool isStripped(String permission) {
    final pattern = RegExp(
      r'<uses-permission\s+android:name="android\.permission\.' +
          RegExp.escape(permission) +
          r'"\s*\n?\s*tools:node="remove"',
      multiLine: true,
    );
    return pattern.hasMatch(manifest);
  }

  bool isDeclared(String permission) => RegExp(
        r'<uses-permission\s+android:name="android\.permission\.' +
            RegExp.escape(permission) +
            r'"\s*/>',
      ).hasMatch(manifest);

  group('foreground service', () {
    test('every profile agrees with the manifest about background encoding',
        () {
      final stripped = isStripped('FOREGROUND_SERVICE');
      final wantsBackground = EncodingProfile.ladder
          .any((p) => p.videoConfig.keepAliveInBackground);

      expect(
        wantsBackground && stripped,
        isFalse,
        reason: 'A profile sets keepAliveInBackground: true while the manifest '
            'strips FOREGROUND_SERVICE. On Android 14+ the plugin\'s service '
            'throws SecurityException in onStartCommand and crashes the app on '
            'every video save. Either restore the permission or set the flag '
            'to false — never one without the other.',
      );
    });

    test('the companion permissions are stripped as a set', () {
      // Restoring only some of the three produces the same crash in a subtler
      // way: Android 14+ requires the typed permission as well.
      final all = [
        'FOREGROUND_SERVICE',
        'FOREGROUND_SERVICE_DATA_SYNC',
        'POST_NOTIFICATIONS',
      ];
      final stripped = all.where(isStripped).toList();
      expect(
        stripped.length,
        anyOf(0, all.length),
        reason: 'Foreground-service permissions must be all stripped or all '
            'present. Currently stripped: $stripped',
      );
    });
  });

  group('offline promise', () {
    test('INTERNET is never declared', () {
      // Principle #1. Flutter adds it to the debug and profile manifests for
      // hot reload; it must never appear in the one that ships.
      expect(isDeclared('INTERNET'), isFalse);
      expect(manifest.contains('android.permission.INTERNET'), isFalse,
          reason: 'the release manifest must not mention INTERNET at all');
    });

    test('network permissions that arrive via Media3 are stripped', () {
      // These come transitively from flutter_compress and video_player. A Play
      // listing showing network access beside a "no cloud" promise undermines
      // the whole pitch.
      expect(isStripped('ACCESS_NETWORK_STATE'), isTrue);
      expect(isStripped('WAKE_LOCK'), isTrue);
    });
  });

  group('declared permissions', () {
    test('location is coarse only, and opt-in', () {
      // §5: location off by default. Asking for FINE would claim more than the
      // feature needs.
      expect(isDeclared('ACCESS_COARSE_LOCATION'), isTrue);
      expect(manifest.contains('ACCESS_FINE_LOCATION'), isFalse,
          reason: 'an entry wants roughly where, not lane-level accuracy');
    });

    test('no permission is both declared and stripped', () {
      // A contradiction here resolves in a way that depends on merge order,
      // which is not something to leave to chance.
      final names = RegExp(r'android\.permission\.([A-Z_]+)')
          .allMatches(manifest)
          .map((m) => m.group(1)!)
          .toSet();
      for (final name in names) {
        expect(isDeclared(name) && isStripped(name), isFalse,
            reason: '$name is both declared and removed');
      }
    });
  });

  group('quick capture', () {
    test('the widget and tile add no permission request', () {
      // The README states the release build ships exactly four permissions, and
      // that claim is public. A widget needs none; the tile's
      // BIND_QUICK_SETTINGS_TILE is signature-level and declared *on the
      // service* (it constrains who may bind to it) rather than requested by
      // the app -- so it must never appear as a uses-permission.
      expect(isDeclared('BIND_QUICK_SETTINGS_TILE'), isFalse,
          reason: 'a signature-level bind permission must not be requested');
      expect(
        manifest.contains('android:permission="android.permission.'
            'BIND_QUICK_SETTINGS_TILE"'),
        isTrue,
        reason: 'without it, any app could bind the tile service',
      );
    });

    test('exactly the expected permissions are requested', () {
      // Pinned as a set rather than individually: the failure mode worth
      // catching is a *new* permission appearing, which no per-permission
      // assertion would notice.
      final declared = RegExp(
        r'<uses-permission\s+android:name="android\.permission\.([A-Z_]+)"'
        r'\s*/>',
      ).allMatches(manifest).map((m) => m.group(1)!).toSet();

      expect(
        declared,
        {'ACCESS_COARSE_LOCATION'},
        reason: 'the only permission this manifest *adds* is coarse location; '
            'READ_EXTERNAL_STORAGE and CAMERA/RECORD_AUDIO arrive from '
            'plugins. A new name here changes what the store listing shows.',
      );
    });

    test('the tile service is exported, and the widget receiver is not', () {
      // The tile must be bindable by SystemUI, so it has to be exported. The
      // widget receiver is reached through the AppWidget framework and needs
      // no external entry point -- exporting it would be a needless surface.
      expect(
        manifest.contains(RegExp(
          r'<receiver\s+android:name="\.QuickRecordWidget"\s+'
          r'android:exported="false"',
        )),
        isTrue,
      );
      expect(
        manifest.contains(RegExp(
          r'<service\s+android:name="\.QuickRecordTileService"\s+'
          r'android:exported="true"',
        )),
        isTrue,
      );
    });
  });

  group('XML validity', () {
    test('no comment contains a double hyphen', () {
      // `--` inside an XML comment is illegal and fails
      // processReleaseMainManifest with an opaque "Error parsing" — which only
      // shows up in a release build. This has bitten this file once already.
      for (final match in RegExp(r'<!--(.*?)-->', dotAll: true)
          .allMatches(manifest)) {
        final body = match.group(1)!;
        expect(body.contains('--'), isFalse,
            reason: 'illegal "--" in comment: '
                '${body.trim().split('\n').first}');
      }
    });

    test('the tools namespace is declared, since node="remove" needs it', () {
      expect(
        manifest.contains('xmlns:tools="http://schemas.android.com/tools"'),
        isTrue,
      );
    });
  });

  group('iOS', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    test('every permission the app uses has a usage description', () {
      for (final key in const [
        'NSCameraUsageDescription',
        'NSMicrophoneUsageDescription',
        'NSPhotoLibraryUsageDescription',
        'NSLocationWhenInUseUsageDescription',
      ]) {
        expect(plist.contains(key), isTrue, reason: '$key missing');
      }
    });

    test('no usage description is added on flutter_compress\'s behalf', () {
      // The plugin reads files by path and needs none. Unjustified privacy keys
      // invite App Store questions.
      expect(plist.contains('NSPhotoLibraryAddUsageDescription'), isFalse);
      expect(plist.contains('NSLocationAlwaysUsageDescription'), isFalse,
          reason: 'location is foreground-only and opt-in');
    });
  });
}
