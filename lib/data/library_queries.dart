/// The library list query: every facet from requirements.md S12 combined into
/// one statement.
///
/// This lives in an extension rather than in `database.dart` so the schema does
/// not have to import the filter model (which imports the schema back).
///
/// Hand-written SQL rather than Drift's query builder, deliberately: there are
/// eight optional facets plus an FTS join, and expressing that as builder
/// combinators produces something harder to read — and harder to reason about
/// for correctness — than the SQL it compiles to.
library;

import 'package:drift/drift.dart';

import '../domain/entry_filter.dart';
import 'database.dart';

/// One row of the library list: the entry, its type's display fields, and its
/// tag names, fetched in a single query rather than N+1.
class LibraryItem {
  const LibraryItem({
    required this.entry,
    required this.typeName,
    required this.iconKey,
    required this.colorKey,
    required this.tagNames,
  });

  final EntryRow entry;
  final String typeName;
  final String iconKey;
  final String colorKey;
  final List<String> tagNames;
}

/// Storage totals for the settings screen (S9: "surface storage usage").
class StorageBreakdown {
  const StorageBreakdown({
    required this.totalBytes,
    required this.trashBytes,
    required this.originalBytes,
    required this.byType,
    required this.entryCount,
  });

  final int totalBytes;
  final int trashBytes;

  /// Sum of pre-compression sizes, where known. The difference against
  /// [totalBytes] is the "space saved" figure S8 wants surfaced.
  final int originalBytes;

  final Map<String, int> byType;
  final int entryCount;

  int get savedBytes {
    final saved = originalBytes - totalBytes;
    return saved > 0 ? saved : 0;
  }

  double get savedFraction =>
      originalBytes == 0 ? 0 : savedBytes / originalBytes;
}

extension LibraryQueries on CairnDatabase {
  /// Drift stores `DateTime` columns as unix **seconds**, so bounds have to be
  /// converted rather than passed as milliseconds.
  static int _epochSeconds(DateTime value) =>
      value.millisecondsSinceEpoch ~/ 1000;

  static String _placeholders(int count) =>
      List.filled(count, '?').join(', ');

  /// Watches the library, narrowed by [filter].
  ///
  /// Note on reactivity: `readsFrom` lists the Drift tables, not `entry_search`
  /// (which Drift does not know about). That is fine in practice because every
  /// write that changes the index also writes to `entries`, so the stream still
  /// fires. A change made *only* to the FTS table — a bulk transcription pass,
  /// for instance — would need an explicit refresh.
  Stream<List<LibraryItem>> watchLibrary(EntryFilter filter) {
    final variables = <Variable>[];
    final joins = <String>[];
    final where = <String>['e.is_deleted = 0'];

    // Search first: its placeholder appears in the JOIN, which precedes every
    // WHERE placeholder in the finished statement. Variable order must match
    // the order the placeholders appear in the SQL text.
    var orderBy = 'e.recorded_at DESC';
    final match = CairnDatabase.buildMatchQuery(filter.searchText);
    if (match != null) {
      joins.add(
        'INNER JOIN ('
        '  SELECT entry_id, bm25(entry_search) AS rank'
        '  FROM entry_search WHERE entry_search MATCH ?'
        ') sr ON sr.entry_id = e.id',
      );
      variables.add(Variable.withString(match));
      // Relevance first when searching; recency is only the tie-breaker.
      orderBy = 'sr.rank, e.recorded_at DESC';
    }

    if (filter.from != null) {
      where.add('e.recorded_at >= ?');
      variables.add(Variable.withInt(_epochSeconds(filter.from!)));
    }
    if (filter.to != null) {
      // Exclusive, so a single-day range is [day, day+1).
      where.add('e.recorded_at < ?');
      variables.add(Variable.withInt(_epochSeconds(filter.to!)));
    }

    if (filter.buckets.isNotEmpty) {
      // 'localtime' matters: the buckets are about the user's clock, so a
      // recording made at 8pm local must not fall into a different bucket
      // because UTC disagrees.
      final hours = filter.buckets.expand((b) => b.hours).toSet().toList();
      where.add(
        "CAST(strftime('%H', e.recorded_at, 'unixepoch', 'localtime') AS INTEGER)"
        ' IN (${_placeholders(hours.length)})',
      );
      variables.addAll(hours.map(Variable.withInt));
    }

    if (filter.typeIds.isNotEmpty) {
      where.add('e.type_id IN (${_placeholders(filter.typeIds.length)})');
      variables.addAll(filter.typeIds.map(Variable.withInt));
    }

    if (filter.medium != null) {
      where.add('e.medium = ?');
      variables.add(Variable.withInt(filter.medium!.index));
    }

    if (filter.favouritesOnly) {
      where.add('e.is_favorite = 1');
    }

    if (filter.bands.isNotEmpty) {
      // Bands are alternatives, so they OR together inside one AND clause.
      final clauses = <String>[];
      for (final band in filter.bands) {
        if (band.maxMsExclusive == null) {
          clauses.add('e.duration_ms >= ?');
          variables.add(Variable.withInt(band.minMs));
        } else {
          clauses.add('(e.duration_ms >= ? AND e.duration_ms < ?)');
          variables.add(Variable.withInt(band.minMs));
          variables.add(Variable.withInt(band.maxMsExclusive!));
        }
      }
      where.add('(${clauses.join(' OR ')})');
    }

    if (filter.tagIds.isNotEmpty) {
      final ids = filter.tagIds.toList();
      switch (filter.tagMode) {
        case TagMode.all:
          // COUNT(DISTINCT) equalling the selection size is what makes this
          // "has every one of these tags" rather than "has any".
          where.add(
            '(SELECT COUNT(DISTINCT et.tag_id) FROM entry_tags et '
            ' WHERE et.entry_id = e.id '
            '   AND et.tag_id IN (${_placeholders(ids.length)})) = ?',
          );
          variables.addAll(ids.map(Variable.withInt));
          variables.add(Variable.withInt(ids.length));
        case TagMode.any:
          where.add(
            'EXISTS (SELECT 1 FROM entry_tags et WHERE et.entry_id = e.id '
            '  AND et.tag_id IN (${_placeholders(ids.length)}))',
          );
          variables.addAll(ids.map(Variable.withInt));
      }
    }

    final sql = '''
      SELECT e.*,
             ty.name      AS type_name,
             ty.icon_key  AS type_icon_key,
             ty.color_key AS type_color_key,
             (SELECT group_concat(t.name, char(31))
                FROM entry_tags et JOIN tags t ON t.id = et.tag_id
               WHERE et.entry_id = e.id) AS tag_names
        FROM entries e
        JOIN entry_types ty ON ty.id = e.type_id
        ${joins.join('\n')}
       WHERE ${where.join('\n         AND ')}
       ORDER BY $orderBy
    ''';

    return customSelect(
      sql,
      variables: variables,
      readsFrom: {entries, entryTypes, entryTags, tags},
    ).watch().map((rows) => rows.map(_toLibraryItem).toList(growable: false));
  }

