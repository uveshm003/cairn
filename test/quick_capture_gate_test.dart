import 'dart:io';

import 'package:cairn/app.dart';
import 'package:cairn/data/database.dart';
import 'package:cairn/media/media_store.dart';
import 'package:cairn/media/save_pipeline.dart';
import 'package:cairn/settings/app_settings.dart';
import 'package:cairn/ui/capture/capture_screen.dart';
import 'package:cairn/ui/capture/quick_capture_gate.dart';
import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widget/tile gate, with a fake native side.
///
/// `quick_capture_test.dart` covers the channel decode; nothing covered the
/// gate, which is where two bugs lived. Both are about a request the gate
/// *cannot act on right now*: it was left pending natively, and a pending
/// request does not stay harmless -- it fires on the next unrelated resume and
/// opens the viewfinder with nobody having tapped anything.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cairn/quick_capture');

  late Directory root;
  late CairnDatabase db;
  late MediaStore store;
  late AppSettings settings;

  /// Stands in for `MainActivity`: holds one request, and consuming clears it.
  String? pending;
  var consumeCalls = 0;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('cairn-gate');
    db = CairnDatabase.forTesting(NativeDatabase.memory());
    store = MediaStore.forTesting(root);
    settings = await AppSettings.load(db);
    pending = null;
    consumeCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'consumePendingCapture') return null;
      consumeCalls++;
      final value = pending;
      pending = null;
      return value;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// The channel call is a real async hop, so the fake clock alone will not
  /// advance it -- hence `runAsync` before pumping the result in.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 60)),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> pumpGate(WidgetTester tester) async {
    await tester.pumpWidget(AppScope(
      db: db,
      store: store,
      pipeline: SavePipeline(store),
      settings: settings,
      child: MaterialApp(
        theme: buildCairnTheme(CairnPalette.dark),
        home: const QuickCaptureGate(
          child: Scaffold(body: Center(child: Text('library'))),
        ),
      ),
    ));
    await settle(tester);
  }

  /// A tap on the widget while Cairn is backgrounded: the request lands on the
  /// intent and the app resumes, which is the only signal the gate gets.
  Future<void> resume(WidgetTester tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle(tester);
  }

  testWidgets('an ordinary launch asks once and stays put', (tester) async {
    await pumpGate(tester);

    expect(consumeCalls, 1, reason: 'one channel call, every launch');
    expect(find.byType(CaptureScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a widget tap opens capture on the medium it names',
      (tester) async {
    await settings.completeOnboarding();
    pending = 'audio';

    await pumpGate(tester);

    expect(find.byType(CaptureScreen), findsOneWidget);
  });

  testWidgets('onboarding is not jumped over, and the request does not '
      'outlive it', (tester) async {
    // S10 puts the offline promise before anything else, so the tap is dropped.
    // The bug was *how* it was dropped: the gate returned before consuming, so
    // the request sat on the native side and opened the viewfinder on some
    // later, unrelated resume.
    pending = 'video';

    await pumpGate(tester);

    expect(find.byType(CaptureScreen), findsNothing);
    expect(pending, isNull, reason: 'consumed and discarded, not queued');

    await resume(tester);
    expect(find.byType(CaptureScreen), findsNothing,
        reason: 'a dropped request must not resurface on a later resume');
  });

  testWidgets('quick capture works in the session onboarding finished in',
      (tester) async {
    // The gate used to be told `enabled: !showOnboarding`, a bool fixed when the
    // process started. Onboarding leaves via `pushReplacement`, so that bool
    // still said "not onboarded" for the rest of the session and every tap was
    // swallowed -- on exactly the install where someone is trying the feature
    // out for the first time.
    await pumpGate(tester);
    expect(find.byType(CaptureScreen), findsNothing);

    await settings.completeOnboarding();
    pending = 'audio';
    await resume(tester);

    expect(find.byType(CaptureScreen), findsOneWidget);
  });

  testWidgets('a tap arriving while capture is open does not reopen it later',
      (tester) async {
    await settings.completeOnboarding();
    pending = 'audio';
    await pumpGate(tester);
    expect(find.byType(CaptureScreen), findsOneWidget);

    // Tapped again from the shade while the viewfinder is already up. The app is
    // already in the foreground showing capture, so the tap has done all it
    // usefully can; what it must not do is queue a second capture screen for
    // whenever the user backs out of this one.
    pending = 'video';
    await resume(tester);
    expect(pending, isNull, reason: 'drained rather than left pending');

    Navigator.of(tester.element(find.byType(CaptureScreen))).pop();
    await settle(tester);

    expect(find.byType(CaptureScreen), findsNothing);
  });
}
