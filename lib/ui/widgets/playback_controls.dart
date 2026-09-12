/// Transport controls for replaying a long entry: speed, an A-B loop, and
/// skip-silence.
///
/// These exist for the Practice job in S3 ("record my guitar practice every day
/// and scan back through the last month"). A 20-minute session is not something
/// anyone replays start to finish -- they want one passage, slowed down, on
/// repeat. Speed and looping are what turn the archive into something usable.
///
/// The widget is deliberately player-agnostic: it takes a position and a set of
/// callbacks, so the same row drives `just_audio` and `video_player` without
/// knowing which is behind it.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'formatting.dart';

/// The speeds offered, slow ones included.
///
/// Slower matters as much as faster here, and for the opposite reason: 0.5x is
/// for learning a passage note by note, 2x is for skimming a diary entry.
const playbackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

/// An A-B loop region. Both ends are set from the current playhead.
///
/// `b` is null while only A has been placed, which is a real state the UI has
/// to show -- the user taps A, listens, then taps B at the end of the phrase.
class LoopRegion {
  const LoopRegion({required this.startMs, this.endMs});

  final int startMs;
  final int? endMs;

  bool get isComplete => endMs != null && endMs! > startMs;
}

/// Closes a half-set loop with a second end, whichever side of A it falls on.
///
/// A playhead *before* A is not a mis-tap: it means the user seeked back and
/// wants the passage between the two points. Ordering the ends is a truer
/// reading of that than storing a region whose `isComplete` is false forever --
/// which is what building `LoopRegion(startMs: a, endMs: b)` blind used to do,
/// leaving the chip stuck on "Loop to here" with nothing able to complete it.
///
/// Returns null when the two ends coincide: a zero-length loop is not a loop,
/// so the half-set state is kept rather than replaced by a dead one. The chip
/// offers a delete in that state, so keeping it is not a trap.
LoopRegion? closeLoop({required int startMs, required int atMs}) {
  if (atMs == startMs) return null;
  return LoopRegion(
    startMs: math.min(startMs, atMs),
    endMs: math.max(startMs, atMs),
  );
}

/// Whether moving to [region] requires touching the player at all.
///
/// `setClip()` with no arguments is not a no-op: it reloads the source and
/// restarts at 0:00. So the half-set state -- A placed, B not yet -- must be
/// kept as pure UI state when there is no clip installed to undo, or placing A
/// throws the user back to the start of the entry.
///
/// [clipApplied] is deliberately a separate input from `region != null`: a
/// half-set loop is a region with no clip behind it, and the two states need
/// opposite treatment.
bool loopNeedsPlayerCall({
  required LoopRegion? region,
  required bool clipApplied,
}) {
  final complete = region != null && region.isComplete;
  // Complete: install the clip. Not complete but a clip is installed: tear it
  // down. Not complete and nothing installed: there is nothing to say.
  return complete || clipApplied;
}

/// What a seek to [targetMs] must actually do, given the active loop.
///
/// `just_audio`'s `setClip` makes the player's whole timeline relative to the
/// clip: positions come back relative to the clip start, and `seek` takes a
/// clip-relative offset too. Both directions need correcting, and missing either
/// one is silent -- the playhead simply lands somewhere else.
///
/// A target *outside* the loop is a request to leave it. Tapping a marker at
/// 0:12 while looping 4:12-4:28 plainly means "go to 0:12", not "clamp me to
/// the loop", so the loop is dropped rather than fighting the tap.
({bool clearLoop, int seekMs}) resolveSeek({
  required int targetMs,
  required LoopRegion? loop,
}) {
  if (loop == null || !loop.isComplete) {
    return (clearLoop: false, seekMs: targetMs);
  }
  if (targetMs < loop.startMs || targetMs > loop.endMs!) {
    return (clearLoop: true, seekMs: targetMs);
  }
  // Inside the loop: same place, expressed in the clip's own coordinates.
  return (clearLoop: false, seekMs: targetMs - loop.startMs);
}

class PlaybackControls extends StatelessWidget {
  const PlaybackControls({
    super.key,
    required this.speed,
    required this.onSpeedChanged,
    required this.loop,
    required this.onSetLoopStart,
    required this.onSetLoopEnd,
    required this.onClearLoop,
    this.skipSilence,
    this.onSkipSilenceChanged,
  });

  final double speed;
  final ValueChanged<double> onSpeedChanged;

  final LoopRegion? loop;
  final VoidCallback onSetLoopStart;
  final VoidCallback onSetLoopEnd;
  final VoidCallback onClearLoop;

  /// Null hides the control entirely.
  ///
  /// Skip-silence is an ExoPlayer feature, so `just_audio` implements it on
  /// Android only. Showing a dead switch on iOS would be worse than showing
  /// nothing, so the *caller* decides whether the platform has it.
  final bool? skipSilence;
  final ValueChanged<bool>? onSkipSilenceChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final region = loop;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _SpeedButton(speed: speed, onChanged: onSpeedChanged),
            // A and B are one control in two states rather than two buttons,
            // because "set B" is meaningless before A exists.
            if (region == null)
              ActionChip(
                avatar: const Icon(Icons.repeat, size: 16),
                label: const Text('Loop from here'),
                onPressed: onSetLoopStart,
              )
            else if (!region.isComplete)
              // An InputChip rather than an ActionChip purely for the delete:
              // A can be placed somewhere the playhead cannot get past (the
              // very end of the entry), and without a way out the half-set
              // state was unescapable short of leaving the screen.
              InputChip(
                avatar: const Icon(Icons.repeat_on, size: 16),
                label: Text('Loop to here (from ${formatClock(region.startMs)})'),
                onPressed: onSetLoopEnd,
                onDeleted: onClearLoop,
                deleteButtonTooltipMessage: 'Cancel loop',
              )
            else
              InputChip(
                avatar: const Icon(Icons.repeat_on, size: 16),
                label: Text(
                  '${formatClock(region.startMs)} – '
                  '${formatClock(region.endMs!)}',
                ),
                selected: true,
                onDeleted: onClearLoop,
                showCheckmark: false,
              ),
            if (skipSilence != null)
              FilterChip(
                avatar: const Icon(Icons.fast_forward, size: 16),
                label: const Text('Skip silence'),
                selected: skipSilence!,
                onSelected: onSkipSilenceChanged,
              ),
          ],
        ),
        if (region != null && !region.isComplete) ...[
          const SizedBox(height: Space.xs),
          Text(
            'Play to the end of the passage, then tap again to close the loop.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onChanged});

  final double speed;
  final ValueChanged<double> onChanged;

  /// "1x" rather than "1.0x", but "1.25x" in full -- trailing zeros are noise,
  /// significant digits are not.
  static String label(double value) {
    final text = value.toStringAsFixed(2);
    return '${text.replaceFirst(RegExp(r'\.?0+$'), '')}×';
  }

  @override
  Widget build(BuildContext context) {
    // A menu rather than a cycling button: six speeds is too many to tap
    // through, and jumping straight from 2x back to 0.5x is the common move.
    return PopupMenuButton<double>(
      tooltip: 'Playback speed',
      initialValue: speed,
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final option in playbackSpeeds)
          PopupMenuItem(value: option, child: Text(label(option))),
      ],
      child: Semantics(
        button: true,
        label: 'Playback speed, ${label(speed)}',
        excludeSemantics: true,
        child: Chip(
          avatar: const Icon(Icons.speed, size: 16),
          label: Text(label(speed)),
        ),
      ),
    );
  }
}
