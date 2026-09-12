import 'dart:typed_data';

import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:cairn/ui/widgets/playback_controls.dart';
import 'package:cairn/ui/widgets/waveform.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

/// The transport row and the waveform, pumped directly.
///
/// Both are player-agnostic by design -- they take a position and callbacks --
/// which is what makes them testable without a platform player. The real
/// `just_audio` and `video_player` wiring cannot run on a host, so what is
/// checked here is the part that can be: the state machine and the layout.
void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double scale = 1.0,
    double width = 390,
    CairnPalette palette = CairnPalette.light,
  }) async {
    tester.view.devicePixelRatio = 3;
    tester.view.physicalSize = Size(width, 900) * 3;
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

  group('speed', () {
    test('labels drop trailing zeros but keep real digits', () {
      // "1x" reads better than "1.0x"; "1.25x" must not become "1.2x".
      expect(playbackSpeeds, contains(1.0));
      expect(playbackSpeeds, contains(1.25));
    });

    testWidgets('the current speed is shown, and a change is reported',
        (tester) async {
      double? picked;
      await pump(
        tester,
        PlaybackControls(
          speed: 1.5,
          onSpeedChanged: (value) => picked = value,
          loop: null,
          onSetLoopStart: () {},
          onSetLoopEnd: () {},
          onClearLoop: () {},
        ),
      );

      expect(find.text('1.5×'), findsOneWidget);

      await tester.tap(find.text('1.5×'));
      await tester.pumpAndSettle();
      // 0.5x matters as much as 2x here: slowing a passage down is the whole
      // reason a practice user wants this.
      await tester.tap(find.text('0.5×').last);
      await tester.pumpAndSettle();
      expect(picked, 0.5);
    });
  });

  group('A-B loop', () {
    testWidgets('offers to start a loop when none is set', (tester) async {
      var started = false;
      await pump(
        tester,
        PlaybackControls(
          speed: 1.0,
          onSpeedChanged: (_) {},
          loop: null,
          onSetLoopStart: () => started = true,
          onSetLoopEnd: () {},
          onClearLoop: () {},
        ),
      );

      await tester.tap(find.text('Loop from here'));
      expect(started, isTrue);
    });

    testWidgets('a half-set loop asks for the other end', (tester) async {
      // The real sequence: tap A, listen, tap B at the end of the phrase. The
      // in-between state has to be legible or the control looks broken.
      await pump(
        tester,
        PlaybackControls(
          speed: 1.0,
          onSpeedChanged: (_) {},
          loop: const LoopRegion(startMs: 252000),
          onSetLoopStart: () {},
          onSetLoopEnd: () {},
          onClearLoop: () {},
        ),
      );

      expect(find.textContaining('4:12'), findsOneWidget);
      expect(find.textContaining('tap again to close the loop'), findsOneWidget);
    });

    testWidgets('a complete loop shows its range and can be cleared',
        (tester) async {
      var cleared = false;
      await pump(
        tester,
        PlaybackControls(
          speed: 1.0,
          onSpeedChanged: (_) {},
          loop: const LoopRegion(startMs: 252000, endMs: 268000),
          onSetLoopStart: () {},
          onSetLoopEnd: () {},
          onClearLoop: () => cleared = true,
        ),
      );

      expect(find.textContaining('4:12'), findsOneWidget);
      expect(find.textContaining('4:28'), findsOneWidget);

      // Found by tooltip rather than by icon: the delete glyph is Material's
      // choice and changes between versions, but the semantics do not.
      await tester.tap(find.byTooltip('Delete'));
      expect(cleared, isTrue);
    });

    test('an end before the start is not a usable loop', () {
      // Guards against setting B earlier than A, which would clip to nothing.
      expect(const LoopRegion(startMs: 5000, endMs: 3000).isComplete, isFalse);
      expect(const LoopRegion(startMs: 5000).isComplete, isFalse);
      expect(const LoopRegion(startMs: 5000, endMs: 9000).isComplete, isTrue);
    });

    testWidgets('a half-set loop can be cancelled', (tester) async {
      // A can be placed where the playhead cannot get past it -- the very end of
      // the entry. Without a delete on this state the user was stuck holding a
      // loop that could never complete, short of leaving the screen. Each retry
      // of "close the loop" also re-entered the setClip path, which reloads the
      // source and restarts at 0:00.
      var cleared = false;
      await pump(
        tester,
        PlaybackControls(
          speed: 1.0,
          onSpeedChanged: (_) {},
          loop: const LoopRegion(startMs: 252000),
          onSetLoopStart: () {},
          onSetLoopEnd: () {},
          onClearLoop: () => cleared = true,
        ),
      );

      await tester.tap(find.byTooltip('Cancel loop'));
      expect(cleared, isTrue);
    });
  });

  group('closing a loop', () {
    // Building `LoopRegion(startMs: a, endMs: playhead)` blind produced a region
    // whose `isComplete` was false forever whenever the playhead sat before A.
    test('the ends are ordered, so a playhead before A still closes', () {
      // Seeking back and tapping again means "the passage between these two
      // points", not "store something unusable".
      final closed = closeLoop(startMs: 252000, atMs: 120000);
      expect(closed, isNotNull);
      expect(closed!.startMs, 120000);
      expect(closed.endMs, 252000);
      expect(closed.isComplete, isTrue);
    });

    test('a playhead after A closes the ordinary way', () {
      final closed = closeLoop(startMs: 252000, atMs: 268000);
      expect(closed!.startMs, 252000);
      expect(closed.endMs, 268000);
      expect(closed.isComplete, isTrue);
    });

    test('coinciding ends are refused rather than stored as a dead region', () {
      // A zero-length loop is not a loop. Null keeps the half-set state, which
      // now offers a cancel, instead of replacing it with something inert.
      expect(closeLoop(startMs: 252000, atMs: 252000), isNull);
    });

    test('every closed region is complete, whichever way it was tapped', () {
      for (final at in [0, 1, 251999, 252001, 600000]) {
        expect(closeLoop(startMs: 252000, atMs: at)!.isComplete, isTrue,
            reason: 'playhead at $at');
      }
    });
  });

  group('whether a loop change reaches the player', () {
    // `setClip()` with no arguments reloads the source and restarts at 0:00, so
    // "no clip needed and none installed" has to short-circuit before it. The
    // case that regressed is the first one: placing A used to call setClip()
    // unconditionally, which threw the user back to the start of the entry on
    // the very first tap of the feature.
    test('placing A with no clip installed does not touch the player', () {
      expect(
        loopNeedsPlayerCall(
          region: const LoopRegion(startMs: 252000),
          clipApplied: false,
        ),
        isFalse,
      );
    });

    test('a complete loop installs the clip', () {
      expect(
        loopNeedsPlayerCall(
          region: const LoopRegion(startMs: 252000, endMs: 268000),
          clipApplied: false,
        ),
        isTrue,
      );
    });

    test('clearing a loop that has a clip tears it down', () {
      expect(loopNeedsPlayerCall(region: null, clipApplied: true), isTrue);
    });

    test('clearing when nothing is installed is a no-op', () {
      expect(loopNeedsPlayerCall(region: null, clipApplied: false), isFalse);
    });

    test('an unusable region with a clip installed still tears it down', () {
      // Reaching this means the region was rejected somewhere; the clip that is
      // actually on the player must still come off.
      expect(
        loopNeedsPlayerCall(
          region: const LoopRegion(startMs: 5000, endMs: 3000),
          clipApplied: true,
        ),
        isTrue,
      );
    });
  });

  group('seeking inside a loop', () {
    // `setClip` makes the player's timeline clip-relative in BOTH directions:
    // positions come back relative to the clip start, and `seek` expects a
    // clip-relative offset. Correcting only the read side -- which is the easy
    // half to notice -- leaves every tap overshooting by the loop start.
    const loop = LoopRegion(startMs: 252000, endMs: 268000);

    test('with no loop, the target is passed through untouched', () {
      final action = resolveSeek(targetMs: 90000, loop: null);
      expect(action.clearLoop, isFalse);
      expect(action.seekMs, 90000);
    });

    test('a half-set loop has no clip yet, so nothing is corrected', () {
      final action = resolveSeek(
        targetMs: 90000,
        loop: const LoopRegion(startMs: 252000),
      );
      expect(action.seekMs, 90000);
    });

    test('a target inside the loop is rebased onto the clip', () {
      // 4:20 inside a 4:12-4:28 loop is 8s into the clip, not 260s.
      final action = resolveSeek(targetMs: 260000, loop: loop);
      expect(action.clearLoop, isFalse);
      expect(action.seekMs, 8000);
    });

    test('the loop start rebases to zero', () {
      expect(resolveSeek(targetMs: 252000, loop: loop).seekMs, 0);
    });

    test('a target before the loop leaves it', () {
      // Tapping a marker at 0:12 while looping 4:12-4:28 means "go to 0:12".
      // Clamping into the loop would ignore the tap.
      final action = resolveSeek(targetMs: 12000, loop: loop);
      expect(action.clearLoop, isTrue);
      expect(action.seekMs, 12000);
    });

    test('a target after the loop also leaves it', () {
      final action = resolveSeek(targetMs: 400000, loop: loop);
      expect(action.clearLoop, isTrue);
      expect(action.seekMs, 400000);
    });

    test('a rebased seek is never negative', () {
      // The failure this guards: seeking to a negative offset inside a clip.
      for (final target in [252000, 255000, 268000]) {
        expect(resolveSeek(targetMs: target, loop: loop).seekMs,
            greaterThanOrEqualTo(0));
      }
    });
  });

  group('skip silence', () {
    testWidgets('is absent when the platform does not support it',
        (tester) async {
      // just_audio implements it on Android only. A dead switch is worse than
      // no switch, so a null means the control is not built at all.
      await pump(
        tester,
        PlaybackControls(
          speed: 1.0,
          onSpeedChanged: (_) {},
          loop: null,
          onSetLoopStart: () {},
          onSetLoopEnd: () {},
          onClearLoop: () {},
          skipSilence: null,
        ),
      );
      expect(find.text('Skip silence'), findsNothing);
    });

    testWidgets('is offered where it is supported', (tester) async {
      bool? changed;
      await pump(
        tester,
        PlaybackControls(
          speed: 1.0,
          onSpeedChanged: (_) {},
          loop: null,
          onSetLoopStart: () {},
          onSetLoopEnd: () {},
          onClearLoop: () {},
          skipSilence: false,
          onSkipSilenceChanged: (value) => changed = value,
        ),
      );

      await tester.tap(find.text('Skip silence'));
      expect(changed, isTrue);
    });
  });

  group('waveform', () {
    Uint8List envelope() =>
        Uint8List.fromList(List.generate(400, (i) => (i * 7) % 256));

    testWidgets('seeks to the tapped position', (tester) async {
      int? sought;
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 0,
          durationMs: 600000,
          onSeek: (ms) => sought = ms,
        ),
      );

      final box = tester.getRect(find.byType(WaveformScrubber));
      await tester.tapAt(Offset(box.left + box.width / 2, box.center.dy));
      await tester.pump();

      // Mid-strip on a 10-minute entry is about 5 minutes in.
      expect(sought, isNotNull);
      expect(sought, closeTo(300000, 20000));
    });

    testWidgets('a vertical scroll over the waveform does not seek',
        (tester) async {
      // This committed on `onTapDown`, which `TapGestureRecognizer` fires once a
      // press outlives kPressTimeout -- even when the gesture goes on to become
      // a vertical scroll of the screen the waveform sits in. Resting a finger
      // on the waveform and scrolling the page seeked the entry.
      final seeks = <int>[];
      // The filler matters: a `SingleChildScrollView` with nothing to scroll
      // reports `canDrag == false` and contributes no recognizer at all, so the
      // tap would win uncontested and the test would pass against the bug. The
      // detail screen this lives on is a real, scrollable ListView.
      await pump(
        tester,
        Column(
          children: [
            WaveformScrubber(
              envelope: envelope(),
              positionMs: 0,
              durationMs: 600000,
              onSeek: seeks.add,
            ),
            const SizedBox(height: 2000),
          ],
        ),
      );

      final box = tester.getRect(find.byType(WaveformScrubber));
      final gesture = await tester.startGesture(box.center);
      // Held past the tap deadline, then dragged vertically: the scroll view
      // wins the arena and the tap is cancelled.
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.moveBy(const Offset(0, -160));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(seeks, isEmpty);
    });

    testWidgets('a drag scrubs and commits once, on release', (tester) async {
      final seeks = <int>[];
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 0,
          durationMs: 600000,
          onSeek: seeks.add,
        ),
      );

      final box = tester.getRect(find.byType(WaveformScrubber));
      final gesture =
          await tester.startGesture(Offset(box.left + 10, box.center.dy));
      await gesture.moveBy(const Offset(120, 0));
      await tester.pump();
      // Nothing committed mid-drag: seeking on every frame would thrash the
      // player. The playhead still follows the finger visually.
      expect(seeks, isEmpty);

      await gesture.up();
      await tester.pump();
      expect(seeks, hasLength(1));
    });

    testWidgets('announces itself as an adjustable slider', (tester) async {
      // This widget replaced a real `Slider` for every entry that has an
      // envelope. A `slider: true` node with no increase/decrease actions
      // announces a control assistive tech cannot move, which is strictly worse
      // than the Slider it replaced -- and no overflow check would notice.
      // Disposed explicitly rather than via addTearDown: the framework's
      // end-of-test check for leaked handles runs *before* teardowns.
      final handle = tester.ensureSemantics();

      final seeks = <int>[];
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 300000,
          durationMs: 600000,
          onSeek: seeks.add,
        ),
      );

      final node = tester.getSemantics(find.byType(WaveformScrubber));
      expect(node.getSemanticsData().flagsCollection.isSlider, isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue,
          reason: 'TalkBack cannot move a slider with no increase action');
      expect(node.getSemanticsData().hasAction(SemanticsAction.decrease), isTrue);
      expect(node.label, 'Playback position');
      expect(node.value, '5:00');
      handle.dispose();
    });

    testWidgets('an assistive nudge moves by a useful step', (tester) async {
      // Disposed explicitly rather than via addTearDown: the framework's
      // end-of-test check for leaked handles runs *before* teardowns.
      final handle = tester.ensureSemantics();

      final seeks = <int>[];
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 300000,
          durationMs: 600000,
          onSeek: seeks.add,
        ),
      );

      // Driven through the semantics tree, so the action must genuinely be
      // wired up -- calling the callback directly would prove nothing. This
      // helper also throws if the node does not support the action at all.
      tester.semantics.increase(find.semantics.byLabel('Playback position'));
      await tester.pump();

      // 10-minute entry: a twentieth is 30s, so one nudge lands at 5:30.
      // Fixed 10s steps would need 60 nudges to cross the entry.
      expect(seeks.single, 330000);

      tester.semantics.decrease(find.semantics.byLabel('Playback position'));
      await tester.pump();
      expect(seeks.last, 270000);
      handle.dispose();
    });

    testWidgets('nudging at the ends stays inside the entry', (tester) async {
      // Disposed explicitly rather than via addTearDown: the framework's
      // end-of-test check for leaked handles runs *before* teardowns.
      final handle = tester.ensureSemantics();

      final seeks = <int>[];
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 0,
          durationMs: 600000,
          onSeek: seeks.add,
        ),
      );

      tester.semantics.decrease(find.semantics.byLabel('Playback position'));
      await tester.pump();
      expect(seeks.single, 0, reason: 'a seek before the start is not a seek');
      handle.dispose();
    });

    testWidgets('a zero-duration entry does not throw', (tester) async {
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 0,
          durationMs: 0,
          onSeek: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('markers paint over the waveform without error',
        (tester) async {
      await pump(
        tester,
        WaveformScrubber(
          envelope: envelope(),
          positionMs: 120000,
          durationMs: 600000,
          markerOffsetsMs: const [0, 90000, 599999],
          onSeek: (_) {},
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('marker ticks survive a zero duration', (tester) async {
      await pump(
        tester,
        MarkerTicks(
          offsetsMs: const [1000],
          durationMs: 0,
          color: const Color(0xFFFF0000),
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the jump row reports the marker it was asked for',
        (tester) async {
      int? jumped;
      await pump(
        tester,
        MarkerJumpRow(
          offsetsMs: const [252000, 12000],
          onJump: (ms) => jumped = ms,
        ),
      );

      // Sorted for display, so 0:12 comes first regardless of insertion order.
      expect(find.text('0:12'), findsOneWidget);
      await tester.tap(find.text('4:12'));
      expect(jumped, 252000);
    });
  });

  group('dynamic type', () {
    for (final scale in [1.3, 1.6, 2.0]) {
      testWidgets('transport row survives ${scale}x text scale',
          (tester) async {
        await pump(
          tester,
          PlaybackControls(
            speed: 1.25,
            onSpeedChanged: (_) {},
            loop: const LoopRegion(startMs: 252000, endMs: 268000),
            onSetLoopStart: () {},
            onSetLoopEnd: () {},
            onClearLoop: () {},
            skipSilence: true,
            onSkipSilenceChanged: (_) {},
          ),
          scale: scale,
          width: 320,
        );
        expect(tester.takeException(), isNull,
            reason: 'the transport row clipped at ${scale}x on a small phone');
      });
    }

    testWidgets('the jump row scrolls rather than overflowing', (tester) async {
      // Twenty markers on a 320dp screen: a Wrap would grow unbounded inside a
      // fixed-height slot, so this row scrolls horizontally instead.
      await pump(
        tester,
        MarkerJumpRow(
          offsetsMs: List.generate(20, (i) => i * 30000),
          onJump: (_) {},
        ),
        scale: 1.6,
        width: 320,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in the dark palette', (tester) async {
      await pump(
        tester,
        WaveformScrubber(
          envelope: Uint8List.fromList([10, 200, 90, 255]),
          positionMs: 1000,
          durationMs: 4000,
          markerOffsetsMs: const [2000],
          onSeek: (_) {},
        ),
        palette: CairnPalette.dark,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
