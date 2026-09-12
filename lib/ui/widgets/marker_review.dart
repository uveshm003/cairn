/// The markers from a take, listed for review before the entry is saved.
///
/// Lives here rather than inside `review_screen.dart` so it can be pumped on
/// its own. The review screen cannot: it builds a `MediaPreview`, and
/// `just_audio`'s player never settles in a host test, so a widget test of the
/// whole screen hangs instead of failing.
library;

import 'package:flutter/material.dart';

import 'formatting.dart';

/// The markers dropped during the take, with a way to remove a stray one.
///
/// Shown as timestamps rather than as ticks on a timeline: at review time the
/// question is "did I mean to tap there?", and a number answers that better
/// than a position on a bar 300px wide.
class MarkerReview extends StatelessWidget {
  const MarkerReview({
    super.key,
    required this.offsetsMs,
    required this.enabled,
    required this.onRemove,
  });

  final List<int> offsetsMs;
  final bool enabled;
  final ValueChanged<int> onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sorted = List.of(offsetsMs)..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.bookmark_outline,
                size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            // Flexible: at a large text scale "12 markers" is wider than the
            // row has left, and an unconstrained Text overflows rather than
            // wrapping.
            Flexible(
              child: Text(
                sorted.length == 1 ? '1 marker' : '${sorted.length} markers',
                style: theme.textTheme.labelLarge,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final offset in sorted)
              InputChip(
                label: Text(formatClock(offset)),
                isEnabled: enabled,
                onDeleted: enabled ? () => onRemove(offset) : null,
                // Tapping the chip body does nothing: there is no playhead to
                // move on this screen, and a chip that looks tappable but is
                // not would be worse than one that plainly is not.
              ),
          ],
        ),
      ],
    );
  }
}
