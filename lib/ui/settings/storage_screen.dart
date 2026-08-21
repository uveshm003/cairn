/// Storage usage (requirements.md S9: "surface storage usage — total, by type,
/// by tag — it's both useful and on-brand for the compression story").
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/library_queries.dart';
import '../widgets/formatting.dart';

class StorageScreen extends StatelessWidget {
  const StorageScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Storage')),
      body: FutureBuilder<StorageBreakdown>(
        future: scope.db.storageBreakdown(),
        builder: (context, snapshot) {
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: CircularProgressIndicator());
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(formatBytes(data.totalBytes),
                          style: theme.textTheme.headlineMedium),
                      const SizedBox(height: 4),
                      Text(
                        '${data.entryCount} '
                        '${data.entryCount == 1 ? 'entry' : 'entries'}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      if (data.savedBytes > 0) ...[
                        const Divider(height: 28),
                        Row(
                          children: [
                            Icon(Icons.compress,
                                size: 18, color: theme.colorScheme.primary),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                '${formatBytes(data.savedBytes)} saved by '
                                'compression '
                                '(${(data.savedFraction * 100).round()}%)',
                                style: theme.textTheme.bodyMedium,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text(
                          // Honest about scope: only entries that recorded an
                          // original size contribute, so this under-reports
                          // rather than inventing a saving.
                          'Measured against the size these recordings were '
                          'before compressing, where that was recorded.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (data.trashBytes > 0) ...[
                const SizedBox(height: 16),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text('${formatBytes(data.trashBytes)} in the trash'),
                    subtitle: const Text(
                      'Still on disk until the trash is emptied',
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Text('BY TYPE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.1,
                    color: theme.colorScheme.onSurfaceVariant,
                  )),
              const SizedBox(height: 12),
              if (data.byType.isEmpty)
                Text('Nothing recorded yet.',
                    style: theme.textTheme.bodyMedium)
              else
                for (final entry in data.byType.entries)
                  _TypeBar(
                    label: entry.key,
                    bytes: entry.value,
                    // Relative to the largest type, so the longest bar fills
                    // the row -- a share-of-total bar would be unreadably
                    // short for everything but the biggest.
                    fraction: data.byType.values.isEmpty
                        ? 0
                        : entry.value / data.byType.values.reduce(
                            (a, b) => a > b ? a : b,
                          ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class _TypeBar extends StatelessWidget {
  const _TypeBar({
    required this.label,
    required this.bytes,
    required this.fraction,
  });

  final String label;
  final int bytes;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
              Text(formatBytes(bytes), style: theme.textTheme.bodySmall),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: fraction.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
