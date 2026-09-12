/// The waveform scrubber, and the marker ticks drawn over it.
///
/// Why a waveform earns its place in an app that is otherwise austere: a
/// 20-minute Practice entry is unnavigable with a plain slider. The bars are
/// the only thing on screen that says *where the playing was* -- silence
/// between takes is visible, so a take is findable without hunting.
///
/// Painted from the stored envelope (`amplitude_envelope`), which is collected
/// during capture. When there is no envelope -- video, or any entry recorded
/// before the column existed -- the caller falls back to a plain slider rather
/// than drawing a flat line, because a flat waveform reads as "silent
/// recording" and not as "no data".
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../domain/amplitude_envelope.dart';
import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';
import 'formatting.dart';

/// A scrubbable waveform with marker ticks.
class WaveformScrubber extends StatefulWidget {
  const WaveformScrubber({
    super.key,
    required this.envelope,
    required this.positionMs,
    required this.durationMs,
    required this.onSeek,
    this.markerOffsetsMs = const [],
    this.height = 56,
  });

  final Uint8List envelope;
  final int positionMs;
  final int durationMs;

  /// Called with the seek target in milliseconds.
  final ValueChanged<int> onSeek;

  final List<int> markerOffsetsMs;
  final double height;

  @override
  State<WaveformScrubber> createState() => _WaveformScrubberState();
}

class _WaveformScrubberState extends State<WaveformScrubber> {
  /// Where the finger is during a drag, so the playhead tracks the gesture
  /// rather than waiting for the player's position stream to catch up.
  double? _dragFraction;

