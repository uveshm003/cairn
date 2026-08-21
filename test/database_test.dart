import 'package:cairn/data/database.dart';
// drift and flutter_test both export isNull/isNotNull; the matchers are what
// this file wants, so drift's column predicates are hidden.
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// These tests exist mainly to answer one question early: **is FTS5 actually
/// available?** The whole reason this project uses Drift instead of ObjectBox
/// (requirements.md S7/S12) is full-text search. If `CREATE VIRTUAL TABLE ...
/// USING fts5` fails, the DB decision is wrong and everything built on top of
/// it would have to be redone.
///
/// Caveat worth stating: this proves the *host* sqlite3 has FTS5. The library
/// bundled with the app on a device is a different binary. `package:sqlite3` 3.x
/// ships FTS5 enabled, but confirm on-device too.
void main() {
  late CairnDatabase db;

  setUp(() {
    db = CairnDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<int> insertEntry({
    String? title,
    String? note,
    int typeId = 1,
    Medium medium = Medium.video,
    List<int> tagIds = const [],
    DateTime? recordedAt,
    int durationMs = 30000,
  }) {
    final now = DateTime.now();
    return db.createEntry(
      EntriesCompanion.insert(
        title: Value(title),
        note: Value(note),
        medium: medium,
        typeId: typeId,
        filePath: 'media/${title ?? 'x'}.mp4',
        durationMs: durationMs,
        fileSizeBytes: 1024,
        createdAt: now,
        updatedAt: now,
        recordedAt: recordedAt ?? now,
      ),
      tagIds: tagIds,
    );
  }

  group('schema', () {
    test('seeds the five system types from S6', () async {
      final types = await db.allTypes();
      expect(types.map((t) => t.name), [
        'Quick Note',
        'Diary',
        'Practice',
        'How-to',
        'Freeform',
      ]);
      expect(types.every((t) => t.isSystem), isTrue);
    });

    test('type durations and profiles match the S6 table', () async {
      final types = {for (final t in await db.allTypes()) t.name: t};
      expect(types['Quick Note']!.maxDurationMs, 60 * 1000);
      expect(types['Quick Note']!.encodingProfile, ProfileKind.small);
      expect(types['Practice']!.encodingProfile, ProfileKind.high);
      expect(types['Freeform']!.maxDurationMs, 30 * 60 * 1000);
      // How-to is the one video-only type.
      expect(types['How-to']!.allowedMedium, AllowedMedium.videoOnly);
    });

    test('FTS5 virtual table exists', () async {
      final rows = await db
          .customSelect(
            "SELECT name FROM sqlite_master WHERE name = 'entry_search'",
          )
          .get();
      expect(rows, hasLength(1),
          reason: 'FTS5 is unavailable — the Drift/FTS5 decision is void');
    });
  });

  group('tags', () {
    test('ensureTag is case-insensitive, so near-duplicates cannot form',
        () async {
      final a = await db.ensureTag('Guitar');
      final b = await db.ensureTag('guitar');
      final c = await db.ensureTag('  GUITAR  ');
      expect(b.id, a.id);
      expect(c.id, a.id);
      expect(await db.allTags(), hasLength(1));
      // The first spelling wins, rather than the last write clobbering it.
      expect(a.name, 'Guitar');
    });

    test('deleting a tag un-tags its entries', () async {
      final tag = await db.ensureTag('scales');
      final id = await insertEntry(title: 'practice', tagIds: [tag.id]);
      expect(await db.tagIdsFor(id), [tag.id]);

      await db.deleteTag(tag.id);
      expect(await db.tagIdsFor(id), isEmpty);
      // The entry survives; only the tag link went away.
      expect(await db.entryById(id), isNotNull);
    });

    test('usage counts ignore trashed entries', () async {
      final tag = await db.ensureTag('daily');
      final kept = await insertEntry(title: 'a', tagIds: [tag.id]);
      final trashed = await insertEntry(title: 'b', tagIds: [tag.id]);
      expect((await db.tagUsageCounts())[tag.id], 2);

      await db.moveToTrash(trashed);
      expect((await db.tagUsageCounts())[tag.id], 1);
      expect(kept, isNotNull);
    });
  });

  group('search', () {
    test('matches on title, note, tag name and type name', () async {
      final tag = await db.ensureTag('fingerpicking');
      await insertEntry(
        title: 'Travis pattern',
        note: 'thumb stays on the bass strings',
        tagIds: [tag.id],
      );

      Future<int> hits(String query) async {
        final match = CairnDatabase.buildMatchQuery(query)!;
        final rows = await db.customSelect(
          'SELECT entry_id FROM entry_search WHERE entry_search MATCH ?',
          variables: [Variable.withString(match)],
        ).get();
        return rows.length;
      }

      expect(await hits('Travis'), 1, reason: 'title');
      expect(await hits('bass'), 1, reason: 'note');
      expect(await hits('fingerpicking'), 1, reason: 'tag name');
      expect(await hits('Quick'), 1, reason: 'type name');
      expect(await hits('banjo'), 0);
    });

    test('is prefix-matching, so results appear while typing', () async {
      await insertEntry(title: 'guitar practice');
      final match = CairnDatabase.buildMatchQuery('gui')!;
      final rows = await db.customSelect(
        'SELECT entry_id FROM entry_search WHERE entry_search MATCH ?',
        variables: [Variable.withString(match)],
      ).get();
      expect(rows, hasLength(1));
    });

    test('reindexes when tags change', () async {
      final id = await insertEntry(title: 'untagged');
      final tag = await db.ensureTag('woodwork');
      await db.setEntryTags(id, [tag.id]);

      final match = CairnDatabase.buildMatchQuery('woodwork')!;
      final rows = await db.customSelect(
        'SELECT entry_id FROM entry_search WHERE entry_search MATCH ?',
        variables: [Variable.withString(match)],
      ).get();
      expect(rows.single.read<int>('entry_id'), id);
    });

    test('purging an entry removes it from the index', () async {
      final id = await insertEntry(title: 'ephemeral');
      await db.purgeEntry(id);
      final rows = await db
          .customSelect('SELECT entry_id FROM entry_search')
          .get();
      expect(rows, isEmpty);
    });

    group('buildMatchQuery', () {
      test('quotes terms so FTS5 operators are treated as text', () {
        // Unquoted, FTS5 reads the hyphen as NOT and would return wrong rows.
        expect(CairnDatabase.buildMatchQuery('re-record'), '"re-record"*');
        expect(CairnDatabase.buildMatchQuery('a OR b'), '"a"* AND "OR"* AND "b"*');
        expect(CairnDatabase.buildMatchQuery('quote"inside'), '"quoteinside"*');
      });

      test('returns null for input with no usable terms', () {
        expect(CairnDatabase.buildMatchQuery(''), isNull);
        expect(CairnDatabase.buildMatchQuery('   '), isNull);
        expect(CairnDatabase.buildMatchQuery('""'), isNull);
      });
    });

    test('a search term with an FTS5 operator does not throw', () async {
      await insertEntry(title: 'take 2 - second try');
      for (final query in ['-', '*', '(', 'a OR', 'NEAR(', '"']) {
        final match = CairnDatabase.buildMatchQuery(query);
        if (match == null) continue;
        // The point is that this completes rather than raising a syntax error.
        await db.customSelect(
          'SELECT entry_id FROM entry_search WHERE entry_search MATCH ?',
          variables: [Variable.withString(match)],
        ).get();
      }
    });
  });

  group('trash', () {
    test('soft delete hides from the library but keeps the row', () async {
      final id = await insertEntry(title: 'oops');
      await db.moveToTrash(id);

      final row = await db.entryById(id);
      expect(row!.isDeleted, isTrue);
      expect(row.deletedAt, isNotNull);
      expect(await db.watchTrash().first, hasLength(1));
    });

    test('restore clears the deleted timestamp', () async {
      final id = await insertEntry(title: 'saved');
      await db.moveToTrash(id);
      await db.restoreFromTrash(id);

      final row = await db.entryById(id);
      expect(row!.isDeleted, isFalse);
      expect(row.deletedAt, isNull);
    });

    test('trashOlderThan only returns items past the purge window', () async {
      final fresh = await insertEntry(title: 'fresh');
      final stale = await insertEntry(title: 'stale');
      await db.moveToTrash(fresh);
      await db.moveToTrash(stale);

      // Nothing has aged yet, so a 30-day window catches neither.
      expect(await db.trashOlderThan(const Duration(days: 30)), isEmpty);

      // Backdate one of them to simulate an item that has sat in the trash
      // past the window. Drift stores DateTime as unix *seconds*, not
      // milliseconds -- which is also why a zero-length window matches nothing:
      // deletedAt and the cutoff land in the same second, and the comparison is
      // strictly less-than.
      final fortyDaysAgo = DateTime.now().subtract(const Duration(days: 40));
      await db.customStatement(
        'UPDATE entries SET deleted_at = ? WHERE id = ?',
        [fortyDaysAgo.millisecondsSinceEpoch ~/ 1000, stale],
      );

      final due = await db.trashOlderThan(const Duration(days: 30));
      expect(due.map((e) => e.id), [stale]);
    });
  });

  group('settings', () {
    test('upserts rather than duplicating a key', () async {
      await db.setSetting('theme', 'dark');
      await db.setSetting('theme', 'light');
      expect(await db.settingValue('theme'), 'light');
    });

    test('returns null for an unset key', () async {
      expect(await db.settingValue('nope'), isNull);
    });
  });
}
