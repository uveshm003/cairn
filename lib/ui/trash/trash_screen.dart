/// Trash (requirements.md S13): soft-deleted entries, restore or purge.
///
/// The purge is the only place in the app that permanently destroys user data,
/// so it is the one place that always asks first and always says how much.
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../widgets/formatting.dart';

class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Trash')),
      body: StreamBuilder<List<EntryRow>>(
        stream: scope.db.watchTrash(),
        builder: (context, snapshot) {
          final entries = snapshot.data;
          if (entries == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (entries.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.delete_outline,
                        size: 40, color: theme.colorScheme.outline),
                    const SizedBox(height: 16),
                    Text('Trash is empty', style: theme.textTheme.titleMedium),
                  ],
                ),
              ),
            );
          }

          final totalBytes =
              entries.fold<int>(0, (sum, e) => sum + e.fileSizeBytes);

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        // S9 asks for a "space used by trash" indicator.
                        '${entries.length} '
                        '${entries.length == 1 ? 'entry' : 'entries'} · '
                        '${formatBytes(totalBytes)}',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => _emptyTrash(context, entries),
                      icon: const Icon(Icons.delete_forever_outlined),
                      label: const Text('Empty'),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: entries.length,
                  itemBuilder: (context, index) {
                    final entry = entries[index];
                    return _TrashTile(entry: entry);
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _emptyTrash(
    BuildContext context,
    List<EntryRow> entries,
  ) async {
    final scope = AppScope.of(context);
    final bytes = entries.fold<int>(0, (sum, e) => sum + e.fileSizeBytes);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete permanently?'),
        content: Text(
          'This removes ${entries.length} '
          '${entries.length == 1 ? 'entry' : 'entries'} and frees '
          '${formatBytes(bytes)}. This cannot be undone, and because Cairn is '
          'offline there is no copy anywhere else.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Files first, then rows: a crash between the two leaves a row pointing at
    // a missing file, which the app surfaces and the orphan sweep can repair.
    // The reverse would leave files no row references -- invisible dead weight.
    for (final entry in entries) {
      await scope.pipeline.deleteMediaFor(entry);
      await scope.db.purgeEntry(entry.id);
    }
  }
}

class _TrashTile extends StatelessWidget {
  const _TrashTile({required this.entry});

  final EntryRow entry;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);

    return FutureBuilder<EntryTypeRow>(
      future: scope.db.typeById(entry.typeId),
      builder: (context, snapshot) {
        final typeName = snapshot.data?.name ?? '';
        final deletedAt = entry.deletedAt;
        final retention = scope.settings.trashRetentionDays.value;
        final daysLeft = deletedAt == null
            ? null
            : retention - DateTime.now().difference(deletedAt).inDays;

        return ListTile(
          leading: Icon(iconForMedium(entry.medium)),
          title: Text(
            displayTitle(entry, typeName),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            [
              formatBytes(entry.fileSizeBytes),
              if (daysLeft != null)
                daysLeft <= 0
                    ? 'due to be removed'
                    : 'removed in $daysLeft ${daysLeft == 1 ? 'day' : 'days'}',
            ].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          trailing: TextButton(
            onPressed: () => scope.db.restoreFromTrash(entry.id),
            child: const Text('Restore'),
          ),
        );
      },
    );
  }
}
