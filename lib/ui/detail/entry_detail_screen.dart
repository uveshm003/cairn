/// Entry detail (requirements.md S13): player, metadata, tags, note, edit,
/// favourite, delete, and the "space saved" stat.
library;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../widgets/formatting.dart';
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
  bool _loadedTags = false;

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
      _loadedTags = true;
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
      final tag = await db.ensureTag(name);
      ids.add(tag.id);
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

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);

    return StreamBuilder<EntryRow?>(
      stream: scope.db.watchEntry(widget.entryId),
      builder: (context, snapshot) {
        final entry = snapshot.data;
        if (entry == null) {
          return Scaffold(
            appBar: AppBar(),
            body: Center(
              child: Text(snapshot.hasData
                  ? 'This entry is gone.'
                  : 'Loading…'),
            ),
          );
        }
        return _buildDetail(context, scope, entry);
      },
    );
  }

  Widget _buildDetail(BuildContext context, AppScope scope, EntryRow entry) {
    final theme = Theme.of(context);

    return FutureBuilder<EntryTypeRow>(
      future: scope.db.typeById(entry.typeId),
      builder: (context, typeSnapshot) {
        final type = typeSnapshot.data;
        final typeName = type?.name ?? '';
        final missing = !scope.store.existsRelative(entry.filePath);

        return Scaffold(
          appBar: AppBar(
            title: Text(
              _editing ? 'Edit entry' : displayTitle(entry, typeName),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            actions: _editing
                ? [
                    TextButton(
                      onPressed: () => setState(() => _editing = false),
                      child: const Text('Cancel'),
                    ),
                    TextButton(
                      onPressed: () => _saveEdits(entry),
                      child: const Text('Save'),
                    ),
                  ]
                : [
                    IconButton(
                      tooltip: entry.isFavorite
                          ? 'Remove from favourites'
                          : 'Add to favourites',
                      icon: Icon(
                        entry.isFavorite ? Icons.star : Icons.star_border,
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
                  ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
            children: [
              if (missing)
                // S9's orphan case, surfaced honestly instead of as a broken
                // player: the row survived but its file did not.
                Container(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.link_off,
                          color: theme.colorScheme.onErrorContainer),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'The media file for this entry is missing. Its notes '
                          'and tags are intact, but there is nothing to play.',
                          style: TextStyle(
                            color: theme.colorScheme.onErrorContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                MediaPreview(
                  // Resolved from the stored relative path (S9).
                  path: scope.store.resolve(entry.filePath),
                  medium: entry.medium,
                  durationMs: entry.durationMs,
                ),
              const SizedBox(height: 20),
              if (_editing && _loadedTags) ...[
                TextField(
                  controller: _titleController,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Title',
                    hintText: autoTitle(typeName, entry.recordedAt),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _noteController,
                  minLines: 3,
                  maxLines: 8,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Note',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 20),
                TagEditor(
                  selected: _tagNames,
                  onChanged: (tags) => setState(() => _tagNames = tags),
                ),
              ] else ...[
                if (type != null)
                  Row(
                    children: [
                      Icon(
                        iconForKey(type.iconKey),
                        size: 16,
                        color: colorForKey(type.colorKey, theme.brightness),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        type.name,
                        style: theme.textTheme.labelLarge?.copyWith(
                          color: colorForKey(type.colorKey, theme.brightness),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(iconForMedium(entry.medium),
                          size: 14, color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        entry.medium == Medium.audio ? 'Audio' : 'Video',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                Text(formatWhen(entry.recordedAt),
                    style: theme.textTheme.bodyMedium),
                if (entry.note != null && entry.note!.trim().isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(entry.note!, style: theme.textTheme.bodyLarge),
                ],
                const SizedBox(height: 16),
                _TagList(entryId: entry.id),
              ],
              const SizedBox(height: 24),
              _MetadataCard(entry: entry),
            ],
          ),
        );
      },
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
            final tags =
                (tagSnapshot.data ?? const <TagRow>[]).where((t) => ids.contains(t.id));
            if (tags.isEmpty) return const SizedBox.shrink();
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in tags) Chip(label: Text(tag.name)),
              ],
            );
          },
        );
      },
    );
  }
}

/// The metadata block, including S8's "space saved" stat.
class _MetadataCard extends StatelessWidget {
  const _MetadataCard({required this.entry});

  final EntryRow entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final original = entry.originalSizeBytes;
    final saved = original == null ? 0 : original - entry.fileSizeBytes;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('DETAILS',
                style: theme.textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  color: theme.colorScheme.onSurfaceVariant,
                )),
            const SizedBox(height: 12),
            _Row(label: 'Length', value: formatDuration(entry.durationMs)),
            _Row(label: 'Size', value: formatBytes(entry.fileSizeBytes)),
            if (saved > 0)
              _Row(
                label: 'Space saved',
                value: '${formatBytes(saved)} '
                    '(${(saved / original! * 100).round()}%)',
                emphasise: true,
              ),
            if (entry.width != null && entry.height != null)
              _Row(
                label: 'Resolution',
                value: '${entry.width}x${entry.height}',
              ),
            if (entry.codec != null)
              _Row(
                label: 'Codec',
                // Spelled out: "h265" on a spec sheet means nothing to most
                // people, and it is the field that explains a playback failure.
                value: switch (entry.codec) {
                  'h265' => 'HEVC (H.265)',
                  'h264' => 'H.264',
                  final other => other ?? '',
                },
              ),
            if (entry.bitrateKbps != null)
              _Row(label: 'Bitrate', value: '${entry.bitrateKbps} kbps'),
            _Row(
              label: 'Recorded',
              value: formatDateOnly(entry.recordedAt),
            ),
            if (entry.latitude != null && entry.longitude != null)
              _Row(
                label: 'Location',
                value: '${entry.latitude!.toStringAsFixed(4)}, '
                    '${entry.longitude!.toStringAsFixed(4)}',
              ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                )),
          ),
          Expanded(
            child: Text(
              value,
              style: emphasise
                  ? theme.textTheme.bodyMedium
                      ?.copyWith(fontWeight: FontWeight.w600)
                  : theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
