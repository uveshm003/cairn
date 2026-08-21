/// The filter facets from requirements.md S12, as a value type.
///
/// Kept separate from the database so it can be persisted (S12: "persist the
/// last-used filter set"), diffed for the active-filter chips, and unit-tested
/// without a database.
library;

import '../data/database.dart';

/// S12 asks for a time-of-day bucket specifically, not just a date.
///
/// Boundaries are a judgement call; these follow ordinary usage rather than
/// astronomical definitions. Night deliberately wraps past midnight, which is
/// why the hour lists exist instead of a simple range comparison.
enum TimeOfDayBucket {
  morning('Morning', '5am – 12pm'),
  afternoon('Afternoon', '12pm – 5pm'),
  evening('Evening', '5pm – 9pm'),
  night('Night', '9pm – 5am');

  const TimeOfDayBucket(this.label, this.hint);

  final String label;
  final String hint;

  /// Local-clock hours belonging to this bucket.
  List<int> get hours => switch (this) {
        TimeOfDayBucket.morning => const [5, 6, 7, 8, 9, 10, 11],
        TimeOfDayBucket.afternoon => const [12, 13, 14, 15, 16],
        TimeOfDayBucket.evening => const [17, 18, 19, 20],
        // Wraps midnight.
        TimeOfDayBucket.night => const [21, 22, 23, 0, 1, 2, 3, 4],
      };
}

/// S12's duration bands.
enum DurationBand {
  under1('Under 1 min', 0, 60000),
  oneToFive('1 – 5 min', 60000, 300000),
  overFive('Over 5 min', 300000, null);

  const DurationBand(this.label, this.minMs, this.maxMsExclusive);

  final String label;
  final int minMs;
  final int? maxMsExclusive;
}

/// How multiple selected tags combine (S12: "AND/OR toggle").
enum TagMode {
  /// Entry must carry every selected tag.
  all('All of'),

  /// Entry must carry at least one.
  any('Any of');

  const TagMode(this.label);

  final String label;
}

class EntryFilter {
  const EntryFilter({
    this.searchText = '',
    this.from,
    this.to,
    this.buckets = const {},
    this.typeIds = const {},
    this.tagIds = const {},
    this.tagMode = TagMode.all,
    this.medium,
    this.bands = const {},
    this.favouritesOnly = false,
  });

  final String searchText;

  /// Inclusive lower bound on `recordedAt`.
  final DateTime? from;

  /// Exclusive upper bound, so a whole-day range is `[day, day+1)` and does not
  /// depend on sub-second precision.
  final DateTime? to;

  final Set<TimeOfDayBucket> buckets;
  final Set<int> typeIds;
  final Set<int> tagIds;
  final TagMode tagMode;
  final Medium? medium;
  final Set<DurationBand> bands;
  final bool favouritesOnly;

  static const empty = EntryFilter();

  bool get isEmpty =>
      searchText.trim().isEmpty &&
      from == null &&
      to == null &&
      buckets.isEmpty &&
      typeIds.isEmpty &&
      tagIds.isEmpty &&
      medium == null &&
      bands.isEmpty &&
      !favouritesOnly;

  bool get isActive => !isEmpty;

  /// How many facets are narrowing the list. Drives the badge on the filter
  /// button; search is excluded because it has its own visible field.
  int get activeFacetCount =>
      (from != null || to != null ? 1 : 0) +
      (buckets.isEmpty ? 0 : 1) +
      (typeIds.isEmpty ? 0 : 1) +
      (tagIds.isEmpty ? 0 : 1) +
      (medium == null ? 0 : 1) +
      (bands.isEmpty ? 0 : 1) +
      (favouritesOnly ? 1 : 0);

  EntryFilter copyWith({
    String? searchText,
    DateTime? from,
    DateTime? to,
    bool clearDates = false,
    Set<TimeOfDayBucket>? buckets,
    Set<int>? typeIds,
    Set<int>? tagIds,
    TagMode? tagMode,
    Medium? medium,
    bool clearMedium = false,
    Set<DurationBand>? bands,
    bool? favouritesOnly,
  }) {
    return EntryFilter(
      searchText: searchText ?? this.searchText,
      from: clearDates ? null : (from ?? this.from),
      to: clearDates ? null : (to ?? this.to),
      buckets: buckets ?? this.buckets,
      typeIds: typeIds ?? this.typeIds,
      tagIds: tagIds ?? this.tagIds,
      tagMode: tagMode ?? this.tagMode,
      medium: clearMedium ? null : (medium ?? this.medium),
      bands: bands ?? this.bands,
      favouritesOnly: favouritesOnly ?? this.favouritesOnly,
    );
  }

  /// Drops every facet but keeps the search text, which is what the "clear
  /// filters" chip should do — wiping what the user is typing would be rude.
  EntryFilter clearedFacets() => EntryFilter(searchText: searchText);

  // ------------------------------------------------------------ persistence

  /// Serialised for the "persist the last-used filter set" requirement (S12).
  /// Search text is deliberately not persisted: restoring a stale query on
  /// launch would look like an empty library.
  Map<String, dynamic> toJson() => {
        if (from != null) 'from': from!.millisecondsSinceEpoch,
        if (to != null) 'to': to!.millisecondsSinceEpoch,
        if (buckets.isNotEmpty) 'buckets': buckets.map((b) => b.name).toList(),
        if (typeIds.isNotEmpty) 'typeIds': typeIds.toList(),
        if (tagIds.isNotEmpty) 'tagIds': tagIds.toList(),
        'tagMode': tagMode.name,
        if (medium != null) 'medium': medium!.name,
        if (bands.isNotEmpty) 'bands': bands.map((b) => b.name).toList(),
        if (favouritesOnly) 'favouritesOnly': true,
      };

  static EntryFilter fromJson(Map<String, dynamic> json) {
    T? byName<T extends Enum>(List<T> values, Object? name) {
      if (name is! String) return null;
      for (final value in values) {
        if (value.name == name) return value;
      }
      return null;
    }

    Set<T> setByName<T extends Enum>(List<T> values, Object? raw) {
      if (raw is! List) return {};
      return raw.map((n) => byName(values, n)).whereType<T>().toSet();
    }

    return EntryFilter(
      from: json['from'] is int
          ? DateTime.fromMillisecondsSinceEpoch(json['from'] as int)
          : null,
      to: json['to'] is int
          ? DateTime.fromMillisecondsSinceEpoch(json['to'] as int)
          : null,
      buckets: setByName(TimeOfDayBucket.values, json['buckets']),
      typeIds: (json['typeIds'] as List?)?.whereType<int>().toSet() ?? {},
      tagIds: (json['tagIds'] as List?)?.whereType<int>().toSet() ?? {},
      tagMode: byName(TagMode.values, json['tagMode']) ?? TagMode.all,
      medium: byName(Medium.values, json['medium']),
      bands: setByName(DurationBand.values, json['bands']),
      favouritesOnly: json['favouritesOnly'] == true,
    );
  }
}
