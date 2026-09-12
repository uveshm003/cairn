/// Cairn's data layer: Drift over SQLite, with an FTS5 index for content search.
///
/// Why Drift and not ObjectBox (requirements.md S7 recommends ObjectBox):
/// content search is the point of this product. S15's on-device transcription
/// turns "I know I recorded something about X" from impossible into instant, and
/// that needs real full-text ranking, not substring matching. The FTS5 table
/// below already carries a `transcript` column so that feature slots in without
/// a schema rewrite.
library;

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

part 'database.g.dart';

/// audio | video (S6's first dimension).
enum Medium { audio, video }

/// Which media a type accepts. How-to is video-only; the rest take either.
enum AllowedMedium { audioOnly, videoOnly, both }

/// The encoding ladder (S8). The *type* picks the profile, so the user never
/// has to think about bitrate.
enum ProfileKind { small, balanced, high }

@DataClassName('EntryTypeRow')
class EntryTypes extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 60)();
  IntColumn get allowedMedium => intEnum<AllowedMedium>()();
  IntColumn get maxDurationMs => integer()();
  IntColumn get encodingProfile => intEnum<ProfileKind>()();

  /// True for the fixed five (S6). System types can be edited but not deleted.
  BoolColumn get isSystem => boolean().withDefault(const Constant(false))();
  TextColumn get iconKey => text()();
  TextColumn get colorKey => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
}

@DataClassName('EntryRow')
class Entries extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get title => text().nullable()();
  TextColumn get note => text().nullable()();
  IntColumn get medium => intEnum<Medium>()();
  IntColumn get typeId => integer().references(EntryTypes, #id)();

  /// **Relative** to the app documents dir — never absolute. iOS app-container
  /// paths change across reinstalls and restores, so an absolute path here
  /// would break playback for every restored entry (S9). `MediaStore` is the
  /// only place this gets resolved.
  TextColumn get filePath => text()();

  /// Also relative. Video only.
  TextColumn get thumbnailPath => text().nullable()();

  IntColumn get durationMs => integer()();
  IntColumn get fileSizeBytes => integer()();

  /// Pre-compression size, for the "space saved" stat (S8).
  IntColumn get originalSizeBytes => integer().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// May differ from createdAt for imported entries (S7).
  DateTimeColumn get recordedAt => dateTime()();

  IntColumn get width => integer().nullable()();
  IntColumn get height => integer().nullable()();
  TextColumn get codec => text().nullable()();
  IntColumn get bitrateKbps => integer().nullable()();

  /// Off by default (S5). Only populated when the user opts in.
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();

  /// Amplitude envelope for waveform scrubbing: one byte (0-255) per sample,
  /// captured live from the recorder rather than decoded back out of the file.
  ///
  /// Nothing in the dependency tree can decode audio to amplitudes, and adding
  /// something that could would mean FFmpeg (S8 rules it out). The recorder is
  /// already reporting levels for the on-screen meter, so sampling them costs
  /// nothing.
  ///
  /// Null for video, and for every audio entry recorded before this column
  /// existed -- the player falls back to a plain slider, so null is a normal
  /// state and not a defect. The sample interval is deliberately *not* stored:
  /// it is derived as `durationMs / length`, so changing the capture cadence
  /// cannot misalign old envelopes.
  BlobColumn get amplitudeEnvelope => blob().nullable()();

  BoolColumn get isFavorite => boolean().withDefault(const Constant(false))();

  /// Soft delete -> trash, purged after N days (S9).
  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();
  DateTimeColumn get deletedAt => dateTime().nullable()();
}

@DataClassName('TagRow')
class Tags extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().withLength(min: 1, max: 40)();
  TextColumn get colorKey => text().withDefault(const Constant('slate'))();
}

