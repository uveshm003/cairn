/// The library (requirements.md §13): list/grid, filter bar, search, capture.
///
/// Structured as a journal rather than a file browser — entries group under day
/// headings, which is how someone actually remembers a recording ("that thing
/// from Tuesday"). One deliberate exception: grouping is suppressed while
/// searching, because `watchLibrary` orders by relevance then, and day headers
/// over a relevance-ordered list would repeat and interleave.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../../data/library_queries.dart';
import '../../domain/entry_filter.dart';
import '../capture/capture_flow.dart';
import '../detail/entry_detail_screen.dart';
import '../settings/settings_screen.dart';
import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';
import '../trash/trash_screen.dart';
import '../widgets/cairn_mark.dart';
import '../widgets/formatting.dart';
import 'entry_tile.dart';
import 'filter_sheet.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  Timer? _debounce;

  EntryFilter _filter = EntryFilter.empty;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // §12: persist the last-used filter set.
    _filter = AppScope.of(context).settings.lastFilter.value;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// §12 wants live results; debounced so one FTS query does not fire per
  /// keystroke.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted) {
        setState(() => _filter = _filter.copyWith(searchText: value));
      }
    });
  }

  void _clearSearch() {
    _debounce?.cancel();
    _searchController.clear();
    _searchFocus.unfocus();
    setState(() => _filter = _filter.copyWith(searchText: ''));
  }

  Future<void> _openFilterSheet() async {
    final scope = AppScope.of(context);
    final updated =
        await showFilterSheet(context, db: scope.db, current: _filter);
    if (updated == null || !mounted) return;
    setState(() => _filter = updated);
    await scope.settings.saveFilter(updated);
  }

  void _clearFacets() {
    final cleared = _filter.clearedFacets();
    setState(() => _filter = cleared);
    AppScope.of(context).settings.saveFilter(cleared);
  }

  void _openEntry(LibraryItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EntryDetailScreen(entryId: item.entry.id),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;
    final palette = context.palette;

    return Scaffold(
      floatingActionButton: _RecordFab(onPressed: () => startCapture(context)),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(
              searchController: _searchController,
              searchFocus: _searchFocus,
              onSearchChanged: _onSearchChanged,
              onClearSearch: _clearSearch,
              hasSearch: _filter.searchText.trim().isNotEmpty,
              facetCount: _filter.activeFacetCount,
              onFilter: _openFilterSheet,
              gridView: settings.gridView,
              onToggleView: () => settings.setGridView(!settings.gridView.value),
              onMenu: (value) {
                switch (value) {
                  case 'settings':
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const SettingsScreen(),
                    ));
                  case 'trash':
                    Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const TrashScreen(),
                    ));
                }
              },
            ),
            if (_filter.activeFacetCount > 0)
              _ActiveFilterChips(
                filter: _filter,
                db: scope.db,
                onClear: _clearFacets,
                onEdit: _openFilterSheet,
              ),
            Expanded(
              child: StreamBuilder<List<LibraryItem>>(
                stream: scope.db.watchLibrary(_filter),
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return _ErrorState(error: snapshot.error!);
                  }
                  if (!snapshot.hasData) {
                    // A brief spinner on a fast local query is more flicker than
                    // information, so the first frame is simply blank.
                    return const SizedBox.shrink();
                  }
                  final items = snapshot.data!;
                  if (items.isEmpty) {
                    return _EmptyState(
                      filtered: _filter.isActive,
                      searching: _filter.searchText.trim().isNotEmpty,
                      onClear: () {
                        _clearSearch();
                        _clearFacets();
                      },
                      onRecord: () => startCapture(context),
                    );
                  }
                  return ValueListenableBuilder<bool>(
                    valueListenable: settings.gridView,
                    builder: (context, grid, _) => grid
                        ? _LibraryGrid(items: items, onTap: _openEntry)
                        : _LibraryList(
                            items: items,
                            onTap: _openEntry,
                            // Relevance order makes day headers nonsense.
                            grouped: _filter.searchText.trim().isEmpty,
                          ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      backgroundColor: palette.canvas,
    );
  }
}