  void _seekTo(double fraction, {required bool commit}) {
    final clamped = fraction.clamp(0.0, 1.0);
    setState(() => _dragFraction = commit ? null : clamped);
    if (commit) {
      widget.onSeek((clamped * widget.durationMs).round());
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final theme = Theme.of(context);

    final playedFraction = _dragFraction ??
        (widget.durationMs <= 0
            ? 0.0
            : (widget.positionMs / widget.durationMs).clamp(0.0, 1.0));

    final positionMs = (playedFraction * widget.durationMs).round();

    return Semantics(
      // S14: the scrubber must be usable without seeing it.
      //
      // The increase/decrease actions are the point, not decoration. This
      // replaced a real `Slider` for every entry that has an envelope, and a
      // `slider: true` node with no adjust actions announces a control that
      // assistive tech cannot move -- strictly worse than the Slider it
      // replaced. `takeException` cannot see that, so it is asserted against the
      // semantics tree in `playback_controls_test.dart`.
      slider: true,
      label: 'Playback position',
      value: formatClock(positionMs),
      increasedValue: formatClock(
        (positionMs + _stepMs).clamp(0, widget.durationMs),
      ),
      decreasedValue: formatClock(
        (positionMs - _stepMs).clamp(0, widget.durationMs),
      ),
      onIncrease: () =>
          widget.onSeek((positionMs + _stepMs).clamp(0, widget.durationMs)),
      onDecrease: () =>
          widget.onSeek((positionMs - _stepMs).clamp(0, widget.durationMs)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;

          void handle(Offset local, {required bool commit}) {
            if (width <= 0) return;
            _seekTo(local.dx / width, commit: commit);
          }

          return GestureDetector(
            // Tap-to-seek and drag-to-scrub, the two gestures anyone will try.
            //
            // On tap *up*, not tap down: `TapGestureRecognizer` fires its down
            // callback once the press outlives `kPressTimeout`, even when the
            // gesture goes on to become a vertical scroll of the detail screen
            // this sits in. Committing there meant resting a finger on the
            // waveform and scrolling seeked the entry. Tap-up only fires when
            // the tap actually won the arena.
            onTapUp: (d) => handle(d.localPosition, commit: true),
            onHorizontalDragStart: (d) =>
                handle(d.localPosition, commit: false),
            onHorizontalDragUpdate: (d) =>
                handle(d.localPosition, commit: false),
            onHorizontalDragEnd: (_) {
              final at = _dragFraction;
              if (at != null) _seekTo(at, commit: true);
            },
            // Opaque so the whole strip is a target, including the quiet parts
            // where the bars are only a pixel tall.
            behavior: HitTestBehavior.opaque,
            child: SizedBox(
              height: widget.height,
              width: double.infinity,
              child: CustomPaint(
                painter: _WaveformPainter(
                  envelope: widget.envelope,
                  playedFraction: playedFraction,
                  markerFractions: _markerFractions(),
                  playedColor: theme.colorScheme.primary,
                  unplayedColor: palette.inkTertiary,
                  markerColor: theme.colorScheme.primary,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// One assistive-tech nudge, in milliseconds.
  ///
  /// Proportional rather than fixed: 10s steps would take 120 nudges to cross a
  /// 20-minute practice session, and would overshoot a 30-second note entirely.
  /// Bounded at both ends so neither extreme becomes useless.
  int get _stepMs => (widget.durationMs / 20).round().clamp(1000, 30000);

  List<double> _markerFractions() {
    if (widget.durationMs <= 0) return const [];
    return widget.markerOffsetsMs
        .map((ms) => (ms / widget.durationMs).clamp(0.0, 1.0))
        .toList();
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.envelope,
    required this.playedFraction,
    required this.markerFractions,
    required this.playedColor,
    required this.unplayedColor,
    required this.markerColor,
  });

  final Uint8List envelope;
  final double playedFraction;
  final List<double> markerFractions;
  final Color playedColor;
  final Color unplayedColor;
  final Color markerColor;

  /// Bar width plus gap, in logical pixels. Bars are sized in *screen* terms
  /// and the envelope is resampled to fit, rather than the reverse -- otherwise
  /// a long entry would draw sub-pixel bars that alias into mush.
  static const _barPitch = 3.0;
  static const _barWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    final barCount = math.max(1, (size.width / _barPitch).floor());
    final bars = resampleEnvelope(envelope, barCount);
    final mid = size.height / 2;
    final playedBars = (playedFraction * barCount).round();

    final paint = Paint()..strokeCap = StrokeCap.round;

    for (var i = 0; i < bars.length; i++) {
      // A floor on the height so silence still draws a visible baseline: a
      // zero-height bar would leave gaps that look like missing data.
      final amplitude = math.max(bars[i] * (size.height - 4), 2.0);
      final x = i * _barPitch + _barWidth / 2;

      paint
        ..color = i < playedBars ? playedColor : unplayedColor
        ..strokeWidth = _barWidth;

      canvas.drawLine(
        Offset(x, mid - amplitude / 2),
        Offset(x, mid + amplitude / 2),
        paint,
      );
    }

    // Markers on top, full height, so they read as cuts through the waveform
    // rather than as unusually loud moments.
    final markerPaint = Paint()
      ..color = markerColor
      ..strokeWidth = 1.5;
    for (final fraction in markerFractions) {
      final x = fraction * size.width;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), markerPaint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.playedFraction != playedFraction ||
      old.envelope != envelope ||
      // Compared by value, not by length: a marker can move without the count
      // changing, which is what happens the moment the duration the fractions
      // were derived from is corrected.
      !listEquals(old.markerFractions, markerFractions) ||
      old.playedColor != playedColor ||
      old.unplayedColor != unplayedColor ||
      old.markerColor != markerColor;
}


/// Marker ticks drawn over an existing progress bar.
///
/// Separate from [WaveformScrubber] because video has no waveform to draw them
/// on -- there they are painted over `VideoProgressIndicator`, whose scrub
/// gesture must keep working, so this is a pure overlay with no hit testing.
class MarkerTicks extends StatelessWidget {
  const MarkerTicks({
    super.key,
    required this.offsetsMs,
    required this.durationMs,
    required this.color,
  });

  final List<int> offsetsMs;
  final int durationMs;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (durationMs <= 0 || offsetsMs.isEmpty) return const SizedBox.shrink();
    return CustomPaint(
      painter: _TicksPainter(
        fractions: offsetsMs
            .map((ms) => (ms / durationMs).clamp(0.0, 1.0))
            .toList(),
        color: color,
      ),
    );
  }
}

class _TicksPainter extends CustomPainter {
  _TicksPainter({required this.fractions, required this.color});

  final List<double> fractions;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    for (final fraction in fractions) {
      // Inset by a hairline at each end so a marker at 0:00 or at the very end
      // is not half-clipped by the bar's own bounds.
      final x = (fraction * size.width).clamp(1.0, size.width - 1);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_TicksPainter old) =>
      old.color != color ||
      // By value. This painter has no playhead to force a repaint the way the
      // waveform's does, so comparing lengths alone left the ticks frozen at
      // whatever duration they were first laid out against -- and the entry's
      // stored duration and the player's reported one routinely differ.
      !listEquals(old.fractions, fractions);
}

/// The markers as tappable timestamps, for jumping straight to one.
///
/// The ticks say *where* the markers are; this says *what time* they are and
/// makes them reachable. Both are needed: a tick is unhittable on a 300px bar
/// holding a 20-minute session.
class MarkerJumpRow extends StatelessWidget {
  const MarkerJumpRow({
    super.key,
    required this.offsetsMs,
    required this.onJump,
  });

  final List<int> offsetsMs;
  final ValueChanged<int> onJump;

  @override
  Widget build(BuildContext context) {
    final sorted = List.of(offsetsMs)..sort();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final offset in sorted)
            Padding(
              padding: const EdgeInsets.only(right: Space.sm),
              child: ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.bookmark, size: 14),
                label: Text(formatClock(offset)),
                onPressed: () => onJump(offset),
              ),
            ),
        ],
      ),
    );
  }
}
