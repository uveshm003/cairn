/// Turning a finished recording into a stored entry: compress, verify, move,
/// thumbnail (requirements.md S8 + S9).
///
/// The ordering is the part that matters, and it is S9's:
///
///   1. compress into the plugin's cache (original untouched)
///   2. integrity-check the output
///   3. only then move it into permanent storage
///   4. only then let the caller commit the database row
///
/// A crash at any point leaves either a stray cache file or an orphan media
/// file, both of which the orphan sweep can clean. What it can never leave is a
/// row pointing at a file that is not there.
library;

import 'dart:io';

import 'package:flutter_compress/flutter_compress.dart';

import '../data/database.dart';
import '../domain/encoding_profile.dart';
import 'media_store.dart';

/// Progress of a save, for the review screen's indicator.
class SaveProgress {
  const SaveProgress({required this.stage, this.fraction});

  final SaveStage stage;

  /// 0..1 where the platform reports it; null for stages that cannot.
  final double? fraction;
}

enum SaveStage {
  probing('Reading the recording'),
  compressing('Compressing'),
  verifying('Checking the file'),
  storing('Saving'),
  thumbnailing('Making a thumbnail'),
  done('Done');

  const SaveStage(this.label);

  final String label;
}

/// A recording that has been compressed, verified and stored. Everything the
/// caller needs to write the row — and nothing about the database itself.
class SavedMedia {
  const SavedMedia({
    required this.relativePath,
    required this.durationMs,
    required this.fileSizeBytes,
    required this.originalSizeBytes,
    this.thumbnailRelativePath,
    this.width,
    this.height,
    this.codec,
    this.bitrateKbps,
    this.compressionSkipped = false,
  });

  final String relativePath;
  final int durationMs;
  final int fileSizeBytes;

  /// Pre-compression size, for the "space saved" stat (S8).
  final int originalSizeBytes;

  final String? thumbnailRelativePath;
  final int? width;
  final int? height;

  /// What the encoder *actually* wrote, which may be h264 even when h265 was
  /// requested.
  final String? codec;

  final int? bitrateKbps;

  /// True when compressing would have grown the file, so the original was kept.
  final bool compressionSkipped;

  int get savedBytes {
    final saved = originalSizeBytes - fileSizeBytes;
    return saved > 0 ? saved : 0;
  }
}

/// Raised when a compressed file fails S9's integrity check. The original is
/// always still on disk when this is thrown.
class IntegrityException implements Exception {
  IntegrityException(this.reason);

  final String reason;

  @override
  String toString() => 'Integrity check failed: $reason';
}

class SavePipeline {
  SavePipeline(this._store);

  final MediaStore _store;
  final _api = FlutterCompress.instance;

  /// Duration drift tolerated between source and output before the file is
  /// called suspect.
  ///
  /// A truncated encode is the failure this catches: the output is perfectly
  /// playable but three seconds long, which a size check alone would happily
  /// report as a spectacular compression win. The tolerance is a judgement, not
  /// a measured figure — container rounding and the plugin's divide-by-16
  /// dimension alignment can shift things legitimately.
  static const durationToleranceMs = 750;

  /// Compresses and stores a **video** recording.
  ///
  /// [sourcePath] is deleted once the output is safely stored, unless
  /// [keepOriginal] is set or compression was skipped (in which case the source
  /// *is* the output and deleting it would destroy the recording).
  Future<SavedMedia> saveVideo({
    required String sourcePath,
    required EncodingProfile profile,
    bool keepOriginal = false,
    void Function(SaveProgress)? onProgress,
    CancellationToken? cancellationToken,
  }) async {
    onProgress?.call(const SaveProgress(stage: SaveStage.probing));
    final source = await _api.getVideoInfo(sourcePath);
    final originalSize = await File(sourcePath).length();

    onProgress?.call(const SaveProgress(stage: SaveStage.compressing));
    final result = await _api.compress(
      sourcePath,
      profile.videoConfig,
      cancellationToken: cancellationToken,
      onProgress: (p) => onProgress?.call(
        SaveProgress(stage: SaveStage.compressing, fraction: p.progress),
      ),
    );

    // `skipped` means compression would have made the file larger, so the
    // plugin handed back the *input path*. Treating that as a temporary output
    // -- deleting it, releasing it -- destroys the user's recording.
    final skipped = result.skipped;

    onProgress?.call(const SaveProgress(stage: SaveStage.verifying));
    if (!skipped) {
      final failure = await _checkIntegrity(result, source);
      if (failure != null) {
        // Never commit a bad output. The original is still on disk.
        await _releaseQuietly(result.outputPath);
        throw IntegrityException(failure);
      }
    }

    onProgress?.call(const SaveProgress(stage: SaveStage.storing));
    final String storedPath;
    if (skipped) {
      // Nothing was encoded, so the source *is* the entry. When the user wants
      // originals kept there is nothing separate to keep -- this file is both.
      storedPath = await _store.adopt(sourcePath);
    } else {
      storedPath = await _store.adopt(result.outputPath);
      if (keepOriginal) {
        // The source is the camera plugin's cache path, which the OS reclaims.
        // Leaving it there would make the setting a promise the app breaks, so
        // it moves somewhere durable instead.
        await _store.adopt(sourcePath, original: true);
      } else {
        // S9: the original goes only after the output is verified and stored.
        await File(sourcePath).delete().catchError((_) => File(sourcePath));
      }
    }

    onProgress?.call(const SaveProgress(stage: SaveStage.thumbnailing));
    final thumbnail = await _makeThumbnail(
      _store.resolve(storedPath),
      durationMs: result.durationMs,
    );

    onProgress?.call(const SaveProgress(stage: SaveStage.done));
    final storedSize = await _store.sizeOfRelative(storedPath);

    return SavedMedia(
      relativePath: storedPath,
      durationMs: result.durationMs,
      fileSizeBytes: storedSize,
      originalSizeBytes: originalSize,
      thumbnailRelativePath: thumbnail,
      width: result.width,
      height: result.height,
      // What shipped, not what was asked for.
      codec: result.codec,
      bitrateKbps: result.durationMs == 0
          ? null
          : (storedSize * 8 / (result.durationMs / 1000) / 1000).round(),
      compressionSkipped: skipped,
    );
  }

