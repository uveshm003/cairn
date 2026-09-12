/// Entry detail (requirements.md §13): player, metadata, tags, note, edit,
/// favourite, delete, and the "space saved" stat.
///
/// Laid out as a page rather than a form: the media sits at the top, the title
/// is set in the display serif, and the note reads as prose. The technical
/// metadata is real and worth keeping, but it goes last — an entry is something
/// you made, not a file you inspect.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';
import '../widgets/formatting.dart';
import '../widgets/marker_review.dart';
import '../widgets/media_preview.dart';
import '../widgets/tag_editor.dart';

class EntryDetailScreen extends StatefulWidget {
  const EntryDetailScreen({super.key, required this.entryId});

  final int entryId;

  @override
  State<EntryDetailScreen> createState() => _EntryDetailScreenState();
}

class _EntryDetailScreenState extends State<EntryDetailScreen> {
  bool _editing = false;
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();
  List<String> _tagNames = [];

  /// Held here, not built in `build()`.
  ///
  /// `watchEntry` and `watchMarkers` hand back a *new* Stream on every call, so
  /// creating them inline made every `setState` on this screen -- entering edit
  /// mode, typing a tag -- tear down both subscriptions and re-run both queries.
  /// `StreamBuilder` keeps its snapshot data across a resubscribe, so nothing
  /// flickered; it was simply query churn on the one screen that also drives a
  /// player.
  Stream<EntryRow?>? _entryStream;
  Stream<List<MarkerRow>>? _markerStream;

