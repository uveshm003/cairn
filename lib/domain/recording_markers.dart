/// Marker offsets, and the rule for making them safe to store.
///
/// Markers are dropped against the **stopwatch**, which starts after the
/// recorder does (`capture_screen.dart`) and stops before the file is finalized.
/// What gets stored is the **compressed output**, whose duration is measured
/// separately precisely because it can diverge from the source -- that
/// divergence is what `SavePipeline`'s integrity check exists to catch.
///
/// So a raw stopwatch offset can sit past the end of the file it points into,
/// and seeking there does nothing visible: the marker looks broken. Everything
/// here exists to make that impossible before the row is written.
library;

/// How close to the end a marker is allowed to land.
///
/// Seeking to the final frame is indistinguishable from "the entry ended", so a
/// marker in the last moment reads as a dead tap. Pulled back instead.
const _endGuardMs = 250;

/// The smallest gap between two markers that is worth keeping as two markers.
///
/// A double-tap is one intention, and two ticks a pixel apart are unreadable.
const _mergeWindowMs = 400;

/// Prepares raw stopwatch offsets for storage against a file of [durationMs].
///
/// Sorts, clamps into range, and merges taps too close together to distinguish.
/// Returns an empty list for a non-positive duration -- a file with no duration
/// has nowhere to seek to.
List<int> normalizeMarkers(Iterable<int> rawOffsetsMs, {required int durationMs}) {
  if (durationMs <= 0) return const [];

  // A very short entry cannot give up the full guard without losing every
  // marker, so the guard shrinks rather than emptying the list.
  final limit = durationMs > _endGuardMs * 2
      ? durationMs - _endGuardMs
      : durationMs - 1;

  final sorted = rawOffsetsMs.map((ms) => ms.clamp(0, limit)).toList()..sort();

  final out = <int>[];
  for (final offset in sorted) {
    if (out.isNotEmpty && offset - out.last < _mergeWindowMs) continue;
    out.add(offset);
  }
  return out;
}
