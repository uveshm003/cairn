/// All filter facets in one bottom sheet (requirements.md S13).
///
/// Edits a local copy and only returns it on "Apply", so backing out of the
/// sheet leaves the library exactly as it was.
library;

import 'package:flutter/material.dart';

import '../../data/database.dart';
import '../../data/library_queries.dart';
import '../../domain/entry_filter.dart';
import '../widgets/formatting.dart';

Future<EntryFilter?> showFilterSheet(
  BuildContext context, {
  required CairnDatabase db,
  required EntryFilter current,
}) {
  return showModalBottomSheet<EntryFilter>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => _FilterSheet(db: db, initial: current),
  );
}

class _FilterSheet extends StatefulWidget {
  const _FilterSheet({required this.db, required this.initial});

  final CairnDatabase db;
  final EntryFilter initial;

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late EntryFilter _draft = widget.initial;

  List<EntryTypeRow> _types = const [];
  List<TagRow> _tags = const [];
  Map<int, int> _typeCounts = const {};
  Map<int, int> _tagCounts = const {};

  @override
  void initState() {
    super.initState();
    _loadFacets();
  }

  /// S7: derive the facets from queries rather than storing them.
  Future<void> _loadFacets() async {
    final types = await widget.db.allTypes();
    final tags = await widget.db.allTags();
    final typeCounts = await widget.db.watchTypeCounts().first;
    final tagCounts = await widget.db.tagUsageCounts();
    if (!mounted) return;
    setState(() {
      _types = types;
      _tags = tags;
      _typeCounts = typeCounts;
      _tagCounts = tagCounts;
    });
  }

  Set<T> _toggled<T>(Set<T> set, T value) {
    final next = set.toSet();
    next.contains(value) ? next.remove(value) : next.add(value);
    return next;
  }

