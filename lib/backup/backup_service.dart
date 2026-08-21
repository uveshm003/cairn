/// Backup, export and import (requirements.md S11) — MVP, not later.
///
/// "Offline means *you* are the only backup." Losing everything on a reinstall
/// would be fatal to trust, so this ships in v1.
///
/// The archive is a plain zip: a versioned `manifest.json` plus the media files
/// under their original relative paths. Nothing proprietary — if this app
/// disappears tomorrow the user can still unzip their recordings and read the
/// manifest in a text editor. That property is worth more than a compact format.
///
/// Identity across devices: rows use autoincrement ids, which are meaningless on
/// another install. But every media file is named `{uuid}.{ext}` (S9), so the
/// filename *is* a stable global identity. Merges key on that rather than on
/// row ids, which is what makes importing the same archive twice a no-op instead
/// of a duplicate.
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../data/database.dart';
import '../media/media_store.dart';

/// Bump when the manifest shape changes. Readers refuse anything newer than
/// they understand rather than guessing (S11: "keep the manifest schema
/// versioned from v1 so future formats can migrate").
const manifestVersion = 1;

const manifestFileName = 'manifest.json';

enum ImportMode {
  /// Add what is missing, leave existing entries alone.
  merge,

  /// Delete everything currently in the app, then restore the archive.
  replace,
}

class BackupProgress {
  const BackupProgress({required this.message, this.fraction});

  final String message;
  final double? fraction;
}

class ExportResult {
  const ExportResult({
    required this.archivePath,
    required this.entryCount,
    required this.bytes,
  });

  final String archivePath;
  final int entryCount;
  final int bytes;
}

class ImportResult {
  const ImportResult({
    required this.imported,
    required this.skipped,
    required this.missingMedia,
  });

  final int imported;
  final int skipped;

  /// Entries in the manifest whose media file was absent from the archive.
  /// Reported rather than silently dropped.
  final int missingMedia;
}

class BackupException implements Exception {
  BackupException(this.message);

  final String message;

  @override
  String toString() => message;
}

class BackupService {
  BackupService(this._db, this._store);

  final CairnDatabase _db;
  final MediaStore _store;

  // ---------------------------------------------------------------- export

  /// Writes an archive of everything and returns where it landed.
  ///
  /// The file goes to a temporary directory: the user then chooses a real
  /// destination through the system share sheet. Cairn never writes to Drive or
  /// anywhere else itself, which keeps the no-network promise intact — handing a
  /// file to the OS is not a network call by this app.
  Future<ExportResult> exportArchive({
    void Function(BackupProgress)? onProgress,
    /// Where to write the archive. Defaults to the OS temporary directory;
    /// injectable so the round-trip can be tested without a plugin host.
    Directory? outputDirectory,
  }) async {
    onProgress?.call(const BackupProgress(message: 'Gathering entries'));

    final entries = await _db.allEntriesIncludingTrash();
    final types = await _db.allTypes();
    final tags = await _db.allTags();

    final entryTagPairs = <Map<String, int>>[];
    for (final entry in entries) {
      for (final tagId in await _db.tagIdsFor(entry.id)) {
        entryTagPairs.add({'entryId': entry.id, 'tagId': tagId});
      }
    }

    final manifest = {
      'manifestVersion': manifestVersion,
      'app': 'cairn',
      'exportedAt': DateTime.now().toIso8601String(),
      'entryTypes': types.map(_typeToJson).toList(),
      'tags': tags.map(_tagToJson).toList(),
      'entries': entries.map(_entryToJson).toList(),
      'entryTags': entryTagPairs,
    };

    final tempDir = outputDirectory ?? await getTemporaryDirectory();
    final stamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .split('.')
        .first;
    final archivePath = p.join(tempDir.path, 'cairn-backup-$stamp.zip');

    // Remove a leftover from a previous export, or the encoder appends to it.
    final existing = File(archivePath);
    if (existing.existsSync()) await existing.delete();

    final encoder = ZipFileEncoder();
    encoder.create(archivePath);
    try {
      encoder.addArchiveFile(
        ArchiveFile.string(manifestFileName, jsonEncode(manifest)),
      );

      var done = 0;
      for (final entry in entries) {
        for (final relative in [entry.filePath, entry.thumbnailPath]) {
          if (relative == null) continue;
          final file = File(_store.resolve(relative));
          // A missing file is skipped rather than aborting the export: a
          // partial backup beats no backup, and the manifest still records
          // what the entry was.
          if (file.existsSync()) {
            await encoder.addFile(file, relative);
          }
        }
        done++;
        onProgress?.call(BackupProgress(
          message: 'Adding media ($done of ${entries.length})',
          fraction: entries.isEmpty ? 1 : done / entries.length,
        ));
      }
    } finally {
      await encoder.close();
    }

    final size = await File(archivePath).length();
    await _db.setSetting('lastExportAt', '${DateTime.now().millisecondsSinceEpoch}');

    return ExportResult(
      archivePath: archivePath,
      entryCount: entries.length,
      bytes: size,
    );
  }

