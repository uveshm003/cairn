import 'package:cairn/data/database.dart';
import 'package:cairn/settings/app_settings.dart';
import 'package:cairn/ui/capture/capture_flow.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where a quick-capture tap actually lands.
///
/// The interesting case is a collision: the home-screen widget's buttons name a
/// medium, and the remembered default type may not accept it. Getting this wrong
/// is quiet -- the app opens on the wrong medium and the user has to notice.
void main() {
  late CairnDatabase db;
  late List<EntryTypeRow> types;

  setUp(() async {
    db = CairnDatabase.forTesting(NativeDatabase.memory());
    types = await db.allTypes();
  });

  tearDown(() => db.close());

  EntryTypeRow named(String name) => types.firstWhere((t) => t.name == name);

  group('reconcileTypeWithMedium', () {
    test('leaves the preferred type alone when no medium was demanded', () {
      // The in-app FAB and the quick-settings tile both take this path.
      final howTo = named('How-to');
      expect(
        reconcileTypeWithMedium(
          preferred: howTo,
          medium: null,
          available: types,
        ).name,
        'How-to',
      );
    });

    test('leaves it alone when the type already accepts the medium', () {
      expect(
        reconcileTypeWithMedium(
          preferred: named('Practice'),
          medium: Medium.audio,
          available: types,
        ).name,
        'Practice',
      );
    });

    test('moves off a video-only type when audio was asked for', () {
      // "Audio" on the widget while How-to is the default. The tap must not
      // silently become a video capture.
      final resolved = reconcileTypeWithMedium(
        preferred: named('How-to'),
        medium: Medium.audio,
        available: types,
      );
      expect(resolved.name, isNot('How-to'));
      expect(typeAllowsMedium(resolved, Medium.audio), isTrue);
    });

    test('video is accepted by every seeded type, so nothing moves', () {
      for (final type in types) {
        expect(
          reconcileTypeWithMedium(
            preferred: type,
            medium: Medium.video,
            available: types,
          ).name,
          type.name,
        );
      }
    });

    test('falls back to the preferred type when nothing accepts the medium',
        () {
      // Degenerate, but it must not throw: capture coerces the medium to one
      // the type allows, so this still lands somewhere legal.
      final howTo = named('How-to');
      final resolved = reconcileTypeWithMedium(
        preferred: howTo,
        medium: Medium.audio,
        available: [howTo],
      );
      expect(resolved.name, 'How-to');
    });
  });

  group('remembered medium', () {
    test('defaults to video, which is what capture opened on before', () async {
      final settings = await AppSettings.load(db);
      expect(settings.preferredMedium.value, Medium.video);
    });

    test('survives a reload, so the tile and capture agree', () async {
      // The tile's whole promise is "the medium you last used"; if this did not
      // persist, the tile would silently always mean video.
      final settings = await AppSettings.load(db);
      await settings.setPreferredMedium(Medium.audio);

      final reloaded = await AppSettings.load(db);
      expect(reloaded.preferredMedium.value, Medium.audio);
    });

    test('a junk stored value falls back rather than throwing', () async {
      await db.setSetting('preferredMedium', 'holographic');
      final settings = await AppSettings.load(db);
      expect(settings.preferredMedium.value, Medium.video);
    });
  });
}
