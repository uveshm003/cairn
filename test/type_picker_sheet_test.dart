import 'dart:io';

import 'package:cairn/app.dart';
import 'package:cairn/data/database.dart';
import 'package:cairn/media/media_store.dart';
import 'package:cairn/media/save_pipeline.dart';
import 'package:cairn/settings/app_settings.dart';
import 'package:cairn/ui/capture/capture_flow.dart';
import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The type picker overflowed by 54px on a real device: a plain `Column` of
/// five two-line `ListTile`s does not fit inside the 9/16-of-screen cap that
/// `showModalBottomSheet` applies by default. Nothing caught it because no test
/// had ever *opened* the sheet.
///
/// Large text scales make the same tiles taller, so these pump the sheet on a
/// short viewport and at accessibility scales and assert it lays out. A
/// RenderFlex overflow is reported during paint, so `takeException` sees it.
void main() {
  late Directory root;
  late CairnDatabase db;
  late MediaStore store;
  late AppSettings settings;
  late EntryTypeRow current;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('cairn-picker');
    db = CairnDatabase.forTesting(NativeDatabase.memory());
    store = MediaStore.forTesting(root);
    settings = await AppSettings.load(db);
    current = (await db.allTypes()).first;
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Opens the sheet for real, through `showTypePicker`, so the sheet's own
  /// constraints are part of what is under test.
  EntryTypeRow? picked;

  Future<void> openPicker(
    WidgetTester tester, {
    required double scale,
    required double height,
    Medium? forMedium,
    CairnPalette palette = CairnPalette.dark,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = Size(390, height) * 3;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(
      AppScope(
        db: db,
        store: store,
        pipeline: SavePipeline(store),
        settings: settings,
        child: MaterialApp(
          theme: buildCairnTheme(palette),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  picked = await showTypePicker(
                    context,
                    current: current,
                    forMedium: forMedium,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    // The picker awaits `allTypes()` before it builds, so the sheet needs a
    // real async turn, not just fake-clock pumps.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('picker fits a short viewport at 1x', (tester) async {
    // 640dp: a small phone, and short enough that five two-line tiles plus the
    // header exceed the default sheet cap.
    await openPicker(tester, scale: 1.0, height: 640);
    expect(find.text('Entry type'), findsOneWidget);
    expect(find.text('How-to'), findsOneWidget);
    expect(tester.takeException(), isNull,
        reason: 'the type list overflowed the sheet');
  });

  for (final scale in [1.3, 1.6, 2.0]) {
    testWidgets('picker fits at ${scale}x text scale', (tester) async {
      await openPicker(tester, scale: scale, height: 800);
      expect(find.text('Entry type'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: 'the type list overflowed at ${scale}x');
    });
  }

  testWidgets('picker survives the worst case: short screen at 2x',
      (tester) async {
    await openPicker(tester, scale: 2.0, height: 600);
    expect(tester.takeException(), isNull);
    // Scrolling is the escape hatch when the list cannot fit, so this case is
    // only meaningful if the last type really does start off the fold --
    // `dragUntilVisible` is a no-op when its target is already on screen.
    expect(find.text('Freeform').hitTestable(), findsNothing,
        reason: 'viewport is not tight enough to exercise scrolling');
    await tester.dragUntilVisible(
      find.text('Freeform'),
      find.byType(SingleChildScrollView).last,
      const Offset(0, -60),
    );
    expect(find.text('Freeform').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a type returns it and closes the sheet', (tester) async {
    // The tiles sit two levels deeper in the tree than they used to; this is
    // the only test that the sheet still does its actual job.
    await openPicker(tester, scale: 1.0, height: 800);
    await tester.tap(find.text('Diary'));
    await tester.pumpAndSettle();
    expect(picked?.name, 'Diary');
    expect(find.text('Entry type'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a video-only type is shown greyed, not hidden, for audio',
      (tester) async {
    await openPicker(tester, scale: 1.0, height: 800, forMedium: Medium.audio);
    expect(find.text('How-to'), findsOneWidget);
    expect(find.text('Video only'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('picker lays out in the light palette too', (tester) async {
    await openPicker(
      tester,
      scale: 1.6,
      height: 700,
      palette: CairnPalette.light,
    );
    expect(tester.takeException(), isNull);
  });
}
