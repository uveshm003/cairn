import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:cairn/ui/widgets/marker_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The review screen's half of the marker flow: what was tapped during the take
/// is shown, and a stray one can be dropped before the entry is saved.
///
/// Two neighbouring halves are covered elsewhere, deliberately:
///  - the *rule* that makes an offset safe to store is in
///    `recording_markers_test.dart`, as pure functions;
///  - the capture screen's mark button cannot run on a host at all -- with no
///    camera or microphone plugin, `_start()` never reaches the recording state
///    the button lives in.
void main() {
  Future<void> pump(
    WidgetTester tester,
    List<int> offsets, {
    void Function(int)? onRemove,
    bool enabled = true,
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
            child: MarkerReview(
              offsetsMs: offsets,
              enabled: enabled,
              onRemove: onRemove ?? (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('markers are shown as timestamps, in order', (tester) async {
    // Tapped out of order; displayed in order, because the list is read as a
    // timeline and not as a tap history.
    await pump(tester, [252000, 12000, 61000]);

    expect(find.text('3 markers'), findsOneWidget);
    expect(find.text('0:12'), findsOneWidget);
    expect(find.text('1:01'), findsOneWidget);
    expect(find.text('4:12'), findsOneWidget);

    final positions = ['0:12', '1:01', '4:12']
        .map((label) => tester.getTopLeft(find.text(label)).dx)
        .toList();
    expect(positions, orderedEquals(List.of(positions)..sort()));
  });

  testWidgets('one marker is described in the singular', (tester) async {
    await pump(tester, [5000]);
    expect(find.text('1 marker'), findsOneWidget);
  });

  testWidgets('a stray marker can be removed, and only that one',
      (tester) async {
    final removed = <int>[];
    await pump(tester, [12000, 252000], onRemove: removed.add);

    // Targets the chip for 0:12 specifically rather than "a chip".
    final chip = find.ancestor(
      of: find.text('0:12'),
      matching: find.byType(InputChip),
    );
    await tester.tap(
      find.descendant(of: chip, matching: find.byTooltip('Delete')),
    );
    await tester.pump();

    expect(removed, [12000]);
  });

  testWidgets('markers cannot be removed while the entry is saving',
      (tester) async {
    // Mid-save the offsets are already committed to the pipeline, so letting
    // one be deleted would show a state the database will not agree with.
    final removed = <int>[];
    await pump(tester, [12000], onRemove: removed.add, enabled: false);

    expect(find.byTooltip('Delete'), findsNothing);
    expect(removed, isEmpty);
  });

  for (final scale in [1.3, 1.6, 2.0]) {
    testWidgets('survives ${scale}x text scale on a small phone',
        (tester) async {
      await pump(
        tester,
        List.generate(8, (i) => i * 45000),
        scale: scale,
        width: 320,
      );
      expect(tester.takeException(), isNull,
          reason: 'the marker chips clipped at ${scale}x');
    });
  }

  testWidgets('many markers wrap rather than overflow', (tester) async {
    await pump(tester, List.generate(30, (i) => i * 20000), width: 320);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders in the dark palette', (tester) async {
    await pump(tester, [12000, 61000], palette: CairnPalette.dark);
    expect(tester.takeException(), isNull);
  });
}
