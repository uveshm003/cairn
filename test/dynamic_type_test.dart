import 'package:cairn/data/database.dart';
import 'package:cairn/data/library_queries.dart';
import 'package:cairn/ui/library/entry_tile.dart';
import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:cairn/ui/widgets/cairn_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// §14 asks for dynamic type, and a designed type scale makes fixed-width
/// layouts *worse*, not better. These pump the components that actually carry
/// text, at large scales, and assert no overflow. Two real clipping bugs (the
/// meta line and the tag row) were found this way.
///
/// Deliberately widget-level rather than whole-app: pumping `CairnApp` keeps a
/// live Drift stream open, and tearing the database down under a mounted
/// StreamBuilder deadlocks the runner. The layout bugs live in the components
/// anyway.
void main() {
  /// An entry whose text is long enough to actually stress the layout. Short
  /// strings never reveal an overflow.
  LibraryItem item({
    String title = 'A deliberately long entry title that keeps going well '
        'past a single line',
    List<String> tags = const ['fingerpicking', 'slow-practice', 'metronome'],
    Medium medium = Medium.video,
    bool favourite = true,
  }) {
    final at = DateTime(2026, 5, 12, 16, 41);
    return LibraryItem(
      entry: EntryRow(
        id: 1,
        title: title,
        note: 'A note long enough to wrap several times over.',
        medium: medium,
        typeId: 1,
        filePath: 'media/x.mp4',
        // Left null, so the tile draws its placeholder and never needs an
        // AppScope to resolve a real file.
        durationMs: 754000,
        fileSizeBytes: 4194304,
        createdAt: at,
        updatedAt: at,
        recordedAt: at,
        isFavorite: favourite,
        isDeleted: false,
      ),
      typeName: 'Practice',
      iconKey: 'music',
      colorKey: 'teal',
      tagNames: tags,
    );
  }

  Future<void> pumpAt(
    WidgetTester tester,
    Widget child, {
    required double scale,
    double width = 390,
    CairnPalette palette = CairnPalette.light,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = Size(width, 900) * 3;
    // Set on the view: MaterialApp builds its own MediaQuery from it, so a
    // wrapping MediaQuery would simply be discarded.
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(MaterialApp(
      theme: buildCairnTheme(palette),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(Space.gutter),
            child: child,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  for (final scale in [1.0, 1.3, 1.6, 2.0]) {
    testWidgets('entry list tile survives ${scale}x text scale',
        (tester) async {
      await pumpAt(
        tester,
        EntryListTile(item: item(), onTap: () {}),
        scale: scale,
      );
      expect(tester.takeException(), isNull,
          reason: 'overflow at ${scale}x — meta line or tag row clipped');
    });

    testWidgets('entry grid tile survives ${scale}x text scale',
        (tester) async {
      await pumpAt(
        tester,
        SizedBox(
          width: 200,
          height: 280,
          child: EntryGridTile(item: item(), onTap: () {}),
        ),
        scale: scale,
      );
      expect(tester.takeException(), isNull,
          reason: 'grid overflow at ${scale}x');
    });
  }

  testWidgets('list tile survives a narrow screen at 2x', (tester) async {
    // The worst realistic case: a small phone at the largest accessibility
    // text scale.
    await pumpAt(
      tester,
      EntryListTile(item: item(), onTap: () {}),
      scale: 2.0,
      width: 320,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('list tile survives several long tags', (tester) async {
    await pumpAt(
      tester,
      EntryListTile(
        item: item(tags: const [
          'a-very-long-tag-name-indeed',
          'another-extremely-long-one',
          'and-a-third',
          'plus-more',
        ]),
        onTap: () {},
      ),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('an untitled entry falls back without breaking layout',
      (tester) async {
    await pumpAt(
      tester,
      EntryListTile(item: item(title: ''), onTap: () {}),
      scale: 1.6,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('audio tile draws its waveform placeholder', (tester) async {
    await pumpAt(
      tester,
      EntryListTile(item: item(medium: Medium.audio), onTap: () {}),
      scale: 1.0,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiles render in the dark palette too', (tester) async {
    await pumpAt(
      tester,
      EntryListTile(item: item(), onTap: () {}),
      scale: 1.6,
      palette: CairnPalette.dark,
    );
    expect(tester.takeException(), isNull);
  });

  group('painted marks', () {
    testWidgets('mark paints across a range of sizes', (tester) async {
      for (final size in [16.0, 26.0, 64.0, 140.0]) {
        await pumpAt(tester, CairnMark(size: size), scale: 1.0);
        expect(tester.takeException(), isNull, reason: 'CairnMark at $size');
      }
    });

    testWidgets('scene paints', (tester) async {
      await pumpAt(tester, const CairnScene(size: 104), scale: 1.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('record button paints in both states', (tester) async {
      await pumpAt(
        tester,
        RecordButton(recording: false, onTap: () {}),
        scale: 1.0,
      );
      expect(tester.takeException(), isNull);

      await pumpAt(
        tester,
        RecordButton(recording: true, onTap: () {}),
        scale: 1.0,
      );
      // Pumped, not settled: the breathing ring repeats forever by design, so
      // pumpAndSettle would never return.
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    });
  });
}
