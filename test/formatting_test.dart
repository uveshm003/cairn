import 'package:cairn/data/database.dart';
import 'package:cairn/ui/widgets/formatting.dart';
import 'package:flutter/material.dart' show Brightness;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatBytes', () {
    test('scales through the units', () {
      expect(formatBytes(512), '512 B');
      expect(formatBytes(1536), '1.5 KB');
      expect(formatBytes(7 * 1024 * 1024), '7.0 MB');
    });

    test('drops the decimal once the number is wide', () {
      expect(formatBytes(450 * 1024 * 1024), '450 MB');
    });
  });

  group('formatDuration', () {
    test('seconds below a minute, then minutes', () {
      expect(formatDuration(15500), '16s');
      expect(formatDuration(90000), '1m 30s');
      expect(formatDuration(600000), '10m');
    });

    test('hours for a long practice session', () {
      expect(formatDuration(3900000), '1h 5m');
    });
  });

  group('formatClock', () {
    test('pads seconds so the width does not jump while recording', () {
      expect(formatClock(5000), '0:05');
      expect(formatClock(65000), '1:05');
      expect(formatClock(600000), '10:00');
    });
  });

  group('displayTitle', () {
    EntryRow entry({String? title}) => EntryRow(
          id: 1,
          title: title,
          medium: Medium.video,
          typeId: 1,
          filePath: 'media/x.mp4',
          durationMs: 1000,
          fileSizeBytes: 10,
          createdAt: DateTime(2026, 5, 10, 14, 30),
          updatedAt: DateTime(2026, 5, 10, 14, 30),
          recordedAt: DateTime(2026, 5, 10, 14, 30),
          isFavorite: false,
          isDeleted: false,
        );

    test('uses the title when there is one', () {
      expect(displayTitle(entry(title: 'Travis pattern'), 'Diary'),
          'Travis pattern');
    });

    test('falls back to the S6 auto-title when the title is empty', () {
      // Whitespace counts as empty: a title of spaces would otherwise render as
      // a blank row in the library.
      for (final blank in [null, '', '   ']) {
        final result = displayTitle(entry(title: blank), 'Diary');
        expect(result, contains('Diary'));
        expect(result, contains('2026'));
      }
    });
  });

  test('iconForKey and colorForKey never fail on an unknown key', () {
    // Keys come out of the database and could arrive from an imported archive
    // written by a different build, so an unknown one must degrade rather than
    // throw.
    expect(() => iconForKey('nonsense'), returnsNormally);
    expect(() => colorForKey('nonsense', Brightness.dark), returnsNormally);
  });
}
