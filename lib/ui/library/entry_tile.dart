/// Library rows, in both list and grid form.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../../data/library_queries.dart';
import '../widgets/formatting.dart';

/// Video thumbnail, or a type-coloured placeholder for audio.
///
/// Thumbnails are cached by Flutter's image cache and decoded to the display
/// size rather than full resolution — which is what keeps scrolling smooth at
/// the 1000-entry target in S14.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.item,
    required this.width,
    required this.height,
    this.radius = 12,
  });

  final LibraryItem item;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = colorForKey(item.colorKey, Theme.of(context).brightness);
    final path = item.entry.thumbnailPath;

    Widget placeholder() => Container(
          width: width,
          height: height,
          color: accent.withValues(alpha: 0.14),
          child: Center(
            child: Icon(
              iconForMedium(item.entry.medium),
              color: accent,
              size: width < 80 ? 22 : 32,
            ),
          ),
        );

    Widget child;
    if (path == null) {
      child = placeholder();
    } else {
      // Resolved from the relative path at display time -- never stored
      // absolute (S9).
      final absolute = AppScope.of(context).store.resolve(path);
      child = Image.file(
        File(absolute),
        width: width,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        // A thumbnail that has gone missing should degrade to the placeholder,
        // not to a broken-image icon or an exception.
        errorBuilder: (_, _, _) => placeholder(),
      );
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            child,
            if (item.entry.medium == Medium.video && path != null)
              Positioned(
                right: 4,
                bottom: 4,
                child: _DurationBadge(ms: item.entry.durationMs),
              ),
            if (item.entry.isFavorite)
              Positioned(
                left: 4,
                top: 4,
                child: Icon(Icons.star,
                    size: 16, color: scheme.surface.withValues(alpha: 0.95)),
              ),
          ],
        ),
      ),
    );
  }
}

class _DurationBadge extends StatelessWidget {
  const _DurationBadge({required this.ms});

  final int ms;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.62),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        formatClock(ms),
        style: const TextStyle(color: Colors.white, fontSize: 11),
      ),
    );
  }
}

class EntryListTile extends StatelessWidget {
  const EntryListTile({super.key, required this.item, required this.onTap});

  final LibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = colorForKey(item.colorKey, theme.brightness);
    final entry = item.entry;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Thumbnail(item: item, width: 68, height: 68, radius: 10),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        displayTitle(entry, item.typeName),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Icon(iconForKey(item.iconKey), size: 13, color: accent),
                          const SizedBox(width: 4),
                          Text(item.typeName,
                              style: theme.textTheme.labelSmall
                                  ?.copyWith(color: accent)),
                          Text('  ·  ', style: theme.textTheme.labelSmall),
                          Expanded(
                            child: Text(
                              '${formatDuration(entry.durationMs)}  ·  '
                              '${formatWhen(entry.recordedAt)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (item.tagNames.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        _TagRow(tags: item.tagNames),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class EntryGridTile extends StatelessWidget {
  const EntryGridTile({super.key, required this.item, required this.onTap});

  final LibraryItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = colorForKey(item.colorKey, theme.brightness);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) => _Thumbnail(
                  item: item,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  radius: 16,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    displayTitle(item.entry, item.typeName),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Icon(iconForKey(item.iconKey), size: 12, color: accent),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          formatDuration(item.entry.durationMs),
                          maxLines: 1,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Two tags plus an overflow count, rather than wrapping and pushing the
    // row height around as the user scrolls.
    final shown = tags.take(2).toList();
    final extra = tags.length - shown.length;

    return Row(
      children: [
        for (final tag in shown)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(tag,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ),
          ),
        if (extra > 0)
          Text('+$extra',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.outline)),
      ],
    );
  }
}
