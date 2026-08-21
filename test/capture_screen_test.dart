import 'dart:io';

import 'package:cairn/app.dart';
import 'package:cairn/data/database.dart';
import 'package:cairn/media/media_store.dart';
import 'package:cairn/media/save_pipeline.dart';
import 'package:cairn/settings/app_settings.dart';
import 'package:cairn/ui/capture/capture_screen.dart';
import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A widget-level smoke test for capture.
///
/// This exists because a real bug shipped past every other test: `_prepare()`
/// was called from `initState`, where reading `AppScope` throws, so the capture
/// screen was dead on arrival. The integration tests drive the camera *plugin*
/// directly and never build this widget, so nothing caught it.
///
/// There is no camera plugin in a host test, so enumeration fails — which is
/// precisely the path a device with no camera, or a denied permission, takes.
/// The screen must land on its retry state rather than an unresolved spinner or
/// an unhandled exception.
void main() {
  late Directory root;
  late CairnDatabase db;
  late MediaStore store;
  late AppSettings settings;
  late EntryTypeRow videoType;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('cairn-capture');
    db = CairnDatabase.forTesting(NativeDatabase.memory());
    store = MediaStore.forTesting(root);
    settings = await AppSettings.load(db);
    final types = await db.allTypes();
    videoType = types.firstWhere((t) => t.name == 'Quick Note');
  });

  tearDown(() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpCapture(WidgetTester tester, {EntryTypeRow? type}) async {
    await tester.pumpWidget(
      AppScope(
        db: db,
        store: store,
        // Real, and cheap: it touches no plugin until a save happens, which
        // cannot occur without a camera.
        pipeline: SavePipeline(store),
        settings: settings,
        child: MaterialApp(
          theme: buildCairnTheme(CairnPalette.dark),
          home: CaptureScreen(initialType: type ?? videoType),
        ),
      ),
    );
    // Camera enumeration is a real platform-channel call. `pump` only advances
    // the fake clock, so give the channel actual time to reject before pumping
    // the resulting state in. Fixed pumps rather than pumpAndSettle, because the
    // record button's ring animates indefinitely while recording.
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 120),
        ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('builds without touching AppScope too early', (tester) async {
    await pumpCapture(tester);
    // The specific failure this guards: "dependOnInheritedWidgetOfExactType
    // was called before initState completed".
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the chrome regardless of camera availability',
      (tester) async {
    await pumpCapture(tester);
    // Type pill, medium toggle, and the limit readout are all independent of
    // whether a camera opened.
    expect(find.text('Quick Note'), findsOneWidget);
    expect(find.text('Video'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    // Quick Note is capped at one minute (§6).
    expect(find.textContaining('/ 1:00'), findsOneWidget);
  });

  testWidgets('an unavailable camera lands on a retry state, not a spinner',
      (tester) async {
    await pumpCapture(tester);
    // Enumeration throws MissingPluginException here. Before the fix that
    // became an unhandled error; now it is an explained state with a way out.
    expect(find.text('Try again'), findsOneWidget);
    expect(
      find.textContaining('could not be opened'),
      findsOneWidget,
      reason: 'the failure should be explained, not just retryable',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('starts in audio for an audio-only type', (tester) async {
    // No audio-only type ships by default, so make one — the branch exists and
    // should not depend on the seed data.
    final id = await db.into(db.entryTypes).insert(
          EntryTypesCompanion.insert(
            name: 'Voice memo',
            allowedMedium: AllowedMedium.audioOnly,
            maxDurationMs: 120000,
            encodingProfile: ProfileKind.small,
            iconKey: 'bolt',
            colorKey: 'amber',
          ),
        );
    final audioOnly = await db.typeById(id);

    await pumpCapture(tester, type: audioOnly);
    expect(find.text('Voice memo'), findsOneWidget);
    // Audio mode needs no camera, so there is nothing to retry.
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Ready when you are'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('respects the hard duration cap over the type maximum',
      (tester) async {
    // §6: the type's limit, but never above the global ceiling.
    await settings.setHardCapMs(30000);
    await pumpCapture(tester);
    // Quick Note's own cap is 60s; the 30s ceiling must win.
    expect(find.textContaining('/ 0:30'), findsOneWidget);
  });

  testWidgets('survives a large text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpCapture(tester);
    // The near-limit warning used to live in a fixed-height box that clipped.
    expect(tester.takeException(), isNull);
  });
}