/// Wordmark, actions, and the search field. Not an `AppBar` — the wordmark is a
/// painted mark plus a serif logotype, which the AppBar title slot fights.
class _Header extends StatelessWidget {
  const _Header({
    required this.searchController,
    required this.searchFocus,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.hasSearch,
    required this.facetCount,
    required this.onFilter,
    required this.gridView,
    required this.onToggleView,
    required this.onMenu,
  });

  final TextEditingController searchController;
  final FocusNode searchFocus;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final bool hasSearch;
  final int facetCount;
  final VoidCallback onFilter;
  final ValueNotifier<bool> gridView;
  final VoidCallback onToggleView;
  final ValueChanged<String> onMenu;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, Space.md, Space.sm, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const CairnMark(size: 26),
              const SizedBox(width: Space.md),
              // The wordmark. Fraunces at display size is the single strongest
              // signal that this is not a stock Material app.
              Expanded(
                child: Text('Cairn', style: text.displaySmall),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: gridView,
                builder: (context, grid, _) => _IconAction(
                  icon: grid ? Icons.view_agenda_outlined : Icons.grid_view,
                  tooltip: grid ? 'Show as list' : 'Show as grid',
                  onTap: onToggleView,
                ),
              ),
              _IconAction(
                icon: Icons.tune,
                tooltip: 'Filter',
                badge: facetCount,
                onTap: onFilter,
              ),
              PopupMenuButton<String>(
                onSelected: onMenu,
                tooltip: 'More',
                icon: Icon(Icons.more_horiz, color: palette.ink),
                position: PopupMenuPosition.under,
                itemBuilder: (context) => const [
                  PopupMenuItem(value: 'trash', child: Text('Trash')),
                  PopupMenuItem(value: 'settings', child: Text('Settings')),
                ],
              ),
            ],
          ),
          const SizedBox(height: Space.md),
          // Always-visible search, rather than hidden behind an icon: finding
          // things is the product (§2), so it should not need a tap to reveal.
          _SearchField(
            controller: searchController,
            focusNode: searchFocus,
            onChanged: onSearchChanged,
            onClear: onClearSearch,
            hasText: hasSearch,
          ),
          const SizedBox(height: Space.md),
        ],
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onClear,
    required this.hasText,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool hasText;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: palette.ink,
          ),
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search titles, notes, tags',
        prefixIcon: Icon(Icons.search, size: 19, color: palette.inkTertiary),
        prefixIconConstraints: const BoxConstraints(minWidth: 44),
        suffixIcon: hasText
            ? IconButton(
                icon: Icon(Icons.close, size: 18, color: palette.inkSecondary),
                onPressed: onClear,
                tooltip: 'Clear search',
              )
            : null,
        contentPadding: const EdgeInsets.symmetric(vertical: Space.md),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
          borderSide: BorderSide(color: palette.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.pill),
          borderSide: BorderSide(color: palette.accent, width: 1.4),
        ),
        fillColor: palette.surface,
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.badge = 0,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final int badge;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      icon: badge > 0
          ? Badge(
              label: Text('$badge'),
              backgroundColor: palette.accent,
              textColor: palette.onAccent,
              child: Icon(icon, color: palette.ink),
            )
          : Icon(icon, color: palette.ink),
    );
  }
}

/// The capture affordance. A record dot rather than a plus — the FAB does one
/// thing, and §5 budgets it as tap one of two.
class _RecordFab extends StatelessWidget {
  const _RecordFab({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return FloatingActionButton.extended(
      onPressed: onPressed,
      backgroundColor: palette.ink,
      foregroundColor: palette.canvas,
      icon: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: palette.record,
          shape: BoxShape.circle,
        ),
      ),
      label: const Text('Record'),
    );
  }
}