  Future<void> _pickDateRange() async {
    final bounds = await widget.db.recordedAtBounds();
    if (!mounted) return;
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      // Bound the picker by what actually exists, so the user cannot filter
      // into a range that is empty by construction.
      firstDate: bounds.earliest ?? DateTime(now.year - 5),
      lastDate: now,
      initialDateRange: _draft.from != null && _draft.to != null
          ? DateTimeRange(
              start: _draft.from!,
              end: _draft.to!.subtract(const Duration(days: 1)),
            )
          : null,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _draft = _draft.copyWith(
        from: DateTime(picked.start.year, picked.start.month, picked.start.day),
        // Stored exclusive: the day after the one the user picked, so the whole
        // final day is included regardless of time of day.
        to: DateTime(picked.end.year, picked.end.month, picked.end.day)
            .add(const Duration(days: 1)),
      );
    });
  }

  void _applyPreset(_DatePreset preset) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final tomorrow = today.add(const Duration(days: 1));
    setState(() {
      _draft = switch (preset) {
        _DatePreset.today => _draft.copyWith(from: today, to: tomorrow),
        _DatePreset.week => _draft.copyWith(
            from: today.subtract(Duration(days: today.weekday - 1)),
            to: tomorrow,
          ),
        _DatePreset.month =>
          _draft.copyWith(from: DateTime(now.year, now.month), to: tomorrow),
      };
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text('Filter', style: theme.textTheme.titleLarge),
                ),
                TextButton(
                  onPressed: () =>
                      setState(() => _draft = _draft.clearedFacets()),
                  child: const Text('Reset'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              children: [
                _Section(
                  title: 'When',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final preset in _DatePreset.values)
                            ActionChip(
                              label: Text(preset.label),
                              onPressed: () => _applyPreset(preset),
                            ),
                          ActionChip(
                            avatar: const Icon(Icons.date_range, size: 16),
                            label: const Text('Custom'),
                            onPressed: _pickDateRange,
                          ),
                          if (_draft.from != null || _draft.to != null)
                            ActionChip(
                              avatar: const Icon(Icons.close, size: 16),
                              label: const Text('Any date'),
                              onPressed: () => setState(
                                () => _draft = _draft.copyWith(clearDates: true),
                              ),
                            ),
                        ],
                      ),
                      if (_draft.from != null && _draft.to != null) ...[
                        const SizedBox(height: 10),
                        Text(
                          '${formatDateOnly(_draft.from!)} – '
                          '${formatDateOnly(_draft.to!.subtract(const Duration(days: 1)))}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
                _Section(
                  title: 'Time of day',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final bucket in TimeOfDayBucket.values)
                        FilterChip(
                          label: Text(bucket.label),
                          tooltip: bucket.hint,
                          selected: _draft.buckets.contains(bucket),
                          onSelected: (_) => setState(() {
                            _draft = _draft.copyWith(
                              buckets: _toggled(_draft.buckets, bucket),
                            );
                          }),
                        ),
                    ],
                  ),
                ),
                _Section(
                  title: 'Type',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final type in _types)
                        FilterChip(
                          avatar: Icon(iconForKey(type.iconKey), size: 16),
                          label: Text('${type.name}'
                              '${_typeCounts[type.id] == null ? '' : ' (${_typeCounts[type.id]})'}'),
                          selected: _draft.typeIds.contains(type.id),
                          onSelected: (_) => setState(() {
                            _draft = _draft.copyWith(
                              typeIds: _toggled(_draft.typeIds, type.id),
                            );
                          }),
                        ),
                    ],
                  ),
                ),
                _Section(
                  title: 'Medium',
                  child: Wrap(
                    spacing: 8,
                    children: [
                      for (final medium in Medium.values)
                        FilterChip(
                          avatar: Icon(iconForMedium(medium), size: 16),
                          label: Text(medium == Medium.audio ? 'Audio' : 'Video'),
                          selected: _draft.medium == medium,
                          onSelected: (selected) => setState(() {
                            _draft = selected
                                ? _draft.copyWith(medium: medium)
                                : _draft.copyWith(clearMedium: true);
                          }),
                        ),
                    ],
                  ),
                ),
                _Section(
                  title: 'Length',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final band in DurationBand.values)
                        FilterChip(
                          label: Text(band.label),
                          selected: _draft.bands.contains(band),
                          onSelected: (_) => setState(() {
                            _draft = _draft.copyWith(
                              bands: _toggled(_draft.bands, band),
                            );
                          }),
                        ),
                    ],
                  ),
                ),
                if (_tags.isNotEmpty)
                  _Section(
                    title: 'Tags',
                    trailing: _draft.tagIds.length > 1
                        // The AND/OR toggle only changes anything with two or
                        // more tags selected, so it appears only then.
                        ? SegmentedButton<TagMode>(
                            style: const ButtonStyle(
                              visualDensity: VisualDensity.compact,
                            ),
                            segments: [
                              for (final mode in TagMode.values)
                                ButtonSegment(
                                  value: mode,
                                  label: Text(mode.label),
                                ),
                            ],
                            selected: {_draft.tagMode},
                            onSelectionChanged: (selection) => setState(() {
                              _draft =
                                  _draft.copyWith(tagMode: selection.first);
                            }),
                          )
                        : null,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in _tags)
                          FilterChip(
                            label: Text('${tag.name}'
                                '${_tagCounts[tag.id] == null ? '' : ' (${_tagCounts[tag.id]})'}'),
                            selected: _draft.tagIds.contains(tag.id),
                            onSelected: (_) => setState(() {
                              _draft = _draft.copyWith(
                                tagIds: _toggled(_draft.tagIds, tag.id),
                              );
                            }),
                          ),
                      ],
                    ),
                  ),
                _Section(
                  title: 'Other',
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Favourites only'),
                    value: _draft.favouritesOnly,
                    onChanged: (value) => setState(
                      () => _draft = _draft.copyWith(favouritesOnly: value),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Cancel'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.of(context).pop(_draft),
                      child: Text(_draft.activeFacetCount == 0
                          ? 'Show all'
                          : 'Apply ${_draft.activeFacetCount}'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum _DatePreset {
  today('Today'),
  week('This week'),
  month('This month');

  const _DatePreset(this.label);

  final String label;
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
