/// The amplitude envelope behind waveform scrubbing.
///
/// Nothing in the dependency tree can decode audio back into amplitudes, and
/// the thing that could is FFmpeg, which S8 rules out. But the recorder already
/// streams levels for the on-screen meter during capture, so the envelope is
/// free if it is collected *while recording* rather than derived afterwards.
///
/// Two properties matter and are what the tests pin:
///
/// 1. **Bounded size.** "Small on disk" is Principle #5, and an app that added
///    20 KB per entry to win a waveform would be arguing against itself. The
///    recorder halves its buffer whenever it fills, so a 20-second note and a
///    30-minute practice session both cost at most [maxSamples] bytes.
/// 2. **Cadence-independence.** The sample interval is never stored. Readers
///    derive it from `durationMs / length`, so changing the capture cadence --
///    or halving the buffer mid-recording -- cannot misalign an envelope that
///    was written under different settings.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// One byte per sample, so this is also the stored byte cap per entry.
///
/// 2048 samples is ~0.9s resolution for a 30-minute entry and the full 90ms
/// capture cadence for anything under ~3 minutes -- which is where Quick Note
/// and Diary live, and where a waveform is read most closely.
const maxSamples = 2048;

/// Collects levels during a recording and hands back a bounded envelope.
///
/// Levels come in as 0..1 (already normalized from dBFS by the caller, which
/// is where the meter's own scaling decision belongs).
class EnvelopeRecorder {
  final _samples = <int>[];

  /// How many raw levels are folded into each stored sample. Doubles every time
  /// the buffer fills, which is what keeps the size bounded without knowing the
  /// recording's length up front.
  int _fold = 1;

  /// Peak of the raw levels seen since the last stored sample.
  int _pending = 0;
  int _pendingCount = 0;

  int get length => _samples.length;

  void add(double level) {
    final byte = (level.clamp(0.0, 1.0) * 255).round();
    // Peak rather than mean: a mean envelope of speech looks like a flat smear,
    // and the point of the waveform is to make the loud parts findable.
    if (byte > _pending) _pending = byte;
    _pendingCount++;

    if (_pendingCount >= _fold) {
      _samples.add(_pending);
      _pending = 0;
      _pendingCount = 0;
      if (_samples.length >= maxSamples) _halve();
    }
  }

  /// Folds pairs of samples into their peak, doubling the covered interval.
  void _halve() {
    for (var i = 0; i < _samples.length ~/ 2; i++) {
      _samples[i] = math.max(_samples[i * 2], _samples[i * 2 + 1]);
    }
    _samples.removeRange(_samples.length ~/ 2, _samples.length);
    _fold *= 2;
  }

  /// The envelope, or null when there is nothing worth storing.
  ///
  /// Null rather than an empty list, because the column is nullable and "no
  /// envelope" is a normal state the player already handles -- an empty blob
  /// would be a second way to say the same thing.
  Uint8List? build() {
    // A trailing partial sample is kept: for a very short recording it may be
    // most of the envelope.
    final out = [..._samples, if (_pendingCount > 0) _pending];
    if (out.isEmpty) return null;
    return Uint8List.fromList(out);
  }
}

/// Resamples an envelope to exactly [buckets] values in 0..1, for painting.
///
/// Peak-preserving in both directions: downsampling takes the max of each
/// span (a waveform that averages away its transients is not worth drawing),
/// and upsampling repeats rather than interpolating, so a short recording shows
/// honest steps instead of invented smoothness.
List<double> resampleEnvelope(Uint8List envelope, int buckets) {
  if (buckets <= 0) return const [];
  if (envelope.isEmpty) return List.filled(buckets, 0);

  return List.generate(buckets, (i) {
    final start = (i * envelope.length) ~/ buckets;
    var end = ((i + 1) * envelope.length) ~/ buckets;
    // Every bucket must cover at least one sample, or upsampling would produce
    // empty spans and a row of zero-height bars.
    if (end <= start) end = start + 1;

    var peak = 0;
    for (var j = start; j < end && j < envelope.length; j++) {
      if (envelope[j] > peak) peak = envelope[j];
    }
    return peak / 255;
  });
}