/// §12: "show active-filter chips with one-tap clear."
class _ActiveFilterChips extends StatelessWidget {
  const _ActiveFilterChips({
    required this.filter,
    required this.db,
    required this.onClear,
    required this.onEdit,
  });

  final EntryFilter filter;
  final CairnDatabase db;
  final VoidCallback onClear;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return FutureBuilder<List<String>>(
      future: _labels(),
      builder: (context, snapshot) {
        final labels = snapshot.data ?? const <String>[];
        if (labels.isEmpty) return const SizedBox.shrink();
        return Padding(
          // Intrinsic height, not a fixed box: §14 asks for dynamic type, and a
          // fixed-height strip clips the chips at large text scales.
          padding: const EdgeInsets.only(bottom: Space.md),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Space.gutter),
            child: Row(
              children: [
                for (final label in labels) ...[
                  ActionChip(
                    label: Text(label),
                    onPressed: onEdit,
                    backgroundColor: palette.accentSoft,
                    side: BorderSide(color: palette.accent.withValues(alpha: 0.3)),
                    labelStyle: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: palette.accent),
                  ),
                  const SizedBox(width: Space.sm),
                ],
                ActionChip(
                  avatar: Icon(Icons.close, size: 14, color: palette.inkSecondary),
                  label: const Text('Clear'),
                  onPressed: onClear,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<List<String>> _labels() async {
    final labels = <String>[];
    if (filter.from != null || filter.to != null) labels.add(_dateLabel());
    for (final bucket in filter.buckets) {
      labels.add(bucket.label);
    }
    if (filter.typeIds.isNotEmpty) {
      final types = await db.allTypes();
      labels.addAll(
        types.where((t) => filter.typeIds.contains(t.id)).map((t) => t.name),
      );
    }
    if (filter.tagIds.isNotEmpty) {
      final tags = await db.allTags();
      final names =
          tags.where((t) => filter.tagIds.contains(t.id)).map((t) => t.name);
      // The AND/OR distinction is invisible with one tag, so it is only stated
      // when it actually changes the result.
      labels.add(filter.tagIds.length > 1
          ? '${filter.tagMode.label} ${names.join(', ')}'
          : names.join(', '));
    }
    if (filter.medium != null) {
      labels.add(filter.medium == Medium.audio ? 'Audio' : 'Video');
    }
    for (final band in filter.bands) {
      labels.add(band.label);
    }
    if (filter.favouritesOnly) labels.add('Favourites');
    return labels;
  }

  String _dateLabel() {
    String d(DateTime v) => '${v.day}/${v.month}/${v.year % 100}';
    final from = filter.from;
    final to = filter.to;
    if (from != null && to != null) {
      // `to` is stored exclusive; show the inclusive day the user picked.
      final inclusive = to.subtract(const Duration(days: 1));
      return d(from) == d(inclusive) ? d(from) : '${d(from)} – ${d(inclusive)}';
    }
    return from != null ? 'From ${d(from)}' : 'Until ${d(to!)}';
  }
}

/// One flattened row, so the list stays lazy even with day headings in it.
sealed class _Row {
  const _Row();
}

class _DayHeading extends _Row {
  const _DayHeading(this.day, this.count);

  final DateTime day;
  final int count;
}

class _EntryRow extends _Row {
  const _EntryRow(this.item);

  final LibraryItem item;
}

class _LibraryList extends StatelessWidget {
  const _LibraryList({
    required this.items,
    required this.onTap,
    required this.grouped,
  });

  final List<LibraryItem> items;
  final void Function(LibraryItem) onTap;
  final bool grouped;

  List<_Row> _flatten() {
    if (!grouped) {
      return [for (final item in items) _EntryRow(item)];
    }
    final rows = <_Row>[];
    DateTime? current;
    var index = 0;
    while (index < items.length) {
      final at = items[index].entry.recordedAt;
      final day = DateTime(at.year, at.month, at.day);
      if (current == null || day != current) {
        // Count this day's run so the heading can show it.
        var run = 0;
        for (var j = index; j < items.length; j++) {
          final other = items[j].entry.recordedAt;
          if (DateTime(other.year, other.month, other.day) != day) break;
          run++;
        }
        rows.add(_DayHeading(day, run));
        current = day;
      }
      rows.add(_EntryRow(items[index]));
      index++;
    }
    return rows;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _flatten();
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 112),
      itemCount: rows.length,
      itemBuilder: (context, index) => switch (rows[index]) {
        _DayHeading(:final day, :final count) =>
          _DayHeadingView(day: day, count: count),
        _EntryRow(:final item) => Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.sm,
            ),
            child: EntryListTile(
              item: item,
              onTap: () => onTap(item),
              underDayHeading: grouped,
            ),
          ),
      },
    );
  }
}

