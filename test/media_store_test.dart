import 'dart:io';

import 'package:cairn/media/media_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// S9's storage rules, tested against a real temporary filesystem.
void main() {
  late Directory root;
  late MediaStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('cairn-store');
    store = MediaStore.forTesting(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File writeInto(String dir, String name, int bytes) {
    final file = File(p.join(root.path, dir, name));
    file.writeAsBytesSync(List.filled(bytes, 1));
    return file;
  }

  group('paths', () {
    test('newMediaPath is a uuid, never the user title', () {
      final path = store.newMediaPath('mp4');
      final name = p.basenameWithoutExtension(path);
      // 8-4-4-4-12 hex. Names derived from titles break on emoji, slashes and
      // duplicates, so the rule is that they never are.
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
            .hasMatch(name),
        isTrue,
        reason: name,
      );
      expect(p.extension(path), '.mp4');
    });

    test('resolve and relativize are inverses', () {
      const relative = 'media/abc.mp4';
      expect(store.relativize(store.resolve(relative)), relative);
    });

    test('relativize produces a path with no leading slash', () {
      // A stored path must be relative, or iOS container changes break playback.
      final absolute = store.newMediaPath('mp4');
      final relative = store.relativize(absolute);
      expect(p.isAbsolute(relative), isFalse);
      expect(relative.startsWith('media/'), isTrue);
    });

    test('handles an extension given with or without a dot', () {
      expect(p.extension(store.newMediaPath('m4a')), '.m4a');
      expect(p.extension(store.newMediaPath('.m4a')), '.m4a');
    });
  });

  group('adopt', () {
    test('moves the file and returns a relative path', () async {
      final source = File(p.join(root.path, 'incoming.mp4'))
        ..writeAsBytesSync(List.filled(64, 2));

      final relative = await store.adopt(source.path);

      expect(relative.startsWith('media/'), isTrue);
      expect(store.existsRelative(relative), isTrue);
      // Moved, not copied -- the cache copy must not linger.
      expect(source.existsSync(), isFalse);
      expect(await store.sizeOfRelative(relative), 64);
    });

    test('thumbnails and originals land in their own directories', () async {
      final thumb = File(p.join(root.path, 'a.jpg'))..writeAsBytesSync([1]);
      final original = File(p.join(root.path, 'b.mp4'))..writeAsBytesSync([1]);

      expect(await store.adopt(thumb.path, thumbnail: true),
          startsWith('thumbs/'));
      expect(await store.adopt(original.path, original: true),
          startsWith('originals/'));
    });
  });

  group('orphan sweep', () {
    test('reports files with no row and rows with no file', () {
      final orphan = writeInto(MediaStore.mediaDirName, 'loose.mp4', 10);
      writeInto(MediaStore.mediaDirName, 'referenced.mp4', 10);

      final report = store.findOrphans(
        referencedPaths: {'media/referenced.mp4', 'media/vanished.mp4'},
        pathsByEntry: {
          1: ['media/referenced.mp4'],
          2: ['media/vanished.mp4'],
        },
      );

      expect(report.filesWithoutRows, [store.relativize(orphan.path)]);
      expect(report.rowsWithoutFiles, [2]);
      expect(report.isClean, isFalse);
    });

    test('never flags a kept original', () {
      // The whole point of the originals directory: these files are referenced
      // by nothing, so a sweep that saw them would delete exactly the files the
      // "keep originals" setting exists to preserve.
      writeInto(MediaStore.originalsDirName, 'kept.mp4', 4096);

      final report = store.findOrphans(
        referencedPaths: const {},
        pathsByEntry: const {},
      );

      expect(report.filesWithoutRows, isEmpty);
      expect(report.isClean, isTrue);
      expect(store.listAllFiles(), isEmpty);
    });

    test('is clean when everything lines up', () {
      writeInto(MediaStore.mediaDirName, 'one.mp4', 10);
      final report = store.findOrphans(
        referencedPaths: {'media/one.mp4'},
        pathsByEntry: {1: ['media/one.mp4']},
      );
      expect(report.isClean, isTrue);
    });
  });

  group('sizes', () {
    test('totalBytesOnDisk counts originals; originalsBytesOnDisk isolates them',
        () {
      writeInto(MediaStore.mediaDirName, 'a.mp4', 100);
      writeInto(MediaStore.thumbDirName, 'a.jpg', 20);
      writeInto(MediaStore.originalsDirName, 'a-orig.mp4', 900);

      expect(store.originalsBytesOnDisk(), 900);
      // Originals are counted in the total, so storage usage cannot under-report
      // what the app is actually holding.
      expect(store.totalBytesOnDisk(), 1020);
    });

    test('sizeOfRelative returns 0 rather than throwing on a missing file',
        () async {
      expect(await store.sizeOfRelative('media/nope.mp4'), 0);
    });

    test('deleteRelative tolerates null and missing paths', () async {
      await store.deleteRelative(null);
      await store.deleteRelative('media/nope.mp4');
    });
  });
}
