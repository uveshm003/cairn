/// The encoding ladder from requirements.md S8, as data.
///
/// The type picks the profile, so the user never sees a bitrate (S8: "type
/// decides the profile automatically").
///
/// **One profile, two implementations.** This is the important wrinkle. Video
/// gets its bitrate by *post-processing* with `flutter_compress`; audio gets its
/// bitrate at *capture time* from `record`. That asymmetry is forced, not
/// stylistic: `flutter_compress` exposes `audioBitrateKbps` and `frameRate` on
/// **iOS only** — Android's Media3 exposes neither and ignores them silently
/// rather than approximating. So S8's audio ladder (32-48 / 96 / 128 kbps)
/// cannot be reached by compressing after the fact on Android. Setting it on the
/// recorder works on both platforms, so that is where audio bitrate is decided.
library;

import 'package:flutter_compress/flutter_compress.dart';
import 'package:record/record.dart';

import '../data/database.dart';

class EncodingProfile {
  const EncodingProfile({
    required this.kind,
    required this.label,
    required this.description,
    required this.videoBitrateKbps,
    required this.maxHeight,
    required this.audioBitrateKbps,
    required this.audioChannels,
    required this.audioSampleRate,
    required this.frameRate,
  });

  final ProfileKind kind;
  final String label;

  /// Shown in settings, where a user may override the type's default.
  final String description;

  /// The primary size lever (S8: "bitrate is the primary size lever,
  /// resolution secondary").
  final int videoBitrateKbps;

  /// Resolution cap. Only ever scales down; aspect ratio is preserved.
  final int maxHeight;

  final int audioBitrateKbps;

  /// Voice is mono; music practice earns stereo (S8).
  final int audioChannels;

  final int audioSampleRate;

  /// Honoured on iOS; on Android it only feeds the bitrate maths. Always read
  /// back from the result rather than assumed.
  final double frameRate;

  static const small = EncodingProfile(
    kind: ProfileKind.small,
    label: 'Small',
    description: 'Talking-head notes and voice. Smallest files.',
    videoBitrateKbps: 1750, // S8: ~1.5-2 Mbps
    maxHeight: 720,
    audioBitrateKbps: 40, // S8: 32-48 kbps
    audioChannels: 1, // voice
    audioSampleRate: 32000,
    frameRate: 30,
  );

  static const balanced = EncodingProfile(
    kind: ProfileKind.balanced,
    label: 'Balanced',
    description: 'The default. Good detail at a reasonable size.',
    videoBitrateKbps: 3500, // S8: ~3-4 Mbps
    maxHeight: 1080,
    audioBitrateKbps: 96,
    audioChannels: 2,
    audioSampleRate: 44100,
    frameRate: 30,
  );

  static const high = EncodingProfile(
    kind: ProfileKind.high,
    label: 'High',
    description: 'For practice, where motion and audio fidelity matter.',
    videoBitrateKbps: 5500, // S8: ~5-6 Mbps
    maxHeight: 1080,
    audioBitrateKbps: 128, // music
    audioChannels: 2,
    audioSampleRate: 48000,
    frameRate: 30,
  );

  /// Smallest first.
  static const ladder = <EncodingProfile>[small, balanced, high];

  static EncodingProfile of(ProfileKind kind) => switch (kind) {
        ProfileKind.small => small,
        ProfileKind.balanced => balanced,
        ProfileKind.high => high,
      };

  /// Post-processing config for video.
  ///
  /// Exactly one size control is set. `flutter_compress` ranks
  /// `targetSizeMB` > `videoBitrateKbps` > `qualityPercent` > `quality` and
  /// silently ignores the losers, so setting more than one is dead config, not
  /// a refinement. `maxHeight` is a dimension cap rather than a size control,
  /// so pairing the two is correct.
  VideoCompressConfig get videoConfig => VideoCompressConfig(
        videoBitrateKbps: videoBitrateKbps,
        maxHeight: maxHeight,
        // Falls back to H.264 automatically where HEVC cannot be
        // hardware-encoded. Always read `result.codec` for what shipped.
        codec: VideoCodec.h265,
        audioBitrateKbps: audioBitrateKbps, // iOS only; harmless elsewhere
        frameRate: frameRate, // iOS only
        // If compressing would make the file bigger, keep the original. The
        // result comes back `skipped`, and `outputPath` is then the *input*.
        keepOriginalIfLarger: true,
        // Foreground-only.
        //
        // `true` starts a foreground service, which needs FOREGROUND_SERVICE,
        // FOREGROUND_SERVICE_DATA_SYNC and POST_NOTIFICATIONS. Those are
        // stripped from the manifest to keep the permission list honest for a
        // privacy-first app (see AndroidManifest.xml) — and contrary to the
        // plugin's guide, a stripped permission does not degrade gracefully on
        // Android 14+: the plugin's service throws SecurityException inside
        // onStartCommand and takes the whole app down on every video save.
        //
        // The cost of `false` is that backgrounding the app mid-encode can kill
        // it. That fails the save rather than losing anything: §9's ordering
        // keeps the original until the output is verified, so the user can
        // simply save again. Restoring the three permissions is the trade if
        // background encoding is ever wanted.
        keepAliveInBackground: false,
      );

  /// Capture-time config for audio entries.
  ///
  /// AAC-LC for compatibility (S8 prefers AAC; Opus is better at low bitrate but
  /// on iOS `record` writes it into a CAF container that only plays back on
  /// Apple platforms, which would break the export promise in S11).
  RecordConfig get audioConfig => RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: audioBitrateKbps * 1000, // the package wants bits/sec
        sampleRate: audioSampleRate,
        numChannels: audioChannels,
      );

  /// Predicted size in bytes for a video of [durationMs] at this profile.
  /// Used for the pre-flight estimate shown while saving.
  int predictedVideoBytes(int durationMs) {
    final totalKbps = videoBitrateKbps + audioBitrateKbps;
    return (totalKbps * 1000 * (durationMs / 1000) / 8).round();
  }

  /// Predicted size for an audio-only entry. Exact rather than estimated:
  /// constant-bitrate AAC has no hardware variance to account for.
  int predictedAudioBytes(int durationMs) =>
      (audioBitrateKbps * 1000 * (durationMs / 1000) / 8).round();
}