  /// The type lookup, memoised by the id it was made for. The type *can* change
  /// (edit mode offers it), so a plain field would go stale.
  int? _typeFutureFor;
  Future<EntryTypeRow>? _typeFuture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // First legal moment to reach AppScope. Both streams key off widget.entryId,
    // which never changes for a given screen, so they are created once.
    final db = AppScope.of(context).db;
    _entryStream ??= db.watchEntry(widget.entryId);
    _markerStream ??= db.watchMarkers(widget.entryId);
  }

  Future<EntryTypeRow> _typeFor(CairnDatabase db, int typeId) {
    if (_typeFutureFor != typeId || _typeFuture == null) {
      _typeFutureFor = typeId;
      _typeFuture = db.typeById(typeId);
    }
    return _typeFuture!;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _startEditing(EntryRow entry) async {
    final db = AppScope.of(context).db;
    final tagIds = await db.tagIdsFor(entry.id);
    final allTags = await db.allTags();
    if (!mounted) return;
    setState(() {
      _titleController.text = entry.title ?? '';
      _noteController.text = entry.note ?? '';
      _tagNames = allTags
          .where((t) => tagIds.contains(t.id))
          .map((t) => t.name)
          .toList();
      _editing = true;
    });
  }

  Future<void> _saveEdits(EntryRow entry) async {
    final db = AppScope.of(context).db;
    final title = _titleController.text.trim();
    final note = _noteController.text.trim();

    await db.updateEntryFields(
      entry.id,
      EntriesCompanion(
        title: Value(title.isEmpty ? null : title),
        note: Value(note.isEmpty ? null : note),
      ),
    );

    final ids = <int>[];
    for (final name in _tagNames) {
      ids.add((await db.ensureTag(name)).id);
    }
    await db.setEntryTags(entry.id, ids);
    if (mounted) setState(() => _editing = false);
  }

  Future<void> _delete(EntryRow entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to trash?'),
        content: const Text(
          'It stays in the trash so you can restore it, and the file is only '
          'removed when the trash is emptied.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move to trash'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await AppScope.of(context).db.moveToTrash(entry.id);
    if (mounted) Navigator.of(context).pop();
  }

  /// A marker kept through review but wrong on reflection. Deleting one is not
  /// worth a confirmation -- it is a timestamp, and re-adding means re-recording
  /// only in the sense that the original tap is gone.
  Future<void> _removeMarker(MarkerRow marker) async {
    await AppScope.of(context).db.deleteMarker(marker.id);
  }

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return StreamBuilder<EntryRow?>(
      stream: _entryStream,
      builder: (context, snapshot) {
        final entry = snapshot.data;
        if (entry == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Text(
                snapshot.hasData ? 'This entry is gone.' : '',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          );
        }
        return _buildDetail(context, scope, entry);
      },
    );
  }

  Widget _buildDetail(BuildContext context, AppScope scope, EntryRow entry) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;

    return FutureBuilder<EntryTypeRow>(
      future: _typeFor(scope.db, entry.typeId),
      builder: (context, typeSnapshot) {
        final type = typeSnapshot.data;
        final typeName = type?.name ?? '';
        final accent =
            type == null ? palette.accent : palette.typeColor(type.colorKey);
        final missing = !scope.store.existsRelative(entry.filePath);

        return Scaffold(
          backgroundColor: palette.canvas,
          appBar: AppBar(
            title: Text(_editing ? 'Edit' : '', style: text.titleMedium),
            actions: _editing
                ? [
                    TextButton(
                      onPressed: () => setState(() => _editing = false),
                      child: const Text('Cancel'),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(right: Space.sm),
                      child: TextButton(
                        onPressed: () => _saveEdits(entry),
                        child: const Text('Done'),
                      ),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: entry.isFavorite
                          ? 'Remove from favourites'
                          : 'Add to favourites',
                      icon: Icon(
                        entry.isFavorite
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: entry.isFavorite ? palette.accent : palette.ink,
                      ),
                      onPressed: () =>
                          scope.db.setFavorite(entry.id, !entry.isFavorite),
                    ),
                    IconButton(
                      tooltip: 'Edit',
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _startEditing(entry),
                    ),
                    IconButton(
                      tooltip: 'Move to trash',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () => _delete(entry),
                    ),
                    const SizedBox(width: Space.xs),
                  ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(
              Space.gutter,
              0,
              Space.gutter,
              Space.huge,
            ),
            children: [
              if (missing)
                // §9's orphan case, stated honestly rather than shown as a
                // broken player: the row survived but its file did not.
                _Notice(
                  icon: Icons.link_off,
                  message: 'The media file for this entry is missing. Its note '
                      'and tags are intact, but there is nothing to play.',
                )
              else
                // Watched rather than read once, so removing a marker in edit
                // mode updates the ticks and the jump row immediately.
                StreamBuilder<List<MarkerRow>>(
                  stream: _markerStream,
                  builder: (context, snapshot) {
                    final markers = snapshot.data ?? const <MarkerRow>[];
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        MediaPreview(
                          // Resolved from the stored relative path (§9).
                          path: scope.store.resolve(entry.filePath),
                          medium: entry.medium,
                          durationMs: entry.durationMs,
                          markerOffsetsMs:
                              markers.map((m) => m.offsetMs).toList(),
                          amplitudeEnvelope: entry.amplitudeEnvelope,
                          // The detail screen is where an entry gets *replayed*,
                          // so this is the one place the transport row belongs.
                          transport: true,
                        ),
                        // Removal lives behind edit mode rather than on the
                        // playback chips: those are for jumping, and a delete
                        // affordance beside a seek target invites the wrong tap.
                        if (_editing && markers.isNotEmpty) ...[
                          const SizedBox(height: Space.lg),
                          MarkerReview(
                            offsetsMs:
                                markers.map((m) => m.offsetMs).toList(),
                            enabled: true,
                            onRemove: (offset) => _removeMarker(
                              markers.firstWhere((m) => m.offsetMs == offset),
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              const SizedBox(height: Space.xl),

              if (_editing) ...[
                TextField(
                  controller: _titleController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    hintText: autoTitle(typeName, entry.recordedAt),
                  ),
                ),
                const SizedBox(height: Space.lg),
                TextField(
                  controller: _noteController,
                  minLines: 4,
                  maxLines: 10,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: Space.xl),
                TagEditor(
                  selected: _tagNames,
                  onChanged: (tags) => setState(() => _tagNames = tags),
                ),
              ] else ...[
                // Type and medium as a quiet caption above the title, so the
                // title itself gets to be the loudest thing on the page.
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration:
                          BoxDecoration(color: accent, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: Space.sm),
                    Text(
                      typeName.toUpperCase(),
                      style: CairnType.eyebrow(palette).copyWith(color: accent),
                    ),
                    const SizedBox(width: Space.md),
                    Icon(iconForMedium(entry.medium),
                        size: 13, color: palette.inkTertiary),
                    const SizedBox(width: Space.xs + 1),
                    Text(
                      entry.medium == Medium.audio ? 'AUDIO' : 'VIDEO',
                      style: CairnType.eyebrow(palette),
                    ),
                  ],
                ),
                const SizedBox(height: Space.md),
                Text(
                  displayTitle(entry, typeName),
                  style: text.headlineMedium,
                ),
                const SizedBox(height: Space.sm),
                Text(
                  formatWhen(entry.recordedAt),
                  style: text.bodySmall?.copyWith(color: palette.inkTertiary),
                ),
                if (entry.note != null && entry.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: Space.xl),
                  Text(entry.note!, style: text.bodyLarge),
                ],
                const SizedBox(height: Space.xl),
                _TagList(entryId: entry.id),
              ],

              const SizedBox(height: Space.xxl),
              _Details(entry: entry),
            ],
          ),
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(Space.lg),
      decoration: BoxDecoration(
        color: palette.dangerSoft,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: Row(
        children: [
          Icon(icon, color: palette.onDangerSoft, size: 20),
          const SizedBox(width: Space.md),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: palette.onDangerSoft,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TagList extends StatelessWidget {
  const _TagList({required this.entryId});

  final int entryId;

  @override
  Widget build(BuildContext context) {
    final db = AppScope.of(context).db;
    return FutureBuilder<List<int>>(
      future: db.tagIdsFor(entryId),
      builder: (context, idSnapshot) {
        final ids = idSnapshot.data;
        if (ids == null || ids.isEmpty) return const SizedBox.shrink();
        return StreamBuilder<List<TagRow>>(
          stream: db.watchTags(),
          builder: (context, tagSnapshot) {
            final tags = (tagSnapshot.data ?? const <TagRow>[])
                .where((t) => ids.contains(t.id));
            if (tags.isEmpty) return const SizedBox.shrink();
            return Wrap(
              spacing: Space.sm,
              runSpacing: Space.sm,
              children: [for (final tag in tags) Chip(label: Text(tag.name))],
            );
          },
        );
      },
    );
  }
}

/// Metadata, with §8's "space saved" given the prominence it earns — it is the
/// evidence behind the app's central claim.
class _Details extends StatelessWidget {
  const _Details({required this.entry});

  final EntryRow entry;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final original = entry.originalSizeBytes;
    final saved = original == null ? 0 : original - entry.fileSizeBytes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (saved > 0) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(Space.lg),
            decoration: BoxDecoration(
              color: palette.accentSoft,
              borderRadius: BorderRadius.circular(Radii.lg),
              border: Border.all(color: palette.accent.withValues(alpha: 0.22)),
            ),
            child: Row(
              children: [
                Icon(Icons.compress, size: 20, color: palette.accent),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${formatBytes(saved)} saved',
                        style: text.titleMedium?.copyWith(color: palette.accent),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${formatBytes(original!)} became '
                        '${formatBytes(entry.fileSizeBytes)} '
                        '(${(saved / original * 100).round()}% smaller)',
                        style: text.bodySmall
                            ?.copyWith(color: palette.inkSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Space.xl),
        ],
        Text('DETAILS', style: CairnType.eyebrow(palette)),
        const SizedBox(height: Space.md),
        _Row(label: 'Length', value: formatDuration(entry.durationMs)),
        _Row(label: 'Size', value: formatBytes(entry.fileSizeBytes)),
        if (entry.width != null && entry.height != null)
          _Row(label: 'Resolution', value: '${entry.width}×${entry.height}'),
        if (entry.codec != null)
          _Row(
            label: 'Codec',
            // Spelled out: "h265" means nothing to most people, and it is the
            // field that explains a playback failure.
            value: switch (entry.codec) {
              'h265' => 'HEVC (H.265)',
              'h264' => 'H.264',
              final other => other ?? '',
            },
          ),
        if (entry.bitrateKbps != null)
          _Row(label: 'Bitrate', value: '${entry.bitrateKbps} kbps'),
        if (entry.latitude != null && entry.longitude != null)
          _Row(
            label: 'Location',
            value: '${entry.latitude!.toStringAsFixed(4)}, '
                '${entry.longitude!.toStringAsFixed(4)}',
          ),
      ],
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm - 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: text.bodySmall?.copyWith(color: palette.inkTertiary),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: text.bodySmall?.copyWith(color: palette.ink),
            ),
          ),
        ],
      ),
    );
  }
}