  /// Hands the archive to the OS share sheet so the user picks the destination.
  Future<ShareResult> shareArchive(ExportResult result) {
    return SharePlus.instance.share(
      ShareParams(
        files: [XFile(result.archivePath)],
        subject: 'Cairn backup',
        text: 'Cairn backup — ${result.entryCount} entries',
      ),
    );
  }

  // ---------------------------------------------------------------- import

  /// Restores from an archive produced by [exportArchive].
  Future<ImportResult> importArchive(
    String archivePath, {
    ImportMode mode = ImportMode.merge,
    void Function(BackupProgress)? onProgress,
  }) async {
    onProgress?.call(const BackupProgress(message: 'Reading the archive'));

    final input = InputFileStream(archivePath);
    final Archive archive;
    try {
      archive = ZipDecoder().decodeStream(input);
    } catch (e) {
      throw BackupException('That file is not a readable zip archive. ($e)');
    }

    final manifestFile = archive.files.firstWhere(
      (f) => f.name == manifestFileName,
      orElse: () => throw BackupException(
        'No $manifestFileName inside — this does not look like a Cairn backup.',
      ),
    );

    final Map<String, dynamic> manifest;
    try {
      manifest = jsonDecode(utf8.decode(manifestFile.readBytes()!))
          as Map<String, dynamic>;
    } catch (e) {
      throw BackupException('The manifest could not be read. ($e)');
    }

    final version = manifest['manifestVersion'];
    if (version is! int) {
      throw BackupException('The manifest has no version.');
    }
    if (version > manifestVersion) {
      // Forward compatibility is not guessable. Refusing is honest; importing
      // half of a newer format and silently dropping the rest is not.
      throw BackupException(
        'This backup was made by a newer version of Cairn '
        '(format $version, this build reads $manifestVersion). '
        'Update the app and try again.',
      );
    }

    if (mode == ImportMode.replace) {
      onProgress?.call(const BackupProgress(message: 'Clearing current entries'));
      await _wipeEverything();
    }

    // --- types: match by name, so the fixed five are reused rather than
    // duplicated on every import.
    onProgress?.call(const BackupProgress(message: 'Restoring types'));
    final typeIdByOldId = <int, int>{};
    final existingTypes = {
      for (final t in await _db.allTypes()) t.name.toLowerCase(): t,
    };
    for (final raw in (manifest['entryTypes'] as List? ?? const [])) {
      final json = raw as Map<String, dynamic>;
      final name = json['name'] as String;
      final existing = existingTypes[name.toLowerCase()];
      if (existing != null) {
        typeIdByOldId[json['id'] as int] = existing.id;
        continue;
      }
      final id = await _db.into(_db.entryTypes).insert(
            EntryTypesCompanion.insert(
              name: name,
              allowedMedium:
                  _enumByName(AllowedMedium.values, json['allowedMedium']) ??
                      AllowedMedium.both,
              maxDurationMs: json['maxDurationMs'] as int,
              encodingProfile:
                  _enumByName(ProfileKind.values, json['encodingProfile']) ??
                      ProfileKind.balanced,
              isSystem: Value(json['isSystem'] as bool? ?? false),
              iconKey: json['iconKey'] as String? ?? 'shapes',
              colorKey: json['colorKey'] as String? ?? 'slate',
              sortOrder: Value(json['sortOrder'] as int? ?? 0),
            ),
          );
      typeIdByOldId[json['id'] as int] = id;
    }

    // --- tags: ensureTag collapses case-variants, so importing "Guitar" when
    // "guitar" exists reuses the existing row.
    onProgress?.call(const BackupProgress(message: 'Restoring tags'));
    final tagIdByOldId = <int, int>{};
    for (final raw in (manifest['tags'] as List? ?? const [])) {
      final json = raw as Map<String, dynamic>;
      final tag = await _db.ensureTag(json['name'] as String);
      tagIdByOldId[json['id'] as int] = tag.id;
    }

    // --- entries
    final tagsByOldEntryId = <int, List<int>>{};
    for (final raw in (manifest['entryTags'] as List? ?? const [])) {
      final json = raw as Map<String, dynamic>;
      tagsByOldEntryId
          .putIfAbsent(json['entryId'] as int, () => [])
          .add(json['tagId'] as int);
    }

    // Existing media filenames, which is how "already imported" is detected.
    final existingKeys = {
      for (final e in await _db.allEntriesIncludingTrash())
        p.basename(e.filePath),
    };

    final entriesJson = (manifest['entries'] as List? ?? const []);
    var imported = 0;
    var skipped = 0;
    var missingMedia = 0;

    for (var i = 0; i < entriesJson.length; i++) {
      final json = entriesJson[i] as Map<String, dynamic>;
      onProgress?.call(BackupProgress(
        message: 'Restoring entries (${i + 1} of ${entriesJson.length})',
        fraction: entriesJson.isEmpty ? 1 : (i + 1) / entriesJson.length,
      ));

      final relativePath = json['filePath'] as String;
      final key = p.basename(relativePath);
      if (existingKeys.contains(key)) {
        skipped++;
        continue;
      }

      // Extract media before writing the row, so a row never lands pointing at
      // a file that failed to extract (S9).
      final mediaWritten = await _extractFile(archive, relativePath);
      if (!mediaWritten) {
        missingMedia++;
        continue;
      }
      final thumbPath = json['thumbnailPath'] as String?;
      final thumbWritten =
          thumbPath == null ? false : await _extractFile(archive, thumbPath);

      final typeId = typeIdByOldId[json['typeId'] as int];
      if (typeId == null) {
        // A row whose type is unresolvable cannot be displayed; better to skip
        // it than to attach it to an arbitrary type.
        skipped++;
        await _store.deleteRelative(relativePath);
        continue;
      }

      await _db.createEntry(
        EntriesCompanion.insert(
          title: Value(json['title'] as String?),
          note: Value(json['note'] as String?),
          medium: _enumByName(Medium.values, json['medium']) ?? Medium.video,
          typeId: typeId,
          filePath: relativePath,
          thumbnailPath: Value(thumbWritten ? thumbPath : null),
          durationMs: json['durationMs'] as int? ?? 0,
          fileSizeBytes: await _store.sizeOfRelative(relativePath),
          originalSizeBytes: Value(json['originalSizeBytes'] as int?),
          createdAt: _date(json['createdAt']) ?? DateTime.now(),
          updatedAt: _date(json['updatedAt']) ?? DateTime.now(),
          // S7: recordedAt may differ from createdAt for an import -- it is the
          // moment the recording happened, which is what the library sorts by.
          recordedAt: _date(json['recordedAt']) ?? DateTime.now(),
          width: Value(json['width'] as int?),
          height: Value(json['height'] as int?),
          codec: Value(json['codec'] as String?),
          bitrateKbps: Value(json['bitrateKbps'] as int?),
          latitude: Value((json['latitude'] as num?)?.toDouble()),
          longitude: Value((json['longitude'] as num?)?.toDouble()),
          isFavorite: Value(json['isFavorite'] as bool? ?? false),
          isDeleted: Value(json['isDeleted'] as bool? ?? false),
          deletedAt: Value(_date(json['deletedAt'])),
        ),
        tagIds: (tagsByOldEntryId[json['id'] as int] ?? const [])
            .map((oldId) => tagIdByOldId[oldId])
            .whereType<int>()
            .toList(),
      );
      existingKeys.add(key);
      imported++;
    }

    // The FTS index is written per-entry by createEntry, but a full rebuild
    // after an import is cheap insurance against a partial index.
    onProgress?.call(const BackupProgress(message: 'Rebuilding search index'));
    await _db.rebuildSearchIndex();

    return ImportResult(
      imported: imported,
      skipped: skipped,
      missingMedia: missingMedia,
    );
  }

