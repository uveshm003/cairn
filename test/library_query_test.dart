import 'package:cairn/data/database.dart';
import 'package:cairn/data/library_queries.dart';
import 'package:cairn/domain/entry_filter.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

/// The library query combines eight optional facets plus an FTS join into one
/// hand-written statement. The combinations are where bugs hide, so they get
/// tested rather than trusted.
void main() {
  late CairnDatabase db;
  late Map<String, int> typeIds;

  setUp(() async {
    db = CairnDatabase.forTesting(NativeDatabase.memory());
    typeIds = {for (final t in await db.allTypes()) t.name: t.id};
  });

  tearDown(() async => db.close());

  Future<int> add({
    String? title,
    String? note,
    String type = 'Diary',
    Medium medium = Medium.video,
    List<int> tagIds = const [],
    DateTime? recordedAt,
    int durationMs = 30000,
    bool favourite = false,
  }) async {
    final at = recordedAt ?? DateTime.now();
    final id = await db.createEntry(
      EntriesCompanion.insert(
        title: Value(title),
        note: Value(note),
        medium: medium,
        typeId: typeIds[type]!,
        filePath: 'media/$title.mp4',
        durationMs: durationMs,
        fileSizeBytes: 2048,
        originalSizeBytes: const Value(20480),
        createdAt: at,
        updatedAt: at,
        recordedAt: at,
        isFavorite: Value(favourite),
      ),
      tagIds: tagIds,
    );
    return id;
  }

  Future<List<String?>> titles(EntryFilter filter) async {
    final items = await db.watchLibrary(filter).first;
    return items.map((i) => i.entry.title).toList();
  }

  test('returns entries newest-first and excludes trash', () async {
    final now = DateTime.now();
    await add(title: 'old', recordedAt: now.subtract(const Duration(days: 2)));
    await add(title: 'new', recordedAt: now);
    final trashed = await add(title: 'gone', recordedAt: now);
    await db.moveToTrash(trashed);

    expect(await titles(EntryFilter.empty), ['new', 'old']);
  });

  test('joins type display fields and tag names in one row', () async {
    final a = await db.ensureTag('guitar');
    final b = await db.ensureTag('scales');
    await add(title: 'practice', type: 'Practice', tagIds: [a.id, b.id]);

    final item = (await db.watchLibrary(EntryFilter.empty).first).single;
    expect(item.typeName, 'Practice');
    expect(item.iconKey, 'music');
    expect(item.tagNames..sort(), ['guitar', 'scales']);
  });

  test('a tag containing a comma survives the join', () async {
    // This is why the delimiter is char(31) and not a comma.
    final tag = await db.ensureTag('work, misc');
    await add(title: 'x', tagIds: [tag.id]);

    final item = (await db.watchLibrary(EntryFilter.empty).first).single;
    expect(item.tagNames, ['work, misc']);
  });

  group('facets', () {
    test('type', () async {
      await add(title: 'd', type: 'Diary');
      await add(title: 'p', type: 'Practice');
      expect(
        await titles(EntryFilter(typeIds: {typeIds['Practice']!})),
        ['p'],
      );
    });

    test('medium', () async {
      await add(title: 'v', medium: Medium.video);
      await add(title: 'a', medium: Medium.audio);
      expect(await titles(const EntryFilter(medium: Medium.audio)), ['a']);
    });

    test('favourites', () async {
      await add(title: 'plain');
      await add(title: 'starred', favourite: true);
      expect(
        await titles(const EntryFilter(favouritesOnly: true)),
        ['starred'],
      );
    });

    test('duration bands are alternatives, not intersections', () async {
      await add(title: 'short', durationMs: 30 * 1000);
      await add(title: 'medium', durationMs: 3 * 60 * 1000);
      await add(title: 'long', durationMs: 12 * 60 * 1000);

      expect(
        await titles(const EntryFilter(bands: {DurationBand.under1})),
        ['short'],
      );
      // Two bands selected should widen the results, not narrow them to nothing.
      final both = await titles(const EntryFilter(
        bands: {DurationBand.under1, DurationBand.overFive},
      ));
      expect(both..sort(), ['long', 'short']);
    });

    test('date range excludes its upper bound', () async {
      final day = DateTime(2026, 5, 10, 12);
      await add(title: 'inside', recordedAt: day);
      await add(title: 'next day', recordedAt: day.add(const Duration(days: 1)));

      final filter = EntryFilter(
        from: DateTime(2026, 5, 10),
        to: DateTime(2026, 5, 11),
      );
      expect(await titles(filter), ['inside']);
    });

    test('time-of-day bucket uses the local clock', () async {
      // Constructed without a UTC flag, so these are local times -- which is
      // what the bucket boundaries are defined against.
      await add(title: 'breakfast', recordedAt: DateTime(2026, 5, 10, 8));
      await add(title: 'lunch', recordedAt: DateTime(2026, 5, 10, 13));
      await add(title: 'bedtime', recordedAt: DateTime(2026, 5, 10, 23));

      expect(
        await titles(const EntryFilter(buckets: {TimeOfDayBucket.morning})),
        ['breakfast'],
      );
      expect(
        await titles(const EntryFilter(buckets: {TimeOfDayBucket.afternoon})),
        ['lunch'],
      );
      // Night wraps past midnight, which a naive range comparison would miss.
      expect(
        await titles(const EntryFilter(buckets: {TimeOfDayBucket.night})),
        ['bedtime'],
      );
    });
  });

  group('tag modes', () {
    test('all-of requires every selected tag', () async {
      final guitar = await db.ensureTag('guitar');
      final scales = await db.ensureTag('scales');
      await add(title: 'both', tagIds: [guitar.id, scales.id]);
      await add(title: 'one', tagIds: [guitar.id]);

      expect(
        await titles(EntryFilter(
          tagIds: {guitar.id, scales.id},
          tagMode: TagMode.all,
        )),
        ['both'],
      );
    });

    test('any-of accepts either tag', () async {
      final guitar = await db.ensureTag('guitar');
      final scales = await db.ensureTag('scales');
      await add(title: 'both', tagIds: [guitar.id, scales.id]);
      await add(title: 'one', tagIds: [guitar.id]);

      final result = await titles(EntryFilter(
        tagIds: {guitar.id, scales.id},
        tagMode: TagMode.any,
      ));
      expect(result..sort(), ['both', 'one']);
    });
  });

  group('search', () {
    test('narrows the list and combines with other facets', () async {
      await add(title: 'guitar practice', type: 'Practice');
      await add(title: 'guitar diary', type: 'Diary');
      await add(title: 'unrelated', type: 'Diary');

      expect(await titles(const EntryFilter(searchText: 'guitar')),
          hasLength(2));

      // Search AND type, not search OR type.
      expect(
        await titles(EntryFilter(
          searchText: 'guitar',
          typeIds: {typeIds['Diary']!},
        )),
        ['guitar diary'],
      );
    });

    test('a query matching nothing returns nothing rather than everything',
        () async {
      await add(title: 'anything');
      expect(await titles(const EntryFilter(searchText: 'zzzz')), isEmpty);
    });

    test('blank search text is ignored rather than matching nothing', () async {
      await add(title: 'kept');
      expect(await titles(const EntryFilter(searchText: '   ')), ['kept']);
    });
  });

  group('derived facets', () {
    test('type counts skip trashed entries', () async {
      await add(title: 'a', type: 'Diary');
      final gone = await add(title: 'b', type: 'Diary');
      await db.moveToTrash(gone);

      final counts = await db.watchTypeCounts().first;
      expect(counts[typeIds['Diary']!], 1);
    });

    test('recordedAtBounds spans the library', () async {
      expect((await db.recordedAtBounds()).earliest, isNull);

      await add(title: 'a', recordedAt: DateTime(2026, 1, 1, 9));
      await add(title: 'b', recordedAt: DateTime(2026, 6, 1, 9));

      final bounds = await db.recordedAtBounds();
      expect(bounds.earliest!.year, 2026);
      expect(bounds.earliest!.month, 1);
      expect(bounds.latest!.month, 6);
    });

    test('storage breakdown separates live from trash and reports savings',
        () async {
      await add(title: 'a');
      final gone = await add(title: 'b');
      await db.moveToTrash(gone);

      final s = await db.storageBreakdown();
      expect(s.entryCount, 1);
      expect(s.totalBytes, 2048);
      expect(s.trashBytes, 2048);
      // Original 20480 vs compressed 2048 for the one live entry.
      expect(s.originalBytes, 20480);
      expect(s.savedBytes, 20480 - 2048);
      expect(s.byType['Diary'], 2048);
    });
  });

  group('filter model', () {
    test('round-trips through JSON without the search text', () async {
      final filter = EntryFilter(
        searchText: 'transient',
        from: DateTime(2026, 3, 1),
        buckets: const {TimeOfDayBucket.evening},
        typeIds: const {3},
        tagIds: const {7, 9},
        tagMode: TagMode.any,
        medium: Medium.audio,
        bands: const {DurationBand.overFive},
        favouritesOnly: true,
      );

      final restored = EntryFilter.fromJson(filter.toJson());
      // Search is deliberately dropped: restoring a stale query on launch would
      // look like an empty library.
      expect(restored.searchText, '');
      expect(restored.from, filter.from);
      expect(restored.buckets, filter.buckets);
      expect(restored.typeIds, filter.typeIds);
      expect(restored.tagIds, filter.tagIds);
      expect(restored.tagMode, TagMode.any);
      expect(restored.medium, Medium.audio);
      expect(restored.bands, filter.bands);
      expect(restored.favouritesOnly, isTrue);
    });

    test('unknown enum names in stored JSON are dropped, not fatal', () {
      // Guards against a downgrade, or a facet being renamed in a later build.
      final restored = EntryFilter.fromJson({
        'buckets': ['morning', 'brunch'],
        'medium': 'hologram',
        'tagMode': 'sideways',
      });
      expect(restored.buckets, {TimeOfDayBucket.morning});
      expect(restored.medium, isNull);
      expect(restored.tagMode, TagMode.all);
    });

    test('activeFacetCount ignores search text', () {
      expect(const EntryFilter(searchText: 'x').activeFacetCount, 0);
      expect(const EntryFilter(favouritesOnly: true).activeFacetCount, 1);
      expect(
        EntryFilter(typeIds: const {1}, tagIds: const {2}, from: DateTime.now())
            .activeFacetCount,
        3,
      );
    });

    test('clearedFacets keeps what the user is typing', () {
      const filter = EntryFilter(searchText: 'guitar', favouritesOnly: true);
      final cleared = filter.clearedFacets();
      expect(cleared.searchText, 'guitar');
      expect(cleared.isEmpty, isFalse); // search still counts as active
      expect(cleared.activeFacetCount, 0);
    });
  });
}