@DataClassName('EntryTagRow')
class EntryTags extends Table {
  IntColumn get entryId =>
      integer().references(Entries, #id, onDelete: KeyAction.cascade)();
  IntColumn get tagId =>
      integer().references(Tags, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {entryId, tagId};
}

/// Markers dropped *during* recording (one tap, no typing), so a long Practice
/// or How-to entry can be scanned instead of replayed.
///
/// Offsets are relative to the **stored** file, not the stopwatch: the
/// compressed output's duration can diverge from the source (which is exactly
/// why `SavePipeline` measures it), so a raw stopwatch offset can land past the
/// end of the file it points into. Clamping happens at save time.
@DataClassName('MarkerRow')
class EntryMarkers extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get entryId =>
      integer().references(Entries, #id, onDelete: KeyAction.cascade)();
  IntColumn get offsetMs => integer()();

  /// Unused for now -- markers are deliberately one tap with no typing. The
  /// column exists so naming one later is not a migration.
  TextColumn get label => text().nullable()();
}

/// Single key-value table for AppSettings (S7).
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column> get primaryKey => {key};
}

@DriftDatabase(
    tables: [EntryTypes, Entries, Tags, EntryTags, EntryMarkers, Settings])
class CairnDatabase extends _$CairnDatabase {
  CairnDatabase() : super(driftDatabase(name: 'cairn'));

  CairnDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 2;

  /// ASCII unit separator, used to join tag names in the library query. Spelled
  /// as a char code rather than a literal byte, because an invisible control
  /// character in source is the kind of thing an editor silently eats. A comma
  /// delimiter would be corrupted by any tag that itself contains a comma.
  static final tagDelimiter = String.fromCharCode(31);

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();

          // Case-insensitive uniqueness for tag names (S7). SQLite cannot
          // express this as a table constraint, so it is an expression index.
          await customStatement(
            'CREATE UNIQUE INDEX tags_name_nocase ON tags (LOWER(name))',
          );

          // Indexes for the filter facets that actually get used (S12).
          await customStatement(
            'CREATE INDEX entries_recorded_at ON entries (recorded_at DESC)',
          );
          await customStatement(
            'CREATE INDEX entries_deleted ON entries (is_deleted)',
          );

          // The search index (S12). `entry_id` is UNINDEXED because it is a key
          // to look rows up by, not text to match against. `transcript` is
          // empty for now and is where S15's on-device transcription lands --
          // having the column from v1 is why this schema will not need a
          // rewrite when that arrives.
          await customStatement('''
            CREATE VIRTUAL TABLE entry_search USING fts5(
              entry_id UNINDEXED,
              title,
              note,
              tags,
              type_name,
              transcript,
              tokenize = 'unicode61 remove_diacritics 2'
            )
          ''');

          await _seedSystemTypes();

