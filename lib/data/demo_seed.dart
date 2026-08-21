/// Development-only seeding, so the UI can be reviewed against a realistic
/// library instead of an empty one.
///
/// Enabled with a build flag rather than a hidden button, so there is no way to
/// reach it from a shipped app:
///
/// ```
/// flutter run --dart-define=CAIRN_SEED_DEMO=true
/// ```
///
/// Guarded three ways: the flag, `kDebugMode`, and "only if the library is
/// empty" — so it can never overwrite anything real.
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';

import '../media/media_store.dart';
import 'database.dart';

/// Set at build time. Const, so a release build tree-shakes the whole path away.
const seedDemoRequested = bool.fromEnvironment('CAIRN_SEED_DEMO');

/// One seeded entry. Sizes are realistic for their profile so the storage screen
/// and the space-saved stat show plausible figures.
typedef _Seed = ({
  String title,
  String? note,
  String type,
  Medium medium,
  Duration ago,
  Duration length,
  List<String> tags,
  bool favourite,
  int sizeBytes,
  int originalBytes,
});

Future<void> seedDemoDataIfRequested(
  CairnDatabase db,
  MediaStore store,
) async {
  if (!seedDemoRequested || !kDebugMode) return;

  // Never touch an existing library.
  if ((await db.allEntriesIncludingTrash()).isNotEmpty) {
    debugPrint('[demo seed] library is not empty — skipping');
    return;
  }

  // Placeholder frames, if any were pushed to the device beforehand. Absent is
  // fine: video entries then render the same placeholder audio entries do.
  final frames = <String>[];
  final pushed = Directory('/data/local/tmp/cairnthumbs');
  if (pushed.existsSync()) {
    for (final file in pushed.listSync().whereType<File>()) {
      try {
        final dest = File(
          '${store.resolve(MediaStore.thumbDirName)}/${file.uri.pathSegments.last}',
        );
        await dest.writeAsBytes(await file.readAsBytes());
        frames.add(store.relativize(dest.path));
      } catch (_) {
        // Skip an unreadable frame rather than failing the seed.
      }
    }
  }

  const seeds = <_Seed>[
    (
      title: 'Bridge idea before I lose it',
      note: 'The descending line under the chorus — try it a fourth lower.',
      type: 'Quick Note',
      medium: Medium.audio,
      ago: Duration(hours: 2),
      length: Duration(seconds: 41),
      tags: ['songwriting'],
      favourite: false,
      sizeBytes: 215040,
      originalBytes: 215040,
    ),
    (
      title: 'Travis picking, slow',
      note: 'Thumb stays on the bass strings the whole way. Still rushing the '
          'turnaround.',
      type: 'Practice',
      medium: Medium.video,
      ago: Duration(hours: 6),
      length: Duration(minutes: 12, seconds: 30),
      tags: ['guitar', 'fingerpicking'],
      favourite: true,
      sizeBytes: 43_000_000,
      originalBytes: 398_000_000,
    ),
    (
      title: 'Resetting the router properly',
      note: 'Hold for 12 seconds, not 5. Wait for the amber light.',
      type: 'How-to',
      medium: Medium.video,
      ago: Duration(days: 1, hours: 3),
      length: Duration(minutes: 2, seconds: 8),
      tags: ['house'],
      favourite: false,
      sizeBytes: 7_300_000,
      originalBytes: 67_000_000,
    ),
    (
      title: 'Long walk, thinking out loud',
      note: null,
      type: 'Diary',
      medium: Medium.audio,
      ago: Duration(days: 1, hours: 9),
      length: Duration(minutes: 4, seconds: 52),
      tags: ['walking'],
      favourite: false,
      sizeBytes: 3_400_000,
      originalBytes: 3_400_000,
    ),
    (
      title: 'She said "again" for the first time',
      note: 'Kitchen, holding the wooden spoon.',
      type: 'Diary',
      medium: Medium.video,
      ago: Duration(days: 3, hours: 5),
      length: Duration(seconds: 34),
      tags: ['family'],
      favourite: true,
      sizeBytes: 9_600_000,
      originalBytes: 101_000_000,
    ),
    (
      title: 'Scales at 80bpm',
      note: null,
      type: 'Practice',
      medium: Medium.video,
      ago: Duration(days: 4, hours: 2),
      length: Duration(minutes: 18, seconds: 4),
      tags: ['guitar', 'scales'],
      favourite: false,
      sizeBytes: 61_000_000,
      originalBytes: 545_000_000,
    ),
    (
      title: 'Reminder about the tax thing',
      note: null,
      type: 'Quick Note',
      medium: Medium.audio,
      ago: Duration(days: 6, hours: 4),
      length: Duration(seconds: 22),
      tags: ['admin'],
      favourite: false,
      sizeBytes: 122880,
      originalBytes: 122880,
    ),
    (
      title: 'Shed roof, before the rain',
      note: 'Two loose felt tiles on the north edge.',
      type: 'Freeform',
      medium: Medium.video,
      ago: Duration(days: 11),
      length: Duration(minutes: 1, seconds: 47),
      tags: ['house', 'repairs'],
      favourite: false,
      sizeBytes: 6_200_000,
      originalBytes: 60_000_000,
    ),
    (
      title: 'First run through, whole piece',
      note: null,
      type: 'Practice',
      medium: Medium.video,
      ago: Duration(days: 24),
      length: Duration(minutes: 9, seconds: 12),
      tags: ['guitar'],
      favourite: false,
      sizeBytes: 31_000_000,
      originalBytes: 302_000_000,
    ),
  ];

  final types = {for (final t in await db.allTypes()) t.name: t};
  var frameIndex = 0;

  for (final seed in seeds) {
    final at = DateTime.now().subtract(seed.ago);

    // A real (if tiny) file, so playback attempts and the orphan sweep behave
    // the way they would for genuine entries.
    final mediaPath =
        store.newMediaPath(seed.medium == Medium.audio ? 'm4a' : 'mp4');
    await File(mediaPath).writeAsBytes(List.filled(2048, 0));

    String? thumb;
    if (seed.medium == Medium.video && frames.isNotEmpty) {
      thumb = frames[frameIndex % frames.length];
      frameIndex++;
    }

    final tagIds = <int>[];
    for (final name in seed.tags) {
      tagIds.add((await db.ensureTag(name)).id);
    }

    await db.createEntry(
      EntriesCompanion.insert(
        title: Value(seed.title),
        note: Value(seed.note),
        medium: seed.medium,
        typeId: types[seed.type]!.id,
        filePath: store.relativize(mediaPath),
        thumbnailPath: Value(thumb),
        durationMs: seed.length.inMilliseconds,
        fileSizeBytes: seed.sizeBytes,
        originalSizeBytes: Value(seed.originalBytes),
        createdAt: at,
        updatedAt: at,
        recordedAt: at,
        width: const Value(1080),
        height: const Value(1920),
        codec: const Value('h265'),
        bitrateKbps: const Value(3500),
        isFavorite: Value(seed.favourite),
      ),
      tagIds: tagIds,
    );
  }

  // The flag exists to review the populated app, so onboarding would just be in
  // the way. Set through the same key AppSettings reads.
  await db.setSetting('onboarded', 'true');

  debugPrint('[demo seed] inserted ${seeds.length} entries');
}