class _DayHeadingView extends StatelessWidget {
  const _DayHeadingView({required this.day, required this.count});

  final DateTime day;
  final int count;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.lg,
        Space.gutter,
        Space.md,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(formatDayHeading(day), style: CairnType.eyebrow(palette)),
          const SizedBox(width: Space.md),
          Expanded(child: Divider(color: palette.hairline, height: 1)),
          const SizedBox(width: Space.md),
          Text('$count', style: CairnType.eyebrow(palette)),
        ],
      ),
    );
  }
}

class _LibraryGrid extends StatelessWidget {
  const _LibraryGrid({required this.items, required this.onTap});

  final List<LibraryItem> items;
  final void Function(LibraryItem) onTap;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(
        Space.gutter,
        Space.xs,
        Space.gutter,
        112,
      ),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 210,
        mainAxisSpacing: Space.md,
        crossAxisSpacing: Space.md,
        childAspectRatio: 0.78,
      ),
      itemCount: items.length,
      itemBuilder: (context, index) => EntryGridTile(
        item: items[index],
        onTap: () => onTap(items[index]),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.filtered,
    required this.searching,
    required this.onClear,
    required this.onRecord,
  });

  final bool filtered;
  final bool searching;
  final VoidCallback onClear;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;

    return SingleChildScrollView(
      // Scrollable so the illustration and CTA survive a large text scale in a
      // short viewport instead of overflowing.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Space.xxl, Space.huge, Space.xxl, 0),
        child: Column(
          children: [
            if (!filtered)
              // The trail metaphor, drawn rather than iconified.
              const CairnScene(size: 92)
            else
              Icon(Icons.search_off, size: 44, color: palette.inkTertiary),
            const SizedBox(height: Space.xl),
            Text(
              filtered
                  ? (searching ? 'No matches' : 'Nothing in this view')
                  : 'Leave your first marker',
              textAlign: TextAlign.center,
              style: text.headlineSmall,
            ),
            const SizedBox(height: Space.md),
            Text(
              filtered
                  ? 'Try widening the filters, or clearing them.'
                  : 'A spoken thought, a practice run, a moment worth keeping. '
                      'It stays on this phone, and it will be easy to find '
                      'again.',
              textAlign: TextAlign.center,
              style: text.bodyMedium,
            ),
            const SizedBox(height: Space.xl),
            if (filtered)
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 18),
                label: const Text('Clear filters'),
              )
            else
              FilledButton(
                onPressed: onRecord,
                child: const Text('Record your first entry'),
              ),
            const SizedBox(height: Space.huge),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xxl),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 36, color: palette.danger),
            const SizedBox(height: Space.lg),
            Text('Could not load the library', style: text.headlineSmall),
            const SizedBox(height: Space.sm),
            // Shown verbatim: this is an offline app with no crash reporting, so
            // the message on screen is the only diagnostic anyone will get.
            Text('$error', textAlign: TextAlign.center, style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}
