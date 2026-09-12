import 'dart:io';
import 'dart:typed_data';

import 'package:cairn/data/database.dart';
import 'package:drift/drift.dart' show Value, Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The v2 migration, exercised the way it will actually run: against a **v1
/// database with rows already in it**.
///
/// This is the app's first migration, and a fresh-create test would pass while
/// the first machine to run the real path is a phone with a real library on it.
/// So the v1 schema below is frozen verbatim (dumped from `sqlite_master` at
/// v1) and seeded with rows before drift is allowed to open the file.
///
/// Do not "fix" this DDL to match the current schema. It is a historical record
/// of what shipped; changing it is the same as deleting the test.
const _v1Schema = [
  'CREATE TABLE "entry_types" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,'
      ' "name" TEXT NOT NULL, "allowed_medium" INTEGER NOT NULL,'
      ' "max_duration_ms" INTEGER NOT NULL, "encoding_profile" INTEGER NOT'
      ' NULL, "is_system" INTEGER NOT NULL DEFAULT 0 CHECK ("is_system" IN (0,'
      ' 1)), "icon_key" TEXT NOT NULL, "color_key" TEXT NOT NULL, "sort_order"'
      ' INTEGER NOT NULL DEFAULT 0)',
  // Note: no `amplitude_envelope`. That column is what v2 adds.
  'CREATE TABLE "entries" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,'
      ' "title" TEXT NULL, "note" TEXT NULL, "medium" INTEGER NOT NULL,'
      ' "type_id" INTEGER NOT NULL REFERENCES entry_types (id), "file_path"'
      ' TEXT NOT NULL, "thumbnail_path" TEXT NULL, "duration_ms" INTEGER NOT'
      ' NULL, "file_size_bytes" INTEGER NOT NULL, "original_size_bytes"'
      ' INTEGER NULL, "created_at" INTEGER NOT NULL, "updated_at" INTEGER NOT'
      ' NULL, "recorded_at" INTEGER NOT NULL, "width" INTEGER NULL, "height"'
      ' INTEGER NULL, "codec" TEXT NULL, "bitrate_kbps" INTEGER NULL,'
      ' "latitude" REAL NULL, "longitude" REAL NULL, "is_favorite" INTEGER NOT'
      ' NULL DEFAULT 0 CHECK ("is_favorite" IN (0, 1)), "is_deleted" INTEGER'
      ' NOT NULL DEFAULT 0 CHECK ("is_deleted" IN (0, 1)), "deleted_at"'
      ' INTEGER NULL)',
  'CREATE TABLE "tags" ("id" INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,'
      ' "name" TEXT NOT NULL, "color_key" TEXT NOT NULL DEFAULT \'slate\')',
  'CREATE TABLE "entry_tags" ("entry_id" INTEGER NOT NULL REFERENCES entries'
      ' (id) ON DELETE CASCADE, "tag_id" INTEGER NOT NULL REFERENCES tags (id)'
      ' ON DELETE CASCADE, PRIMARY KEY ("entry_id", "tag_id"))',
  'CREATE TABLE "settings" ("key" TEXT NOT NULL, "value" TEXT NOT NULL,'
      ' PRIMARY KEY ("key"))',
  'CREATE UNIQUE INDEX tags_name_nocase ON tags (LOWER(name))',
  'CREATE INDEX entries_recorded_at ON entries (recorded_at DESC)',
  'CREATE INDEX entries_deleted ON entries (is_deleted)',
  '''
    CREATE VIRTUAL TABLE entry_search USING fts5(
      entry_id UNINDEXED, title, note, tags, type_name, transcript,
      tokenize = 'unicode61 remove_diacritics 2'
    )
  ''',
];