  LibraryItem _toLibraryItem(QueryRow row) {
    final joined = row.read<String?>('tag_names');
    return LibraryItem(
      entry: entries.map(row.data),
      typeName: row.read<String>('type_name'),
      iconKey: row.read<String>('type_icon_key'),
      colorKey: row.read<String>('type_color_key'),
      tagNames: joined == null || joined.isEmpty
          ? const []
          : joined.split(CairnDatabase.tagDelimiter),
    );
  }

  /// Date bounds of the whole (non-trashed) library, for the date-range picker.
  /// S7: derive facets from queries rather than storing them.
  Future<({DateTime? earliest, DateTime? latest})> recordedAtBounds() async {
    final row = await customSelect(
      'SELECT MIN(recorded_at) AS lo, MAX(recorded_at) AS hi '
      'FROM entries WHERE is_deleted = 0',
      readsFrom: {entries},
    ).getSingle();
    final lo = row.read<int?>('lo');
    final hi = row.read<int?>('hi');
    return (
      earliest: lo == null ? null : DateTime.fromMillisecondsSinceEpoch(lo * 1000),
      latest: hi == null ? null : DateTime.fromMillisecondsSinceEpoch(hi * 1000),
    );
  }

  /// Per-type counts, for the filter sheet.
  Stream<Map<int, int>> watchTypeCounts() {
    return customSelect(
      'SELECT type_id, COUNT(*) AS n FROM entries '
      'WHERE is_deleted = 0 GROUP BY type_id',
      readsFrom: {entries},
    ).watch().map((rows) => {
          for (final row in rows)
            row.read<int>('type_id'): row.read<int>('n'),
        });
  }

  Stream<int> watchTrashCount() => customSelect(
        'SELECT COUNT(*) AS n FROM entries WHERE is_deleted = 1',
        readsFrom: {entries},
      ).watch().map((rows) => rows.single.read<int>('n'));

  /// Storage usage, broken down for the settings screen (S9).
  Future<StorageBreakdown> storageBreakdown() async {
    final totals = await customSelect(
      'SELECT '
      '  COALESCE(SUM(CASE WHEN is_deleted = 0 THEN file_size_bytes END), 0) AS live, '
      '  COALESCE(SUM(CASE WHEN is_deleted = 1 THEN file_size_bytes END), 0) AS trash, '
      // Live-only, to match `live` above -- otherwise trashed entries would
      // inflate the "space saved" figure against a total they are not part of.
      '  COALESCE(SUM(CASE WHEN is_deleted = 0 THEN original_size_bytes END), 0) AS original, '
      '  COUNT(CASE WHEN is_deleted = 0 THEN 1 END) AS n '
      'FROM entries',
      readsFrom: {entries},
    ).getSingle();

    final perType = await customSelect(
      'SELECT ty.name AS name, COALESCE(SUM(e.file_size_bytes), 0) AS bytes '
      'FROM entries e JOIN entry_types ty ON ty.id = e.type_id '
      'WHERE e.is_deleted = 0 '
      'GROUP BY ty.id ORDER BY bytes DESC',
      readsFrom: {entries, entryTypes},
    ).get();

    return StorageBreakdown(
      totalBytes: totals.read<int>('live'),
      trashBytes: totals.read<int>('trash'),
      // Only entries that recorded an original size contribute, so this
      // under-reports rather than inventing a saving that was never measured.
      originalBytes: totals.read<int>('original'),
      entryCount: totals.read<int>('n'),
      byType: {
        for (final row in perType)
          row.read<String>('name'): row.read<int>('bytes'),
      },
    );
  }
}
