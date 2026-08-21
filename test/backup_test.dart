import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:cairn/backup/backup_service.dart';
import 'package:cairn/data/database.dart';
import 'package:cairn/data/library_queries.dart';
import 'package:cairn/domain/entry_filter.dart';
import 'package:cairn/media/media_store.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Export/import is the app's only safety net (S11: "offline means *you* are the
/// only backup"), so it gets tested against a real filesystem and a real zip
/// rather than mocks. A silent bug here loses everything the user has.
void main() {
  // This suite deliberately runs two CairnDatabase instances at once to model a
  // source install and a destination install. They use separate in-memory
  // executors, so drift's shared-executor race warning does not apply here.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory sourceRoot;
  late Directory destRoot;
  late Directory archiveDir;
  late CairnDatabase sourceDb;
  late MediaStore sourceStore;

  setUp(() {
    sourceRoot = Directory.systemTemp.createTempSync('cairn-src');
    destRoot = Directory.systemTemp.createTempSync('cairn-dst');
    archiveDir = Directory.systemTemp.createTempSync('cairn-zip');
    sourceDb = CairnDatabase.forTesting(NativeDatabase.memory());
    sourceStore = MediaStore.forTesting(sourceRoot);
  });

  tearDown(() async {
    await sourceDb.close();
    for (final dir in [sourceRoot, destRoot, archiveDir]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  });

  /// Creates an entry with a real file behind it.
  Future<int> seedEntry(
    CairnDatabase db,
    MediaStore store, {
    required String title,
    String type = 'Diary',
    List<String> tags = const [],
    int bytes = 512,
    bool withThumbnail = false,
    Medium medium = Medium.video,
    DateTime? recordedAt,
  }) async {
    final mediaPath = store.newMediaPath('mp4');
    File(mediaPath).writeAsBytesSync(List.filled(bytes, 3));
    final relative = store.relativize(mediaPath);

    String? thumbRelative;
    if (withThumbnail) {
      final thumbAbsolute =
          p.join(store.resolve(MediaStore.thumbDirName), 'thumb-$title.jpg');
      File(thumbAbsolute).writeAsBytesSync(List.filled(32, 9));
      thumbRelative = store.relativize(thumbAbsolute);
    }

    final types = {for (final t in await db.allTypes()) t.name: t};
    final tagIds = <int>[];
    for (final name in tags) {
      tagIds.add((await db.ensureTag(name)).id);
    }

    final at = recordedAt ?? DateTime(2026, 4, 1, 10, 30);
    return db.createEntry(
      EntriesCompanion.insert(
        title: Value(title),
        note: Value('note for $title'),
        medium: medium,
        typeId: types[type]!.id,
        filePath: relative,
        thumbnailPath: Value(thumbRelative),
        durationMs: 45000,
        fileSizeBytes: bytes,
        originalSizeBytes: Value(bytes * 10),
        createdAt: at,
        updatedAt: at,
        recordedAt: at,
      ),
      tagIds: tagIds,
    );
  }

  /// A fresh, empty install to import into.
  ({CairnDatabase db, MediaStore store}) freshInstall() => (
        db: CairnDatabase.forTesting(NativeDatabase.memory()),
        store: MediaStore.forTesting(destRoot),
      );

  group('export', () {
    test('writes a versioned manifest plus the media files', () async {
      await seedEntry(sourceDb, sourceStore,
          title: 'first', tags: ['guitar'], withThumbnail: true);

      final service = BackupService(sourceDb, sourceStore);
      final result =
          await service.exportArchive(outputDirectory: archiveDir);

      expect(result.entryCount, 1);
      expect(File(result.archivePath).existsSync(), isTrue);

      final archive =
          ZipDecoder().decodeStream(InputFileStream(result.archivePath));
      final names = archive.files.map((f) => f.name).toList();

      expect(names, contains(manifestFileName));
      // Media is stored under its relative path, so it lands back in the right
      // place on import without any path rewriting.
      expect(names.where((n) => n.startsWith('media/')), hasLength(1));
      expect(names.where((n) => n.startsWith('thumbs/')), hasLength(1));

      final manifest = jsonDecode(utf8.decode(
        archive.files.firstWhere((f) => f.name == manifestFileName).readBytes()!,
      )) as Map<String, dynamic>;

      expect(manifest['manifestVersion'], manifestVersion);
      expect(manifest['app'], 'cairn');
      expect(manifest['entries'], hasLength(1));
      expect(manifest['tags'], hasLength(1));
      // All five system types travel, so an import can resolve any typeId.
      expect(manifest['entryTypes'], hasLength(5));
    });

    test('an entry whose file has vanished does not abort the export',
        () async {
      final id = await seedEntry(sourceDb, sourceStore, title: 'ghost');
      final row = await sourceDb.entryById(id);
      // Simulate the orphan case from S9.
      await sourceStore.deleteRelative(row!.filePath);

      final result = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      // A partial backup beats no backup.
      expect(result.entryCount, 1);
      expect(File(result.archivePath).existsSync(), isTrue);
    });

    test('exports an empty library without error', () async {
      final result = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);
      expect(result.entryCount, 0);
      expect(File(result.archivePath).existsSync(), isTrue);
    });
  });

  group('import', () {
    test('round-trips entries, tags, notes and media bytes', () async {
      await seedEntry(sourceDb, sourceStore,
          title: 'practice', type: 'Practice', tags: ['guitar', 'scales'],
          bytes: 700, withThumbnail: true);
      await seedEntry(sourceDb, sourceStore,
          title: 'diary', medium: Medium.audio);

      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      final fresh = freshInstall();
      addTearDown(fresh.db.close);

      final result = await BackupService(fresh.db, fresh.store)
          .importArchive(exported.archivePath);

      expect(result.imported, 2);
      expect(result.skipped, 0);
      expect(result.missingMedia, 0);

      final items = await fresh.db.watchLibrary(EntryFilter.empty).first;
      expect(items.map((i) => i.entry.title), containsAll(['practice', 'diary']));

      final practice = items.firstWhere((i) => i.entry.title == 'practice');
      expect(practice.typeName, 'Practice');
      expect(practice.tagNames..sort(), ['guitar', 'scales']);
      expect(practice.entry.note, 'note for practice');
      expect(practice.entry.medium, Medium.video);
      // The media actually arrived, at the path the row points at.
      expect(fresh.store.existsRelative(practice.entry.filePath), isTrue);
      expect(await fresh.store.sizeOfRelative(practice.entry.filePath), 700);
      expect(practice.entry.thumbnailPath, isNotNull);
      expect(fresh.store.existsRelative(practice.entry.thumbnailPath!), isTrue);

      final diary = items.firstWhere((i) => i.entry.title == 'diary');
      expect(diary.entry.medium, Medium.audio);
    });

    test('recordedAt survives, so imported entries keep their place in time',
        () async {
      // S7: recordedAt may differ from createdAt for an import. If it were reset
      // to "now", a restored library would collapse into a single day.
      final when = DateTime(2025, 11, 3, 21, 15);
      await seedEntry(sourceDb, sourceStore, title: 'old', recordedAt: when);

      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);
      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      await BackupService(fresh.db, fresh.store)
          .importArchive(exported.archivePath);

      final item = (await fresh.db.watchLibrary(EntryFilter.empty).first).single;
      expect(item.entry.recordedAt, when);
    });

    test('importing the same archive twice is a no-op', () async {
      // The media filename is a uuid, so it is a stable cross-device identity.
      // Without that, a second import would silently double the library.
      await seedEntry(sourceDb, sourceStore, title: 'once');
      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      final service = BackupService(fresh.db, fresh.store);

      final first = await service.importArchive(exported.archivePath);
      final second = await service.importArchive(exported.archivePath);

      expect(first.imported, 1);
      expect(second.imported, 0);
      expect(second.skipped, 1);
      expect(await fresh.db.watchLibrary(EntryFilter.empty).first, hasLength(1));
    });

    test('merge keeps existing entries; replace clears them first', () async {
      await seedEntry(sourceDb, sourceStore, title: 'from backup');
      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      // --- merge
      final merging = freshInstall();
      addTearDown(merging.db.close);
      await seedEntry(merging.db, merging.store, title: 'already here');
      await BackupService(merging.db, merging.store)
          .importArchive(exported.archivePath, mode: ImportMode.merge);
      final merged = await merging.db.watchLibrary(EntryFilter.empty).first;
      expect(merged.map((i) => i.entry.title),
          containsAll(['already here', 'from backup']));

      // --- replace
      final replacing = (
        db: CairnDatabase.forTesting(NativeDatabase.memory()),
        store: MediaStore.forTesting(
          Directory.systemTemp.createTempSync('cairn-rep'),
        ),
      );
      addTearDown(replacing.db.close);
      await seedEntry(replacing.db, replacing.store, title: 'will be gone');
      await BackupService(replacing.db, replacing.store)
          .importArchive(exported.archivePath, mode: ImportMode.replace);
      final replaced = await replacing.db.watchLibrary(EntryFilter.empty).first;
      expect(replaced.map((i) => i.entry.title), ['from backup']);
    });

    test('imported entries are searchable', () async {
      // The FTS index lives outside the entries table, so an import that forgot
      // to index would restore invisible-to-search entries.
      await seedEntry(sourceDb, sourceStore,
          title: 'fingerpicking practice', tags: ['guitar']);
      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      await BackupService(fresh.db, fresh.store)
          .importArchive(exported.archivePath);

      final byTitle = await fresh.db
          .watchLibrary(const EntryFilter(searchText: 'fingerpicking'))
          .first;
      expect(byTitle, hasLength(1));

      final byTag =
          await fresh.db.watchLibrary(const EntryFilter(searchText: 'guitar')).first;
      expect(byTag, hasLength(1));
    });

    test('system types are reused rather than duplicated', () async {
      await seedEntry(sourceDb, sourceStore, title: 'x');
      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      await BackupService(fresh.db, fresh.store)
          .importArchive(exported.archivePath);

      // The fresh install already seeded the five; the import must match them by
      // name instead of creating a second "Diary".
      expect(await fresh.db.allTypes(), hasLength(5));
    });

    test('tags merge case-insensitively', () async {
      await seedEntry(sourceDb, sourceStore, title: 'a', tags: ['Guitar']);
      final exported = await BackupService(sourceDb, sourceStore)
          .exportArchive(outputDirectory: archiveDir);

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      await fresh.db.ensureTag('guitar'); // already present, lower-case
      await BackupService(fresh.db, fresh.store)
          .importArchive(exported.archivePath);

      expect(await fresh.db.allTags(), hasLength(1));
    });
  });

  group('rejects bad input', () {
    test('a file that is not a zip', () async {
      final junk = File(p.join(archiveDir.path, 'not-a-zip.zip'))
        ..writeAsStringSync('hello');
      final fresh = freshInstall();
      addTearDown(fresh.db.close);

      await expectLater(
        BackupService(fresh.db, fresh.store).importArchive(junk.path),
        throwsA(isA<BackupException>()),
      );
    });

    test('a zip with no manifest', () async {
      final path = p.join(archiveDir.path, 'empty.zip');
      final encoder = ZipFileEncoder()..create(path);
      encoder.addArchiveFile(ArchiveFile.string('readme.txt', 'nothing here'));
      await encoder.close();

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      await expectLater(
        BackupService(fresh.db, fresh.store).importArchive(path),
        throwsA(isA<BackupException>()),
      );
    });

    test('a manifest from a newer format is refused, not half-imported',
        () async {
      final path = p.join(archiveDir.path, 'future.zip');
      final encoder = ZipFileEncoder()..create(path);
      encoder.addArchiveFile(ArchiveFile.string(
        manifestFileName,
        jsonEncode({'manifestVersion': manifestVersion + 1, 'entries': []}),
      ));
      await encoder.close();

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      await expectLater(
        BackupService(fresh.db, fresh.store).importArchive(path),
        throwsA(predicate((e) =>
            e is BackupException && e.message.contains('newer version'))),
      );
    });

    test('an entry with no media in the archive is reported, not invented',
        () async {
      final path = p.join(archiveDir.path, 'headless.zip');
      final encoder = ZipFileEncoder()..create(path);
      encoder.addArchiveFile(ArchiveFile.string(
        manifestFileName,
        jsonEncode({
          'manifestVersion': manifestVersion,
          'entryTypes': [
            {
              'id': 1,
              'name': 'Diary',
              'allowedMedium': 'both',
              'maxDurationMs': 300000,
              'encodingProfile': 'balanced',
              'isSystem': true,
              'iconKey': 'book',
              'colorKey': 'indigo',
              'sortOrder': 1,
            }
          ],
          'tags': [],
          'entryTags': [],
          'entries': [
            {
              'id': 1,
              'title': 'no file',
              'medium': 'video',
              'typeId': 1,
              'filePath': 'media/absent.mp4',
              'durationMs': 1000,
              'fileSizeBytes': 10,
              'createdAt': '2026-01-01T00:00:00.000',
              'updatedAt': '2026-01-01T00:00:00.000',
              'recordedAt': '2026-01-01T00:00:00.000',
            }
          ],
        }),
      ));
      await encoder.close();

      final fresh = freshInstall();
      addTearDown(fresh.db.close);
      final result =
          await BackupService(fresh.db, fresh.store).importArchive(path);

      expect(result.imported, 0);
      expect(result.missingMedia, 1);
      // No row was written, so the library cannot show an entry with nothing
      // behind it.
      expect(await fresh.db.watchLibrary(EntryFilter.empty).first, isEmpty);
    });
  });
}