  /// Stores an **audio** recording.
  ///
  /// There is no compression step: audio is already at the profile's bitrate
  /// because `record` was configured with it at capture time. That is not a
  /// shortcut — `flutter_compress` cannot re-encode audio bitrate on Android at
  /// all (the option is iOS-only), so capture-time is the only place the S8
  /// audio ladder can actually be applied. See [EncodingProfile].
  Future<SavedMedia> saveAudio({
    required String sourcePath,
    required int durationMs,
    void Function(SaveProgress)? onProgress,
  }) async {
    onProgress?.call(const SaveProgress(stage: SaveStage.verifying));
    final file = File(sourcePath);
    if (!file.existsSync()) {
      throw IntegrityException('the recording file is missing');
    }
    final size = await file.length();
    if (size == 0) {
      throw IntegrityException('the recording is empty');
    }

    onProgress?.call(const SaveProgress(stage: SaveStage.storing));
    final storedPath = await _store.adopt(sourcePath);

    onProgress?.call(const SaveProgress(stage: SaveStage.done));
    return SavedMedia(
      relativePath: storedPath,
      durationMs: durationMs,
      fileSizeBytes: size,
      // Audio was never larger: it was captured at this bitrate, so there is no
      // "original" to compare against and no saving to claim.
      originalSizeBytes: size,
      bitrateKbps:
          durationMs == 0 ? null : (size * 8 / (durationMs / 1000) / 1000).round(),
    );
  }

  /// S9's integrity check: exists, non-empty, plausible dimensions, and a
  /// duration close to the source's.
  Future<String?> _checkIntegrity(
    VideoCompressResult result,
    VideoInfo source,
  ) async {
    final file = File(result.outputPath);
    if (!file.existsSync()) return 'the compressed file is missing';
    if (await file.length() == 0) return 'the compressed file is empty';
    if (result.width <= 0 || result.height <= 0) {
      return 'the output reports ${result.width}x${result.height}';
    }
    final drift = (result.durationMs - source.durationMs).abs();
    if (drift > durationToleranceMs) {
      return 'the compressed file is ${_seconds(result.durationMs)} long but '
          'the recording was ${_seconds(source.durationMs)} — it looks truncated';
    }
    return null;
  }

  static String _seconds(int ms) => '${(ms / 1000).toStringAsFixed(1)}s';

  /// Grabs a frame for the library grid (S8: "generate a thumbnail on save").
  ///
  /// Taken from the midpoint rather than the first frame, which on phone
  /// captures is very often black while the sensor is still settling.
  /// A failure here is not fatal — an entry without a thumbnail is fine, an
  /// entry that refused to save because of one is not.
  Future<String?> _makeThumbnail(
    String absoluteVideoPath, {
    required int durationMs,
  }) async {
    try {
      final path = await _api.getThumbnail(
        absoluteVideoPath,
        positionMs: durationMs > 2000 ? durationMs ~/ 2 : 0,
        maxWidth: 480,
      );
      return await _store.adopt(path, thumbnail: true);
    } on CompressException {
      return null;
    }
  }

  Future<void> _releaseQuietly(String path) async {
    try {
      await _api.releaseOutput(path);
    } on CompressException {
      // Best-effort cleanup; a stuck cache file is not worth failing a save.
    }
  }

  /// Deletes an entry's files. Used by the trash purge and by rollback when a
  /// row fails to commit.
  Future<void> deleteMediaFor(EntryRow entry) async {
    await _store.deleteRelative(entry.filePath);
    await _store.deleteRelative(entry.thumbnailPath);
  }
}
