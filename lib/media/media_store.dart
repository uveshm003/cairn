/// Storage discipline from requirements.md S9, established on the first file the
/// app ever writes rather than retrofitted.
///
/// Two rules carry the weight:
///
///   1. **Relative paths only in the database.** Rows store `media/{uuid}.mp4`,
///      never an absolute path. iOS app-container paths change across
///      reinstalls and restores, so a stored absolute path *will* break playback
///      for every restored entry. [resolve] is the only place a stored path
///      becomes absolute, and [relativize] the only place the reverse happens.
///   2. **Compress to the plugin's cache, then move.** `flutter_compress` writes
///      to its own cache directory and `releaseOutput()` deletes cache files;
///      its behaviour on a custom `outputDirectory` is undocumented. So
///      permanent media never lives inside the plugin's release semantics — it
///      is moved in after passing the integrity check.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Result of an orphan sweep (S9).
class OrphanReport {
  const OrphanReport({required this.filesWithoutRows, required this.rowsWithoutFiles});

  /// Files on disk that no entry points at — safe to delete.
  final List<String> filesWithoutRows;

  /// Entry ids whose media file is gone — the row is the broken one.
  final List<int> rowsWithoutFiles;

  bool get isClean => filesWithoutRows.isEmpty && rowsWithoutFiles.isEmpty;
}

class MediaStore {
  MediaStore._(this._documentsDir);

  static const _uuid = Uuid();

  /// Sub-directory holding entry media.
  static const mediaDirName = 'media';

  /// Sub-directory holding generated video thumbnails.
  static const thumbDirName = 'thumbs';

  final Directory _documentsDir;

  static MediaStore? _instance;

  /// Opens the store, creating its directories. Safe to call repeatedly.
  static Future<MediaStore> open() async {
    final existing = _instance;
    if (existing != null) return existing;
    final docs = await getApplicationDocumentsDirectory();
    for (final name in [mediaDirName, thumbDirName]) {
      await Directory(p.join(docs.path, name)).create(recursive: true);
    }
    return _instance = MediaStore._(docs);
  }

  /// Test seam: point the store at a temporary directory.
  static MediaStore forTesting(Directory documentsDir) {
    for (final name in [mediaDirName, thumbDirName]) {
      Directory(p.join(documentsDir.path, name)).createSync(recursive: true);
    }
    return MediaStore._(documentsDir);
  }

  /// The only place a stored relative path becomes absolute.
  String resolve(String relativePath) =>
      p.join(_documentsDir.path, relativePath);

  /// The only place an absolute path becomes storable.
  String relativize(String absolutePath) =>
      p.relative(absolutePath, from: _documentsDir.path);

  bool existsRelative(String relativePath) =>
      File(resolve(relativePath)).existsSync();

  /// A fresh absolute path for something about to be recorded.
  ///
  /// File names are always `{uuid}.{ext}` — never derived from a user's title
  /// (S9), which would break on emoji, slashes, and duplicate names.
  String newMediaPath(String extension) {
    final ext = extension.startsWith('.') ? extension : '.$extension';
    return p.join(_documentsDir.path, mediaDirName, '${_uuid.v4()}$ext');
  }

  /// Moves [sourcePath] into permanent storage and returns the **relative**
  /// path to store in the database.
  ///
  /// Falls back to copy-then-delete when a rename would cross filesystems,
  /// which is the normal case for a plugin cache directory on Android.
  Future<String> adopt(String sourcePath, {bool thumbnail = false}) async {
    final ext = p.extension(sourcePath);
    final dir = thumbnail ? thumbDirName : mediaDirName;
    final destination =
        p.join(_documentsDir.path, dir, '${_uuid.v4()}$ext');
    final source = File(sourcePath);
    try {
      await source.rename(destination);
    } on FileSystemException {
      await source.copy(destination);
      await source.delete();
    }
    return relativize(destination);
  }

  Future<int> sizeOfRelative(String relativePath) async {
    final file = File(resolve(relativePath));
    if (!file.existsSync()) return 0;
    return file.length();
  }

  Future<void> deleteRelative(String? relativePath) async {
    if (relativePath == null) return;
    final file = File(resolve(relativePath));
    if (file.existsSync()) await file.delete();
  }

  /// Every media/thumb file, as relative paths.
  List<String> listAllFiles() {
    final out = <String>[];
    for (final name in [mediaDirName, thumbDirName]) {
      final dir = Directory(p.join(_documentsDir.path, name));
      if (!dir.existsSync()) continue;
      out.addAll(
        dir.listSync().whereType<File>().map((f) => relativize(f.path)),
      );
    }
    return out;
  }

  int totalBytesOnDisk() {
    var total = 0;
    for (final name in [mediaDirName, thumbDirName]) {
      final dir = Directory(p.join(_documentsDir.path, name));
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync()) {
        if (entity is File) total += entity.lengthSync();
      }
    }
    return total;
  }

  /// Compares what is on disk against what the database references (S9's orphan
  /// sweep). Reports rather than deletes — the repair is the caller's decision.
  OrphanReport findOrphans({
    required Set<String> referencedPaths,
    required Map<int, List<String>> pathsByEntry,
  }) {
    final onDisk = listAllFiles().toSet();
    final rowsWithoutFiles = <int>[];
    for (final entry in pathsByEntry.entries) {
      if (entry.value.any((path) => !onDisk.contains(path))) {
        rowsWithoutFiles.add(entry.key);
      }
    }
    return OrphanReport(
      filesWithoutRows:
          onDisk.difference(referencedPaths).toList(growable: false),
      rowsWithoutFiles: rowsWithoutFiles,
    );
  }
}