/// A v1 library with content in it: two types, two entries (one trashed), a
/// tag, a setting, and a populated search row.
const _v1Rows = [
  "INSERT INTO entry_types (id, name, allowed_medium, max_duration_ms,"
      " encoding_profile, is_system, icon_key, color_key, sort_order)"
      " VALUES (1, 'Quick Note', 2, 60000, 0, 1, 'bolt', 'amber', 0)",
  "INSERT INTO entry_types (id, name, allowed_medium, max_duration_ms,"
      " encoding_profile, is_system, icon_key, color_key, sort_order)"
      " VALUES (3, 'Practice', 2, 1200000, 2, 1, 'music', 'teal', 2)",
  "INSERT INTO entries (id, title, note, medium, type_id, file_path,"
      " duration_ms, file_size_bytes, original_size_bytes, created_at,"
      " updated_at, recorded_at, is_favorite, is_deleted)"
      " VALUES (1, 'Scales', 'slow', 0, 3, 'media/a.m4a', 754000, 4194304,"
      " 29500000, 1750000000, 1750000000, 1750000000, 1, 0)",
  "INSERT INTO entries (id, title, medium, type_id, file_path, duration_ms,"
      " file_size_bytes, created_at, updated_at, recorded_at, is_favorite,"
      " is_deleted, deleted_at)"
      " VALUES (2, 'Trashed thought', 1, 1, 'media/b.mp4', 12000, 900000,"
      " 1750000001, 1750000001, 1750000001, 0, 1, 1750000500)",
  "INSERT INTO tags (id, name) VALUES (1, 'fingerpicking')",
  "INSERT INTO entry_tags (entry_id, tag_id) VALUES (1, 1)",
  "INSERT INTO settings (key, value) VALUES ('onboarded', 'true')",
  "INSERT INTO entry_search (entry_id, title, note, tags, type_name,"
      " transcript) VALUES (1, 'Scales', 'slow', 'fingerpicking', 'Practice',"
      " '')",
];

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('cairn-migration');
    file = File('${dir.path}/cairn.sqlite');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// Opens [file] as a v1 database, letting drift's migrator upgrade it.
  ///
  /// The v1 schema is written in `setup`, which runs before drift inspects the
  /// file, so `user_version = 1` is what the migrator sees.
  CairnDatabase openAsV1() => CairnDatabase.forTesting(
        NativeDatabase(
          file,
          setup: (raw) {
            for (final stmt in [..._v1Schema, ..._v1Rows]) {
              raw.execute(stmt);
            }
            raw.execute('PRAGMA user_version = 1');
          },
        ),
      );

  test('a v1 database upgrades to v2 without losing anything', () async {
    final db = openAsV1();
    addTearDown(db.close);

    // Any query forces the migration.
    final entries = await db.allEntriesIncludingTrash();

    expect(entries, hasLength(2), reason: 'entries were lost in the upgrade');
    final scales = entries.firstWhere((e) => e.id == 1);
    expect(scales.title, 'Scales');
    expect(scales.durationMs, 754000);
    expect(scales.originalSizeBytes, 29500000);
    expect(scales.isFavorite, isTrue);
    expect(entries.firstWhere((e) => e.id == 2).isDeleted, isTrue,
        reason: 'the trashed entry must stay trashed, not resurface');
  });

  test('the new column really exists after the upgrade', () async {
    final db = openAsV1();
    addTearDown(db.close);

    // Asserted against `table_info`, not by reading the field. Drift issues
    // `SELECT *` and maps results by name, so a *missing* column reads back as
    // null exactly like a present-but-empty one -- an `expect(..., isNull)`
    // here passes whether or not the migration ran, which is worthless.
    final columns =
        await db.customSelect("PRAGMA table_info('entries')").get();
    expect(
      columns.map((r) => r.read<String>('name')),
      contains('amplitude_envelope'),
      reason: 'onUpgrade did not add the column',
    );
  });

  test('an envelope can be written and read on a migrated database',
      () async {
    final db = openAsV1();
    addTearDown(db.close);

    // A write is the assertion that cannot be faked: `UPDATE` names the column
    // explicitly, so it throws if v2 never added it.
    final envelope = Uint8List.fromList([0, 128, 255]);
    await db.updateEntryFields(
      1,
      EntriesCompanion(amplitudeEnvelope: Value(envelope)),
    );
    expect((await db.entryById(1))!.amplitudeEnvelope, envelope);
  });

  test('existing rows have no envelope, rather than an empty one', () async {
    final db = openAsV1();
    addTearDown(db.close);

    // Null means "no waveform, use the slider". An empty blob would paint as a
    // flat line and read as a silent recording.
    expect((await db.entryById(2))!.amplitudeEnvelope, isNull);
  });

  test('markers work on a migrated database', () async {
    final db = openAsV1();
    addTearDown(db.close);

    await db.replaceMarkers(1, [1000, 5000, 9000]);
    final markers = await db.markersFor(1);
    expect(markers.map((m) => m.offsetMs), [1000, 5000, 9000]);
  });

  test('the marker cascade is wired on a migrated database', () async {
    // The FK only cascades because `beforeOpen` sets `PRAGMA foreign_keys` on
    // every connection -- a migrated database is a new connection too.
    final db = openAsV1();
    addTearDown(db.close);

    await db.replaceMarkers(1, [1000]);
    await db.purgeEntry(1);
    expect(await db.markersFor(1), isEmpty,
        reason: 'markers outlived their entry');
  });

  test('the v1 tag uniqueness index survives the upgrade', () async {
    // An expression index is not a table, so a careless `createAll` in
    // onUpgrade would have thrown here instead.
    final db = openAsV1();
    addTearDown(db.close);

    final again = await db.ensureTag('FingerPicking');
    expect(again.id, 1, reason: 'case-insensitive tag reuse broke');
  });

  test('the v1 search index survives and still matches', () async {
    final db = openAsV1();
    addTearDown(db.close);

    final hits = await db
        .customSelect(
          "SELECT entry_id FROM entry_search WHERE entry_search MATCH ?",
          variables: [Variable.withString('"scales"*')],
        )
        .get();
    expect(hits.map((r) => r.read<int>('entry_id')), contains(1));
  });

  test('opening an already-migrated database is a no-op', () async {
    final first = openAsV1();
    await first.allTypes();
    await first.close();

    // Second open: user_version is 2 now, so setup must not re-run the v1 DDL.
    final second = CairnDatabase.forTesting(NativeDatabase(file));
    addTearDown(second.close);

    expect(await second.allEntriesIncludingTrash(), hasLength(2));
    await second.replaceMarkers(2, [500]);
    expect(await second.markersFor(2), hasLength(1));
  });

  test('a fresh v2 database has the same marker capability', () async {
    // Both paths must arrive at the same shape: onCreate and onUpgrade each
    // create the marker index, and a divergence there is invisible until a
    // query plan gets slow.
    final fresh = CairnDatabase.forTesting(NativeDatabase.memory());
    addTearDown(fresh.close);

    final indexes = await fresh
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name = 'entry_markers_entry'",
        )
        .get();
    expect(indexes, hasLength(1), reason: 'onCreate skipped the marker index');
  });

  test('the migrated database also has the marker index', () async {
    final db = openAsV1();
    addTearDown(db.close);
    await db.allTypes();

    final indexes = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' "
          "AND name = 'entry_markers_entry'",
        )
        .get();
    expect(indexes, hasLength(1), reason: 'onUpgrade skipped the marker index');
  });
}
