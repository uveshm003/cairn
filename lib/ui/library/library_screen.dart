/// The library (requirements.md S13): list/grid, filter bar, search, and the
/// capture FAB.
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
import '../trash/trash_screen.dart';
import 'entry_tile.dart';
import 'filter_sheet.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;

  EntryFilter _filter = EntryFilter.empty;
  bool _searching = false;
  bool _restored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restored) return;
    _restored = true;
    // S12: persist the last-used filter set.
    _filter = AppScope.of(context).settings.lastFilter.value;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  /// S12 wants debounced live results — re-querying on every keystroke would
  /// fire an FTS query per character.
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), () {
      if (mounted) setState(() => _filter = _filter.copyWith(searchText: value));
    });
  }

  Future<void> _openFilterSheet() async {
    final scope = AppScope.of(context);
    final updated = await showFilterSheet(
      context,
      db: scope.db,
      current: _filter,
    );
    if (updated == null || !mounted) return;
    setState(() => _filter = updated);
    await scope.settings.saveFilter(updated);
  }

  void _clearFacets() {
    final cleared = _filter.clearedFacets();
    setState(() => _filter = cleared);
    AppScope.of(context).settings.saveFilter(cleared);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _searchController,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onChanged: _onSearchChanged,
                decoration: const InputDecoration(
                  hintText: 'Search titles, notes, tags',
                  border: InputBorder.none,
                  filled: false,
                ),
              )
            : const Text('Cairn'),
        actions: [
          if (_searching)
            IconButton(
              tooltip: 'Close search',
              icon: const Icon(Icons.close),
              onPressed: () {
                _debounce?.cancel();
                _searchController.clear();
                setState(() {
                  _searching = false;
                  _filter = _filter.copyWith(searchText: '');
                });
              },
            )
          else ...[
            IconButton(
              tooltip: 'Search',
              icon: const Icon(Icons.search),
              onPressed: () => setState(() => _searching = true),
            ),
            ValueListenableBuilder(
              valueListenable: settings.gridView,
              builder: (context, grid, _) => IconButton(
                tooltip: grid ? 'Show as list' : 'Show as grid',
                icon: Icon(grid ? Icons.view_list : Icons.grid_view),
                onPressed: () => settings.setGridView(!grid),
              ),
            ),
            _FilterButton(
              count: _filter.activeFacetCount,
              onPressed: _openFilterSheet,
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
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
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'trash', child: Text('Trash')),
                PopupMenuItem(value: 'settings', child: Text('Settings')),
              ],
            ),
          ],
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => startCapture(context),
        icon: const Icon(Icons.fiber_manual_record),
        label: const Text('Record'),
      ),
      body: Column(
        children: [
          if (_filter.activeFacetCount > 0)
            _ActiveFilterChips(
              filter: _filter,
              db: scope.db,
              onClear: _clearFacets,
            ),
          Expanded(
            child: StreamBuilder<List<LibraryItem>>(
              stream: scope.db.watchLibrary(_filter),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _ErrorState(error: snapshot.error!);
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final items = snapshot.data!;
                if (items.isEmpty) {
                  // S10: the empty state teaches the first action rather than
                  // showing a blank screen.
                  return _EmptyState(
                    filtered: _filter.isActive,
                    onClear: _clearFacets,
                    onRecord: () => startCapture(context),
                  );
                }
                return ValueListenableBuilder(
                  valueListenable: settings.gridView,
                  builder: (context, grid, _) => grid
                      ? _LibraryGrid(items: items, onTap: _openEntry)
                      : _LibraryList(items: items, onTap: _openEntry),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  void _openEntry(LibraryItem item) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => EntryDetailScreen(entryId: item.entry.id),
    ));
  }
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: 'Filter',
      onPressed: onPressed,
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        backgroundColor: scheme.primary,
        child: const Icon(Icons.tune),
      ),
    );
  }
}

/// S12: "show active-filter chips with one-tap clear."
class _ActiveFilterChips extends StatelessWidget {
  const _ActiveFilterChips({
    required this.filter,
    required this.db,
    required this.onClear,
  });

  final EntryFilter filter;
  final CairnDatabase db;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<String>>(
      future: _labels(),
      builder: (context, snapshot) {
        final labels = snapshot.data ?? const <String>[];
        if (labels.isEmpty) return const SizedBox.shrink();
        return SizedBox(
          height: 52,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              for (final label in labels)
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 8, bottom: 8),
                  child: Chip(label: Text(label)),
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: ActionChip(
                  avatar: const Icon(Icons.close, size: 16),
                  label: const Text('Clear'),
                  onPressed: onClear,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<List<String>> _labels() async {
    final labels = <String>[];

    if (filter.from != null || filter.to != null) {
      labels.add(_dateLabel());
    }
    for (final bucket in filter.buckets) {
      labels.add(bucket.label);
    }
    if (filter.typeIds.isNotEmpty) {
      final types = await db.allTypes();
      final names = types
          .where((t) => filter.typeIds.contains(t.id))
          .map((t) => t.name);
      labels.addAll(names);
    }
    if (filter.tagIds.isNotEmpty) {
      final tags = await db.allTags();
      final names =
          tags.where((t) => filter.tagIds.contains(t.id)).map((t) => t.name);
      // The AND/OR distinction is invisible with one tag, so only say it when
      // it actually changes the result.
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
    final from = filter.from;
    final to = filter.to;
    String d(DateTime value) =>
        '${value.day}/${value.month}/${value.year % 100}';
    if (from != null && to != null) {
      // `to` is stored exclusive; show the inclusive day the user picked.
      final inclusive = to.subtract(const Duration(days: 1));
      return d(from) == d(inclusive)
          ? d(from)
          : '${d(from)} – ${d(inclusive)}';
    }
    if (from != null) return 'From ${d(from)}';
    return 'Until ${d(to!)}';
  }
}

class _LibraryList extends StatelessWidget {
  const _LibraryList({required this.items, required this.onTap});

  final List<LibraryItem> items;
  final void Function(LibraryItem) onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 96, top: 4),
      // itemCount + builder keeps this lazy, which is what holds up at the
      // 1000-entry target in S14.
      itemCount: items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 4),
      itemBuilder: (context, index) => EntryListTile(
        item: items[index],
        onTap: () => onTap(items[index]),
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
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.82,
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
    required this.onClear,
    required this.onRecord,
  });

  final bool filtered;
  final VoidCallback onClear;
  final VoidCallback onRecord;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              filtered ? Icons.filter_alt_off_outlined : Icons.graphic_eq,
              size: 48,
              color: theme.colorScheme.outline,
            ),
            const SizedBox(height: 20),
            Text(
              filtered ? 'Nothing matches' : 'Nothing here yet',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              filtered
                  ? 'No entries match these filters. Try widening them.'
                  : 'Record a thought, a practice run, or a moment worth '
                      'keeping. It stays on this phone.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            if (filtered)
              OutlinedButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.close),
                label: const Text('Clear filters'),
              )
            else
              FilledButton.icon(
                onPressed: onRecord,
                icon: const Icon(Icons.fiber_manual_record),
                label: const Text('Record your first entry'),
              ),
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
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text('Could not load the library',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            // Shown verbatim rather than swallowed: this is an offline app with
            // no crash reporting, so the message on screen is the only
            // diagnostic anyone will ever get.
            Text('$error',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}
