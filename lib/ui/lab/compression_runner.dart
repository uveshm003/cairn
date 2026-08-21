/// Milestone 1 (requirements.md S16): prove the compression ladder on real
/// hardware before building any UI around it.
///
/// What this actually de-risks — worth being precise, because it is narrower
/// than "does compression work":
///
///   * **Bytes out are arithmetic, not a gamble.** 2 Mbps x 600 s = 150 MB.
///     The spec's S8 table is internally sound and needs no device to confirm.
///     We print predicted-vs-measured anyway, because a large gap means the
///     encoder ignored the requested bitrate.
///   * **What genuinely varies by OEM is whether HEVC hardware encode exists
///     at all, and how long it takes.** So every row carries `result.codec`
///     (h265, or a silent h264 fallback) and wall-clock encode time. This is
///     the real finding.
///   * **Perceptual quality at 1.5-2 Mbps cannot be measured in bytes.** The
///     outputs are kept playable so they can be watched. A bytes-only report
///     would leave the riskiest question untested.
library;

import 'dart:io';

import 'package:flutter_compress/flutter_compress.dart';

import '../../domain/encoding_profile.dart';
import '../../media/media_store.dart';

/// Outcome of running one rung of the ladder.
class RungResult {
  RungResult({
    required this.profile,
    required this.encodeDuration,
    this.result,
    this.storedRelativePath,
    this.integrityFailure,
    this.error,
  });

  final EncodingProfile profile;

  /// Wall-clock time for the encode. The OEM-variable number.
  final Duration encodeDuration;

  /// Null when the encode threw.
  final VideoCompressResult? result;

  /// Relative path in the media dir, once the output passed integrity and was
  /// adopted. Null when the rung failed or was skipped.
  final String? storedRelativePath;

  /// Set when the output encoded but failed the S9 integrity check.
  final String? integrityFailure;

  final Object? error;

  bool get ok => result != null && integrityFailure == null && error == null;

  /// True when the plugin returned the source untouched because compressing
  /// would have made it *larger*. Not a failure — it means this rung is
  /// pointless for this input, which is itself a finding.
  bool get skipped => result?.skipped ?? false;

  /// Did HEVC actually happen, or did it silently fall back?
  bool get gotHevc => result?.codec == 'h265';
}

/// Everything measured for one source clip.
class LadderReport {
  LadderReport({required this.source, required this.rungs});

  final VideoInfo source;
  final List<RungResult> rungs;
}

class CompressionRunner {
  CompressionRunner(this._store);

  final MediaStore _store;
  final _api = FlutterCompress.instance;

  /// Duration drift we tolerate between source and output before calling the
  /// file suspect. Container rounding and the +/-16 alignment pass can shift a
  /// frame or two legitimately.
  static const _durationToleranceMs = 750;

  /// Runs every rung of the ladder against [sourcePath], sequentially.
  ///
  /// Sequential is not laziness: hardware encoders contend, so parallel encodes
  /// are slower and can outright fail. (We hand-roll the loop rather than using
  /// `compressAll`, because each rung needs its own config and its own timing.)
  ///
  /// The source file is never deleted or moved by this method. A `skipped`
  /// result hands back the *source* path, so any cleanup keyed on `outputPath`
  /// would destroy the user's recording and break every later rung.
  Future<LadderReport> run(
    String sourcePath, {
    void Function(EncodingProfile profile, double progress)? onProgress,
    void Function(EncodingProfile profile)? onRungStart,
  }) async {
    final source = await _api.getVideoInfo(sourcePath);
    final rungs = <RungResult>[];

    for (final profile in EncodingProfile.ladder) {
      onRungStart?.call(profile);
      final stopwatch = Stopwatch()..start();
      try {
        final result = await _api.compress(
          sourcePath,
          profile.videoConfig,
          onProgress: (p) => onProgress?.call(profile, p.progress),
        );
        stopwatch.stop();

        if (result.skipped) {
          // outputPath == sourcePath. Adopting would MOVE the recording out
          // from under the remaining rungs; releasing would delete it. Do
          // neither — just record what we learned.
          rungs.add(RungResult(
            profile: profile,
            encodeDuration: stopwatch.elapsed,
            result: result,
          ));
          continue;
        }

        final failure = await _checkIntegrity(result, source);
        if (failure != null) {
          // S9: a failed output never gets committed. Clean up the cache file.
          await _releaseQuietly(result.outputPath);
          rungs.add(RungResult(
            profile: profile,
            encodeDuration: stopwatch.elapsed,
            result: result,
            integrityFailure: failure,
          ));
          continue;
        }

        // S9 ordering: encode to the plugin's cache, verify, *then* move into
        // permanent storage under a uuid name. The move takes the file out of
        // the plugin's cache, so no releaseOutput is needed for this path.
        final stored = await _store.adopt(result.outputPath);
        rungs.add(RungResult(
          profile: profile,
          encodeDuration: stopwatch.elapsed,
          result: result,
          storedRelativePath: stored,
        ));
      } on CompressCancelled {
        stopwatch.stop();
        rungs.add(RungResult(
          profile: profile,
          encodeDuration: stopwatch.elapsed,
          error: 'cancelled',
        ));
        break;
      } on CompressException catch (e) {
        stopwatch.stop();
        rungs.add(RungResult(
          profile: profile,
          encodeDuration: stopwatch.elapsed,
          // e.code is the stable surface; e.message wording is not.
          error: 'compress failed: ${e.code}',
        ));
      }
    }

    return LadderReport(source: source, rungs: rungs);
  }

  /// S9 integrity check: the output must exist, be non-empty, and have roughly
  /// the source's duration. Returns a reason string, or null when it passes.
  ///
  /// A truncated encode is the failure mode this catches — the file is valid
  /// and playable but three seconds long, which byte-size alone would happily
  /// report as a spectacular compression win.
  Future<String?> _checkIntegrity(
    VideoCompressResult result,
    VideoInfo source,
  ) async {
    final file = File(result.outputPath);
    if (!file.existsSync()) return 'output file missing';
    final length = await file.length();
    if (length == 0) return 'output file is empty';

    final drift = (result.durationMs - source.durationMs).abs();
    if (drift > _durationToleranceMs) {
      return 'duration drift ${drift}ms '
          '(source ${source.durationMs}ms, output ${result.durationMs}ms) '
          '— likely truncated';
    }
    if (result.width <= 0 || result.height <= 0) {
      return 'output reports ${result.width}x${result.height}';
    }
    return null;
  }

  Future<void> _releaseQuietly(String path) async {
    try {
      await _api.releaseOutput(path);
    } on CompressException {
      // Cleanup is best-effort; a stuck cache file is not worth failing over.
    }
  }

  /// Frees every stored output from a finished run. Called from the lab screen
  /// once the numbers have been read, not per-rung during the run.
  Future<void> discardOutputs(LadderReport report) async {
    for (final rung in report.rungs) {
      final stored = rung.storedRelativePath;
      if (stored != null) await _store.deleteRelative(stored);
    }
  }
}
