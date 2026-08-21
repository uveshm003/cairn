import 'package:cairn/data/database.dart';
import 'package:cairn/domain/encoding_profile.dart';
import 'package:flutter_compress/flutter_compress.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';

void main() {
  group('video config', () {
    test('expresses size as an explicit bitrate, and nothing outranks it', () {
      // flutter_compress ranks targetSizeMB > videoBitrateKbps >
      // qualityPercent > quality, and silently ignores the losers rather than
      // blending them. The invariant that matters is not "exactly one field is
      // set" -- `quality` defaults to `medium` and so is never null -- but that
      // nothing ABOVE videoBitrateKbps is set.
      for (final profile in EncodingProfile.ladder) {
        final config = profile.videoConfig;
        expect(config.targetSizeMB, isNull, reason: profile.label);
        expect(config.qualityPercent, isNull, reason: profile.label);
        expect(config.videoBitrateKbps, profile.videoBitrateKbps);
        expect(config.quality, CompressQuality.medium, reason: profile.label);
      }
    });

    test('requests HEVC and never grows a file', () {
      for (final profile in EncodingProfile.ladder) {
        expect(profile.videoConfig.codec, VideoCodec.h265);
        expect(profile.videoConfig.keepOriginalIfLarger, isTrue);
      }
    });

    test('caps resolution downward only', () {
      // maxHeight is a cap and the plugin only ever scales down, so a rung
      // asking for more than 1080p would be requesting an upscale it cannot get.
      for (final profile in EncodingProfile.ladder) {
        expect(profile.maxHeight, lessThanOrEqualTo(1080));
      }
    });
  });

  group('audio config', () {
    test('carries the profile bitrate, because post-processing cannot', () {
      // The whole reason audio is configured at capture time: flutter_compress
      // exposes audioBitrateKbps on iOS only, so this is the only place the S8
      // audio ladder can be applied on both platforms.
      for (final profile in EncodingProfile.ladder) {
        final config = profile.audioConfig;
        // The package wants bits/sec, not kbps -- an easy factor-of-1000 bug.
        expect(config.bitRate, profile.audioBitrateKbps * 1000);
        expect(config.numChannels, profile.audioChannels);
        expect(config.sampleRate, profile.audioSampleRate);
      }
    });

    test('uses AAC-LC for portability, not Opus', () {
      // S8 prefers AAC. Opus is better at low bitrate, but `record` writes it
      // into a CAF container on iOS that only plays on Apple platforms, which
      // would quietly break the export promise in S11.
      for (final profile in EncodingProfile.ladder) {
        expect(profile.audioConfig.encoder, AudioEncoder.aacLc);
      }
    });

    test('voice is mono, music is stereo', () {
      expect(EncodingProfile.small.audioChannels, 1);
      expect(EncodingProfile.high.audioChannels, 2);
    });
  });

  group('predicted sizes', () {
    test('match the arithmetic the S8 table rests on', () {
      // Balanced: 3500 kbps video + 96 kbps audio over 600s.
      // (3596 * 1000 * 600) / 8 = 269,700,000 bytes ~= 257 MB, and S8 predicts
      // ~250-300 MB for a 10-minute Balanced clip. The ladder and the spec
      // agree, which is why bytes-out needs no device to verify.
      final bytes = EncodingProfile.balanced.predictedVideoBytes(600000);
      expect(bytes, 269700000);
      expect(bytes / (1024 * 1024), closeTo(257, 1));
    });

    test('a 30s Small clip lands in single-digit MB', () {
      final mb =
          EncodingProfile.small.predictedVideoBytes(30000) / (1024 * 1024);
      expect(mb, greaterThan(5));
      expect(mb, lessThan(10));
    });

    test('a 10-minute audio note is about a megabyte', () {
      // S8's audio column: ~0.8 MB for a minute at Balanced. Ten minutes of
      // voice at the Small profile should still be trivial.
      final mb = EncodingProfile.small.predictedAudioBytes(600000) /
          (1024 * 1024);
      expect(mb, lessThan(4));
    });

    test('the ladder is monotonic in size', () {
      final sizes = EncodingProfile.ladder
          .map((p) => p.predictedVideoBytes(60000))
          .toList();
      expect(sizes, orderedEquals([...sizes]..sort()));
    });
  });

  test('every ProfileKind resolves to a profile', () {
    // Guards the switch in `of` against a new kind being added to the database
    // enum without a matching rung here.
    for (final kind in ProfileKind.values) {
      expect(EncodingProfile.of(kind).kind, kind);
    }
  });
}