  Future<bool> _extractFile(Archive archive, String relativePath) async {
    final file = archive.files.firstWhere(
      (f) => f.name == relativePath && f.isFile,
      orElse: () => ArchiveFile.noData(''),
    );
    final bytes = file.name.isEmpty ? null : file.readBytes();
    if (bytes == null) return false;

    final destination = File(_store.resolve(relativePath));
    await destination.parent.create(recursive: true);
    await destination.writeAsBytes(bytes);
    return true;
  }

  /// Used by [ImportMode.replace]. Deletes media files as well as rows —
  /// otherwise the replaced entries' files would linger as orphans.
  Future<void> _wipeEverything() async {
    final entries = await _db.allEntriesIncludingTrash();
    for (final entry in entries) {
      await _store.deleteRelative(entry.filePath);
      await _store.deleteRelative(entry.thumbnailPath);
      await _db.purgeEntry(entry.id);
    }
    for (final tag in await _db.allTags()) {
      await _db.deleteTag(tag.id);
    }
  }

  // ---------------------------------------------------------------- mapping

  Map<String, dynamic> _entryToJson(EntryRow e) => {
        'id': e.id,
        'title': e.title,
        'note': e.note,
        'medium': e.medium.name,
        'typeId': e.typeId,
        // Relative, exactly as stored -- an absolute path would be meaningless
        // on the importing device (S9).
        'filePath': e.filePath,
        'thumbnailPath': e.thumbnailPath,
        'durationMs': e.durationMs,
        'fileSizeBytes': e.fileSizeBytes,
        'originalSizeBytes': e.originalSizeBytes,
        'createdAt': e.createdAt.toIso8601String(),
        'updatedAt': e.updatedAt.toIso8601String(),
        'recordedAt': e.recordedAt.toIso8601String(),
        'width': e.width,
        'height': e.height,
        'codec': e.codec,
        'bitrateKbps': e.bitrateKbps,
        'latitude': e.latitude,
        'longitude': e.longitude,
        'isFavorite': e.isFavorite,
        'isDeleted': e.isDeleted,
        'deletedAt': e.deletedAt?.toIso8601String(),
      };

  Map<String, dynamic> _typeToJson(EntryTypeRow t) => {
        'id': t.id,
        'name': t.name,
        'allowedMedium': t.allowedMedium.name,
        'maxDurationMs': t.maxDurationMs,
        'encodingProfile': t.encodingProfile.name,
        'isSystem': t.isSystem,
        'iconKey': t.iconKey,
        'colorKey': t.colorKey,
        'sortOrder': t.sortOrder,
      };

  Map<String, dynamic> _tagToJson(TagRow t) => {
        'id': t.id,
        'name': t.name,
        'colorKey': t.colorKey,
      };

  static T? _enumByName<T extends Enum>(List<T> values, Object? name) {
    if (name is! String) return null;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw) : null;
}
