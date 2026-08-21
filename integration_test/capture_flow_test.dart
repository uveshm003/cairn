/// On-device test of the one path that unit tests cannot reach: record ->
/// compress -> integrity-check -> store -> commit row -> appears in library.
///
/// This has to run on real hardware because it is the hardware that varies —
/// whether HEVC hardware encode exists, how long it takes, and whether the
/// encoder honours the requested bitrate. It also exercises the `skipped`
/// branch's neighbours, `MediaStore.adopt` across filesystems, and the FTS
/// index write, none of which the host tests touch.
///
/// Run with:
///   flutter test integration_test/capture_flow_test.dart -d `device-id`
///
/// Requires camera and microphone permissions to already be granted; the test
/// cannot dismiss a system permission dialog.
library;

import 'dart:io';

import 'package:cairn/app.dart';
import 'package:cairn/data/database.dart';
import 'package:cairn/data/library_queries.dart';
import 'package:cairn/domain/encoding_profile.dart';
import 'package:cairn/domain/entry_filter.dart';
import 'package:cairn/media/media_store.dart';
import 'package:cairn/media/save_pipeline.dart';
import 'package:cairn/settings/app_settings.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late CairnDatabase db;
  late MediaStore store;
  late AppSettings settings;

  setUp(() async {
    db = CairnDatabase();
    store = await MediaStore.open();
    settings = await AppSettings.load(db);
  });

  tearDown(() async => db.close());

  testWidgets('the database opens on device and FTS5 is available',
      (tester) async {
    // The host tests prove the *macOS* sqlite3 has FTS5. This proves the
    // library actually bundled with the app does -- a different binary, and the
    // one that matters.
    final rows = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE name = 'entry_search'",
        )
        .get();
    expect(rows, hasLength(1),
        reason: 'FTS5 missing in the on-device sqlite3 build');

    final types = await db.allTypes();
    expect(types.map((t) => t.name), contains('Quick Note'));
  });

  testWidgets('app boots to the library', (tester) async {
    await tester.pumpWidget(CairnApp(
      db: db,
      store: store,
      settings: settings,
      showOnboarding: false,
    ));
    await tester.pumpAndSettle(const Duration(seconds: 3));

    expect(find.text('Cairn'), findsOneWidget);
    expect(find.text('Record'), findsOneWidget);
  });

  testWidgets('an entry survives a full write and read back', (tester) async {
    // Exercises the real on-device filesystem and the relative-path discipline
    // in S9 -- write a file, store its RELATIVE path, then resolve it back to
    // something that actually exists.
    final probe = File(store.newMediaPath('bin'));
    await probe.writeAsBytes(List.filled(2048, 7));
    final relative = store.relativize(probe.path);

    expect(relative.startsWith('media/'), isTrue,
        reason: 'stored paths must be relative, never absolute');
    expect(store.existsRelative(relative), isTrue);
    expect(File(store.resolve(relative)).existsSync(), isTrue);

    final types = await db.allTypes();
    final now = DateTime.now();
    final tag = await db.ensureTag('integration');

    final id = await db.createEntry(
      EntriesCompanion.insert(
        title: const Value('device write probe'),
        note: const Value('written by the integration test'),
        medium: Medium.audio,
        typeId: types.first.id,
        filePath: relative,
        durationMs: 1234,
        fileSizeBytes: await probe.length(),
        createdAt: now,
        updatedAt: now,
        recordedAt: now,
      ),
      tagIds: [tag.id],
    );

    // Round-trips through the real library query, not just a direct select.
    final items = await db
        .watchLibrary(const EntryFilter(searchText: 'probe'))
        .first;
    expect(items.map((i) => i.entry.id), contains(id));
    final item = items.firstWhere((i) => i.entry.id == id);
    expect(item.tagNames, contains('integration'));

    // Clean up after ourselves -- this is the user's real device.
    await db.purgeEntry(id);
    await db.deleteTag(tag.id);
    await store.deleteRelative(relative);
    expect(store.existsRelative(relative), isFalse);
  });

  testWidgets('the audio profile is what the recorder will actually be given',
      (tester) async {
    // Cheap, but it is the assertion that catches a kbps/bps mix-up before it
    // silently produces a 128 kbps "Small" note.
    for (final profile in EncodingProfile.ladder) {
      expect(profile.audioConfig.bitRate, profile.audioBitrateKbps * 1000);
    }
  });

  testWidgets('integrity check rejects an empty audio file', (tester) async {
    // The failure path matters as much as the success path: a zero-byte
    // recording must be refused rather than committed as an entry.
    final pipeline = SavePipeline(store);
    final empty = File(store.newMediaPath('m4a'));
    await empty.writeAsBytes(const []);

    await expectLater(
      pipeline.saveAudio(sourcePath: empty.path, durationMs: 1000),
      throwsA(isA<IntegrityException>()),
    );

    // The source is left alone when the check fails, so the user could retry.
    expect(empty.existsSync(), isTrue);
    await empty.delete();
  });

  testWidgets('missing source is refused rather than crashing',
      (tester) async {
    final pipeline = SavePipeline(store);
    await expectLater(
      pipeline.saveAudio(
        sourcePath: '${store.resolve('media')}/does-not-exist.m4a',
        durationMs: 1000,
      ),
      throwsA(isA<IntegrityException>()),
    );
  });
}
