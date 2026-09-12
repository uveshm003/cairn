import 'dart:typed_data';

import 'package:cairn/domain/amplitude_envelope.dart';
import 'package:flutter_test/flutter_test.dart';

/// The envelope's two contractual properties are bounded size (Principle #5 --
/// an app that sells "small on disk" cannot quietly add 20 KB per entry) and
/// cadence-independence (the sample interval is never stored, so it cannot go
/// stale).
void main() {
  group('EnvelopeRecorder', () {
    test('a short recording keeps every sample', () {
      final rec = EnvelopeRecorder();
      for (final level in [0.1, 0.5, 0.9]) {
        rec.add(level);
      }
      final built = rec.build()!;
      expect(built.length, 3);
      expect(built[0], (0.1 * 255).round());
      expect(built[2], (0.9 * 255).round());
    });

    test('nothing recorded yields null, not an empty blob', () {
      // Null is the column's "no waveform" state and the player already handles
      // it; an empty blob would be a second encoding of the same fact.
      expect(EnvelopeRecorder().build(), isNull);
    });

    test('size stays bounded no matter how long the recording runs', () {
      final rec = EnvelopeRecorder();
      // 20,000 samples is a 30-minute entry at the 90ms capture cadence.
      for (var i = 0; i < 20000; i++) {
        rec.add((i % 100) / 100);
      }
      final built = rec.build()!;
      expect(built.length, lessThanOrEqualTo(maxSamples + 1),
          reason: 'a 30-minute entry must not cost more than ${maxSamples}B');
      expect(built.length, greaterThan(maxSamples ~/ 4),
          reason: 'halving should not collapse the envelope to a stub');
    });

    test('halving preserves peaks rather than averaging them away', () {
      final rec = EnvelopeRecorder();
      // One loud spike in an otherwise silent recording, long enough to force
      // several halvings. The spike must survive all of them.
      for (var i = 0; i < 9000; i++) {
        rec.add(i == 4000 ? 1.0 : 0.0);
      }
      expect(rec.build()!.reduce((a, b) => a > b ? a : b), 255,
          reason: 'the transient was averaged away, which is the one thing a '
              'peak envelope exists to prevent');
    });

    test('levels outside 0..1 are clamped rather than wrapping', () {
      final rec = EnvelopeRecorder();
      rec.add(-3);
      rec.add(9);
      final built = rec.build()!;
      expect(built[0], 0);
      expect(built[1], 255);
    });
  });

  group('resampleEnvelope', () {
    test('returns exactly the requested bucket count, up or down', () {
      final small = Uint8List.fromList([0, 128, 255]);
      expect(resampleEnvelope(small, 12).length, 12);
      final big = Uint8List.fromList(List.generate(500, (i) => i % 256));
      expect(resampleEnvelope(big, 40).length, 40);
    });

    test('downsampling keeps the peak of each span', () {
      final env = Uint8List.fromList([0, 0, 255, 0, 0, 0, 0, 0]);
      final bars = resampleEnvelope(env, 2);
      expect(bars[0], 1.0, reason: 'the spike is in the first half');
      expect(bars[1], 0.0);
    });

    test('upsampling repeats rather than inventing zero-height bars', () {
      final bars = resampleEnvelope(Uint8List.fromList([255, 255]), 8);
      expect(bars.every((b) => b == 1.0), isTrue,
          reason: 'empty spans would paint as gaps in a solid waveform');
    });

    test('degenerate inputs do not throw', () {
      expect(resampleEnvelope(Uint8List(0), 10), List.filled(10, 0));
      expect(resampleEnvelope(Uint8List.fromList([9]), 0), isEmpty);
    });

    test('output is normalized to 0..1', () {
      final env = Uint8List.fromList(List.generate(256, (i) => i));
      final bars = resampleEnvelope(env, 32);
      expect(bars.every((b) => b >= 0 && b <= 1), isTrue);
    });
  });
}