          // v1 databases reach the same shape through onUpgrade; keeping the
          // marker index in one helper means the two paths cannot diverge.
          await _createMarkerIndex();
        },
        onUpgrade: (m, from, to) async {
          // The app's first migration. Deliberately additive and step-wise:
          // `createAll` would be wrong here -- it would collide with the FTS5
          // virtual table and the expression index, neither of which Drift
          // tracks as a table.
          if (from < 2) {
            await m.createTable(entryMarkers);
            await _createMarkerIndex();
            // Existing rows get NULL, which the player reads as "no waveform,
            // use the slider" rather than as an empty waveform.
            await m.addColumn(entries, entries.amplitudeEnvelope);
          }
        },
        beforeOpen: (details) async {
          // Cascade deletes on entry_tags depend on this, and SQLite defaults
          // it off per-connection, so it has to be set on every open.
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  /// Markers are always read by entry, never scanned globally.
  Future<void> _createMarkerIndex() => customStatement(
        'CREATE INDEX IF NOT EXISTS entry_markers_entry '
        'ON entry_markers (entry_id)',
      );

  /// The fixed five (S6). Durations are *defaults*; settings can raise them
  /// within the hard cap.
  Future<void> _seedSystemTypes() async {
    const minute = 60 * 1000;
    final seeds = <EntryTypesCompanion>[
      EntryTypesCompanion.insert(
        name: 'Quick Note',
        allowedMedium: AllowedMedium.both,
        maxDurationMs: minute,
        encodingProfile: ProfileKind.small,
        isSystem: const Value(true),
        iconKey: 'bolt',
        colorKey: 'amber',
        sortOrder: const Value(0),
      ),
      EntryTypesCompanion.insert(
        name: 'Diary',
        allowedMedium: AllowedMedium.both,
        maxDurationMs: 5 * minute,
        encodingProfile: ProfileKind.balanced,
        isSystem: const Value(true),
        iconKey: 'book',
        colorKey: 'indigo',
        sortOrder: const Value(1),
      ),
      EntryTypesCompanion.insert(
        name: 'Practice',
        allowedMedium: AllowedMedium.both,
        maxDurationMs: 20 * minute,
        encodingProfile: ProfileKind.high,
        isSystem: const Value(true),
        iconKey: 'music',
        colorKey: 'teal',
        sortOrder: const Value(2),
      ),
      EntryTypesCompanion.insert(
        name: 'How-to',
        allowedMedium: AllowedMedium.videoOnly,
        maxDurationMs: 10 * minute,
        encodingProfile: ProfileKind.balanced,
        isSystem: const Value(true),
        iconKey: 'steps',
        colorKey: 'rose',
        sortOrder: const Value(3),
      ),
      EntryTypesCompanion.insert(
        name: 'Freeform',
        allowedMedium: AllowedMedium.both,
        maxDurationMs: 30 * minute,
        encodingProfile: ProfileKind.balanced,
        isSystem: const Value(true),
        iconKey: 'shapes',
        colorKey: 'slate',
        sortOrder: const Value(4),
      ),
    ];

    for (final seed in seeds) {
      await into(entryTypes).insert(seed);
    }
  }

  // ---------------------------------------------------------------- types

  Future<List<EntryTypeRow>> allTypes() => (select(entryTypes)
        ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
      .get();

  Stream<List<EntryTypeRow>> watchTypes() => (select(entryTypes)
        ..orderBy([(t) => OrderingTerm(expression: t.sortOrder)]))
      .watch();

  Future<EntryTypeRow> typeById(int id) =>
      (select(entryTypes)..where((t) => t.id.equals(id))).getSingle();

  Future<void> updateTypeMaxDuration(int id, int maxDurationMs) =>
      (update(entryTypes)..where((t) => t.id.equals(id)))
          .write(EntryTypesCompanion(maxDurationMs: Value(maxDurationMs)));

  // ---------------------------------------------------------------- tags

  Stream<List<TagRow>> watchTags() =>
      (select(tags)..orderBy([(t) => OrderingTerm(expression: t.name)])).watch();

  Future<List<TagRow>> allTags() =>
      (select(tags)..orderBy([(t) => OrderingTerm(expression: t.name)])).get();

  /// Finds a tag by case-insensitive name, creating it if absent.
  ///
  /// Tagging has to be *cheap* (S3), so typing "guitar" when "Guitar" already
  /// exists must reuse the existing tag rather than making a near-duplicate.
  Future<TagRow> ensureTag(String rawName) async {
    final name = rawName.trim();
    if (name.isEmpty) throw ArgumentError('tag name is empty');

    final existing = await (select(tags)
          ..where((t) => t.name.lower().equals(name.toLowerCase()))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return existing;

    final id = await into(tags).insert(TagsCompanion.insert(name: name));
    return (select(tags)..where((t) => t.id.equals(id))).getSingle();
  }

  Future<void> renameTag(int id, String name) =>
      (update(tags)..where((t) => t.id.equals(id)))
          .write(TagsCompanion(name: Value(name.trim())));

  /// Deletes a tag, un-tagging every entry that used it, then repairs those
  /// entries' search rows so the removed name stops matching.
  Future<void> deleteTag(int id) async {
    final affected = await (select(entryTags)..where((t) => t.tagId.equals(id)))
        .map((row) => row.entryId)
        .get();
    await (delete(tags)..where((t) => t.id.equals(id))).go();
    for (final entryId in affected) {
      await reindexEntry(entryId);
    }
  }

  /// Usage counts for sorting the tag picker. S7 stores this denormalized; a
  /// GROUP BY over a table this small is simpler and cannot drift out of sync.
  Future<Map<int, int>> tagUsageCounts() async {
    final rows = await customSelect(
      'SELECT et.tag_id AS tag_id, COUNT(*) AS uses '
      'FROM entry_tags et '
      'JOIN entries e ON e.id = et.entry_id '
      'WHERE e.is_deleted = 0 '
      'GROUP BY et.tag_id',
      readsFrom: {entryTags, entries},
    ).get();
    return {
      for (final row in rows) row.read<int>('tag_id'): row.read<int>('uses'),
    };
  }

  Future<List<int>> tagIdsFor(int entryId) =>
      (select(entryTags)..where((t) => t.entryId.equals(entryId)))
          .map((row) => row.tagId)
          .get();

  Future<void> setEntryTags(int entryId, List<int> tagIds) async {
    await transaction(() async {
      await (delete(entryTags)..where((t) => t.entryId.equals(entryId))).go();
      for (final tagId in tagIds) {
        await into(entryTags).insert(
          EntryTagsCompanion.insert(entryId: entryId, tagId: tagId),
        );
      }
    });
    await reindexEntry(entryId);
  }

  // ---------------------------------------------------------------- entries

  Future<EntryRow?> entryById(int id) =>
      (select(entries)..where((e) => e.id.equals(id))).getSingleOrNull();

  Stream<EntryRow?> watchEntry(int id) =>
      (select(entries)..where((e) => e.id.equals(id))).watchSingleOrNull();

  /// Writes the row, its tags, and its search index.
  ///
  /// S9 requires that a crash cannot leave a row pointing at a missing file, or
  /// a file with no row. The media file is already written and integrity-checked
  /// by the time this is called, so committing the row is deliberately the last
  /// step — and if it throws, the caller deletes the orphaned file.
  Future<int> createEntry(
    EntriesCompanion entry, {
    List<int> tagIds = const [],
    List<int> markerOffsetsMs = const [],
  }) async {
    final id = await transaction(() async {
      final newId = await into(entries).insert(entry);
      for (final tagId in tagIds) {
        await into(entryTags)
            .insert(EntryTagsCompanion.insert(entryId: newId, tagId: tagId));
      }
      for (final offset in markerOffsetsMs) {
        await into(entryMarkers).insert(
          EntryMarkersCompanion.insert(entryId: newId, offsetMs: offset),
        );
      }
      return newId;
    });
    await reindexEntry(id);
    return id;
  }

  // --------------------------------------------------------------- markers

  Future<List<MarkerRow>> markersFor(int entryId) => (select(entryMarkers)
        ..where((m) => m.entryId.equals(entryId))
        ..orderBy([(m) => OrderingTerm(expression: m.offsetMs)]))
      .get();

  Stream<List<MarkerRow>> watchMarkers(int entryId) => (select(entryMarkers)
        ..where((m) => m.entryId.equals(entryId))
        ..orderBy([(m) => OrderingTerm(expression: m.offsetMs)]))
      .watch();

  Future<void> deleteMarker(int id) =>
      (delete(entryMarkers)..where((m) => m.id.equals(id))).go();

  /// Sets an existing entry's markers to exactly [offsetsMs].
  ///
  /// Not on the restore path -- that goes through [createEntry], which writes
  /// markers with the row in one transaction. This is the set-replace primitive
  /// the migration test drives the v1 -> v2 table with, and the seam a future
  /// bulk edit would use.
  Future<void> replaceMarkers(int entryId, List<int> offsetsMs) async {
    await transaction(() async {
      await (delete(entryMarkers)..where((m) => m.entryId.equals(entryId)))
          .go();
      for (final offset in offsetsMs) {
        await into(entryMarkers).insert(
          EntryMarkersCompanion.insert(entryId: entryId, offsetMs: offset),
        );
      }
    });
  }


  Future<void> updateEntryFields(int id, EntriesCompanion changes) async {
    await (update(entries)..where((e) => e.id.equals(id))).write(
      changes.copyWith(updatedAt: Value(DateTime.now())),
    );
    await reindexEntry(id);
  }

  Future<void> setFavorite(int id, bool value) =>
      (update(entries)..where((e) => e.id.equals(id))).write(
        EntriesCompanion(
          isFavorite: Value(value),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Soft delete -> trash (S9). The file stays on disk until purge.
  Future<void> moveToTrash(int id) =>
      (update(entries)..where((e) => e.id.equals(id))).write(
        EntriesCompanion(
          isDeleted: const Value(true),
          deletedAt: Value(DateTime.now()),
          updatedAt: Value(DateTime.now()),
        ),
      );

  Future<void> restoreFromTrash(int id) =>
      (update(entries)..where((e) => e.id.equals(id))).write(
        EntriesCompanion(
          isDeleted: const Value(false),
          deletedAt: const Value(null),
          updatedAt: Value(DateTime.now()),
        ),
      );

  /// Removes the row and its search entry. The *caller* deletes the media file
  /// — this class has no filesystem access by design.
  Future<void> purgeEntry(int id) async {
    await (delete(entries)..where((e) => e.id.equals(id))).go();
    await customStatement('DELETE FROM entry_search WHERE entry_id = ?', [id]);
  }

  Stream<List<EntryRow>> watchTrash() => (select(entries)
        ..where((e) => e.isDeleted.equals(true))
        ..orderBy([
          (e) => OrderingTerm(expression: e.deletedAt, mode: OrderingMode.desc),
        ]))
      .watch();

  Future<List<EntryRow>> trashOlderThan(Duration age) {
    final cutoff = DateTime.now().subtract(age);
    return (select(entries)
          ..where((e) =>
              e.isDeleted.equals(true) &
              e.deletedAt.isSmallerThanValue(cutoff)))
        .get();
  }

  Future<List<EntryRow>> allEntriesIncludingTrash() => select(entries).get();

  // ---------------------------------------------------------------- search

  /// Rebuilds one entry's row in the FTS index.
  ///
  /// Delete-then-insert rather than UPDATE: an FTS5 row is not an ordinary row,
  /// and this keeps the index correct whether or not one was already present.
  Future<void> reindexEntry(int id) async {
    final row = await customSelect(
      'SELECT e.title AS title, e.note AS note, ty.name AS type_name, '
      "  (SELECT group_concat(t.name, ' ') FROM entry_tags et "
      '     JOIN tags t ON t.id = et.tag_id WHERE et.entry_id = e.id) AS tags '
      'FROM entries e JOIN entry_types ty ON ty.id = e.type_id '
      'WHERE e.id = ?',
      variables: [Variable.withInt(id)],
      readsFrom: {entries, entryTypes, entryTags, tags},
    ).getSingleOrNull();

    await customStatement('DELETE FROM entry_search WHERE entry_id = ?', [id]);
    if (row == null) return;

    await customStatement(
      'INSERT INTO entry_search '
      '(entry_id, title, note, tags, type_name, transcript) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [
        id,
        row.read<String?>('title') ?? '',
        row.read<String?>('note') ?? '',
        row.read<String?>('tags') ?? '',
        row.read<String>('type_name'),
        '', // S15: transcription fills this in.
      ],
    );
  }

  /// Rebuilds the whole index. Used after an import (S11), and offered as a
  /// repair action in settings.
  Future<void> rebuildSearchIndex() async {
    await customStatement('DELETE FROM entry_search');
    final ids = await select(entries).map((e) => e.id).get();
    for (final id in ids) {
      await reindexEntry(id);
    }
  }

  /// Turns raw user input into an FTS5 prefix query.
  ///
  /// Every term is quoted and given a `*` so "gui" matches "guitar" while the
  /// user is still typing (S12 wants live results). The quoting is about
  /// correctness, not just injection: bare FTS5 treats `-`, `*`, `(`, `"`, `OR`
  /// and `NEAR` as operators, so an unquoted "re-record" would parse as a NOT
  /// and silently return the wrong rows.
  static String? buildMatchQuery(String raw) {
    final terms = raw
        .split(RegExp(r'\s+'))
        .map((t) => t.replaceAll('"', '').trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (terms.isEmpty) return null;
    return terms.map((t) => '"$t"*').join(' AND ');
  }

  // ---------------------------------------------------------------- settings

  Future<String?> settingValue(String key) async {
    final row = await (select(settings)..where((s) => s.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) => into(settings).insertOnConflictUpdate(
        SettingRow(key: key, value: value),
      );

  Stream<List<SettingRow>> watchSettings() => select(settings).watch();
}
