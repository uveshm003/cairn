/// Library rows, in list and grid form.
///
/// The hierarchy is deliberate: title first, then a single quiet meta line, then
/// tags. Everything else an entry knows (codec, bitrate, resolution) belongs on
/// the detail screen — putting it here would turn a journal into a file manager.
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../../data/library_queries.dart';
import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';
import '../widgets/formatting.dart';

/// Video thumbnail, or a type-tinted placeholder for audio.
///
/// Decoded to display size rather than full resolution, which is what keeps
/// scrolling smooth at §14's 1000-entry target.
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.item,
    required this.width,
    required this.height,
    this.radius = Radii.md,
  });

  final LibraryItem item;
  final double width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accent = palette.typeColor(item.colorKey);
    final path = item.entry.thumbnailPath;
    final compact = width < 100;

    Widget placeholder() => Container(
          width: width,
          height: height,
          color: accent.withValues(alpha: palette.isDark ? 0.16 : 0.11),
          child: Center(
            child: item.entry.medium == Medium.audio
                // Audio has no frame to show, so it gets a small waveform mark
                // instead of a generic microphone glyph.
                ? _WaveGlyph(color: accent, size: compact ? 20 : 30)
                : Icon(
                    Icons.videocam_outlined,
                    color: accent,
                    size: compact ? 20 : 28,
                  ),
          ),
        );

    Widget child;
    if (path == null) {
      child = placeholder();
    } else {
      // Resolved from the stored relative path at display time (§9).
      final absolute = AppScope.of(context).store.resolve(path);
      child = Image.file(
        File(absolute),
        width: width,
        height: height,
        fit: BoxFit.cover,
        cacheWidth: (width * MediaQuery.devicePixelRatioOf(context)).round(),
        // A missing thumbnail degrades to the placeholder, not a broken-image
        // glyph or an exception.
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
            if (item.entry.isFavorite)
              Positioned(
                left: 6,
                top: 6,
                child: _Pip(child: Icon(Icons.star_rounded, size: 12, color: palette.accent)),
              ),
            Positioned(
              right: 6,
              bottom: 6,
              child: _Pip(
                child: Text(
                  formatClock(item.entry.durationMs),
                  style: const TextStyle(
                    fontFamily: CairnType.body,
                    color: Colors.white,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                    height: 1.1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small dark capsule for overlays on top of imagery, which can be any colour.
class _Pip extends StatelessWidget {
  const _Pip({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2.5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(Radii.sm - 2),
      ),
      child: child,
    );
  }
}

/// Three bars, tallest in the middle. Reads as audio without borrowing the
/// microphone icon that already means "record".
class _WaveGlyph extends StatelessWidget {
  const _WaveGlyph({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bar = size / 7;
    return SizedBox(
      height: size,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          for (final scale in const [0.45, 0.8, 1.0, 0.65, 0.35])
            Padding(
              padding: EdgeInsets.symmetric(horizontal: bar * 0.35),
              child: Container(
                width: bar,
                height: size * scale,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(bar),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class EntryListTile extends StatelessWidget {
  const EntryListTile({
    super.key,
    required this.item,
    required this.onTap,
    this.underDayHeading = false,
  });

  final LibraryItem item;
  final VoidCallback onTap;

  /// When the row sits under a day heading, the meta line drops the date and
  /// shows only the time — the heading already said which day it was.
  final bool underDayHeading;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final accent = palette.typeColor(item.colorKey);
    final entry = item.entry;

    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: palette.hairline),
          ),
          padding: const EdgeInsets.all(Space.md - 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Thumbnail(item: item, width: 76, height: 76, radius: Radii.md),
              const SizedBox(width: Space.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: Space.xxs),
                    Text(
                      displayTitle(entry, item.typeName),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleMedium,
                    ),
                    const SizedBox(height: 5),
                    _MetaLine(
                      typeName: item.typeName,
                      accent: accent,
                      entry: entry,
                      timeOnly: underDayHeading,
                    ),
                    if (item.tagNames.isNotEmpty) ...[
                      const SizedBox(height: Space.sm),
                      _TagRow(tags: item.tagNames),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Type mark, then time. A dot rather than an icon per type keeps the row calm —
/// five different glyphs down a scrolling list is noise.
class _MetaLine extends StatelessWidget {
  const _MetaLine({
    required this.typeName,
    required this.accent,
    required this.entry,
    required this.timeOnly,
  });

  final String typeName;
  final Color accent;
  final EntryRow entry;
  final bool timeOnly;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
          color: palette.inkTertiary,
        );

    // Wrap, not Row: at a large text scale (§14) a fixed row clips the time.
    // Flowing lets the card grow a line instead of hiding content.
    //
    // Every text child is also individually shrinkable. A Wrap constrains its
    // children to the run width but does not force them narrower, so a child
    // that cannot shrink still overflows — which is exactly what happened on a
    // 320pt screen at 2x.
    return LayoutBuilder(
      builder: (context, constraints) => Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: Space.sm,
        runSpacing: 2,
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  decoration:
                      BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: Space.sm - 2),
                Flexible(
                  child: Text(
                    typeName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: accent,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth),
            child: Text(
              timeOnly
                  ? formatTimeOnly(entry.recordedAt)
                  : formatWhen(entry.recordedAt),
              style: style,
            ),
          ),
        ],
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
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final accent = palette.typeColor(item.colorKey);

    return Material(
      color: palette.surface,
      borderRadius: BorderRadius.circular(Radii.lg),
      child: InkWell(
        borderRadius: BorderRadius.circular(Radii.lg),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.lg),
            border: Border.all(color: palette.hairline),
          ),
          padding: const EdgeInsets.all(Space.sm - 1),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) => _Thumbnail(
                    item: item,
                    width: constraints.maxWidth,
                    height: constraints.maxHeight,
                    radius: Radii.md,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  Space.xs,
                  Space.sm,
                  Space.xs,
                  Space.xs,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayTitle(item.entry, item.typeName),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall,
                    ),
                    const SizedBox(height: Space.xs),
                    Row(
                      children: [
                        Container(
                          width: 5,
                          height: 5,
                          decoration: BoxDecoration(
                            color: accent,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            item.typeName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.labelSmall?.copyWith(
                              color: palette.inkTertiary,
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
      ),
    );
  }
}

/// Two tags plus an overflow count. Wraps rather than clipping, so a large
/// text scale grows the card instead of hiding tags (§14).
class _TagRow extends StatelessWidget {
  const _TagRow({required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final text = Theme.of(context).textTheme;
    final shown = tags.take(2).toList();
    final extra = tags.length - shown.length;

    return Wrap(
      spacing: Space.xs + 1,
      runSpacing: Space.xs + 1,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in shown)
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 3),
            decoration: BoxDecoration(
              color: palette.surfaceSunken,
              borderRadius: BorderRadius.circular(Radii.pill),
            ),
            child: Text(
              tag,
              style: text.labelSmall?.copyWith(color: palette.inkSecondary),
            ),
          ),
        if (extra > 0)
          Text(
            '+$extra',
            style: text.labelSmall?.copyWith(color: palette.inkTertiary),
          ),
      ],
    );
  }
}
