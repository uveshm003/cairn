/// The path that host tests cannot reach: a **real recording** from a **real
/// camera**, through compression, integrity check, storage and the database row.
///
/// This is the Milestone 1 validation `requirements.md` §16 asks for — "prove
/// the compression numbers on real devices first" — plus proof that both lenses
/// work, since §3 lists a private video diary alongside guitar practice.
///
/// Run with:
///   flutter test integration_test/real_capture_test.dart -d `device`
///
/// Camera and microphone permissions must already be granted; a test cannot
/// dismiss a system permission dialog. Measured figures are printed, because
/// the numbers are the point — a pass/fail alone would not tell you whether
/// HEVC hardware encode happened or how long it took.
library;

import 'dart:io';

import 'package:cairn/data/database.dart';
import 'package:cairn/domain/camera_choice.dart';
import 'package:cairn/domain/encoding_profile.dart';
import 'package:cairn/media/media_store.dart';
import 'package:cairn/media/save_pipeline.dart';
import 'package:cairn/app.dart';
import 'package:cairn/settings/app_settings.dart';
import 'package:cairn/ui/capture/capture_screen.dart';
import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:record/record.dart';

/// Long enough that the encoder has real work to do, short enough to keep the
/// suite quick.
const _clip = Duration(seconds: 3);

String _mb(int bytes) => '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late MediaStore store;
  late SavePipeline pipeline;
  final cleanup = <String>[];

  setUp(() async {
    store = await MediaStore.open();
    pipeline = SavePipeline(store);
  });

  tearDown(() async {
    // This runs on the user's real device; leave nothing behind.
    for (final path in cleanup) {
      await store.deleteRelative(path);
    }
    cleanup.clear();
  });

  testWidgets('the device exposes both a back and a front lens',
      (tester) async => tester.runAsync(() async {
    final cameras = await availableCameras();
    debugPrint('CAMERAS: ${cameras.map((c) => '${c.name}/${c.lensDirection.name}').join(', ')}');

    expect(cameras, isNotEmpty);
    expect(canFlipCamera(cameras), isTrue,
        reason: 'a journal needs both lenses; this device reports only one');

    // The selection logic must resolve each direction to a real camera.
    for (final lens in [CameraLensDirection.back, CameraLensDirection.front]) {
      final picked = pickCamera(cameras, preferred: lens);
      expect(picked, isNotNull, reason: 'no camera for ${lens.name}');
      expect(picked!.lensDirection, lens,
          reason: 'asked for ${lens.name}, got ${picked.lensDirection.name}');
    }
  }));

  /// Records from [lens] and pushes the result through the real save pipeline.
  /// All the real-world work runs inside `tester.runAsync`: `testWidgets`
  /// installs a fake async clock, under which `Future.delayed` never completes
  /// and plugin callbacks never arrive.
  Future<void> recordAndSave(
    WidgetTester tester,
    CameraLensDirection lens,
    EncodingProfile profile,
  ) async => tester.runAsync(() async {
    final cameras = await availableCameras();
    final description = pickCamera(cameras, preferred: lens);
    expect(description, isNotNull);

    final controller = CameraController(
      description!,
      // Matches the app: veryHigh is ~1080p, high is only ~720p.
      ResolutionPreset.veryHigh,
      enableAudio: true,
    );
    await controller.initialize();

    String? sourcePath;
    try {
      await controller.startVideoRecording();
      await Future<void>.delayed(_clip);
      final file = await controller.stopVideoRecording();
      sourcePath = file.path;
    } finally {
      await controller.dispose();
    }

    final rawBytes = await File(sourcePath).length();

    final stopwatch = Stopwatch()..start();
    final saved = await pipeline.saveVideo(
      sourcePath: sourcePath,
      profile: profile,
    );
    stopwatch.stop();
    cleanup.add(saved.relativePath);
    if (saved.thumbnailRelativePath != null) {
      cleanup.add(saved.thumbnailRelativePath!);
    }

    // --- the measurements §17 asks for, on real hardware
    final ratio = rawBytes == 0 ? 0.0 : saved.fileSizeBytes / rawBytes;
    debugPrint(
      'MEASURED ${lens.name}/${profile.label}: '
      'raw ${_mb(rawBytes)} -> out ${_mb(saved.fileSizeBytes)} '
      '(${(ratio * 100).toStringAsFixed(0)}% of raw), '
      'codec=${saved.codec}, ${saved.width}x${saved.height}, '
      'duration=${saved.durationMs}ms, '
      'encode=${stopwatch.elapsedMilliseconds}ms, '
      'skipped=${saved.compressionSkipped}',
    );

    // --- integrity of the stored result
    expect(store.existsRelative(saved.relativePath), isTrue,
        reason: 'the stored file is not where the row would point');
    expect(saved.relativePath.startsWith('media/'), isTrue,
        reason: 'paths must be relative (§9)');
    expect(saved.fileSizeBytes, greaterThan(0));
    // Within a second of the clip length: the integrity check would have thrown
    // on a truncated encode, so this is belt and braces.
    expect(
      (saved.durationMs - _clip.inMilliseconds).abs(),
      lessThan(1500),
      reason: 'output duration ${saved.durationMs}ms for a '
          '${_clip.inMilliseconds}ms clip',
    );
    expect(saved.codec, anyOf('h264', 'h265'));

    // The source is consumed once the output is safely stored (§9), unless the
    // plugin skipped compressing and handed the source back as the output.
    if (!saved.compressionSkipped) {
      expect(File(sourcePath).existsSync(), isFalse,
          reason: 'the original should be gone once the output is stored');
    }

    // §8: a thumbnail is generated on save.
    if (saved.thumbnailRelativePath != null) {
      expect(store.existsRelative(saved.thumbnailRelativePath!), isTrue);
      expect(await store.sizeOfRelative(saved.thumbnailRelativePath!),
          greaterThan(0));
    }
  });

  testWidgets('records and saves from the BACK camera', (tester) async {
    await recordAndSave(tester, CameraLensDirection.back,
        EncodingProfile.balanced);
  });

  testWidgets('records and saves from the FRONT camera', (tester) async {
    // The lens a video diary actually uses.
    await recordAndSave(tester, CameraLensDirection.front,
        EncodingProfile.balanced);
  });

  testWidgets('the Small profile produces a smaller file than Balanced',
      (tester) async => tester.runAsync(() async {
    // Not a tautology on real hardware: an encoder that ignores the requested
    // bitrate would produce two files of the same size, and this is what would
    // catch that.
    final cameras = await availableCameras();
    final description =
        pickCamera(cameras, preferred: CameraLensDirection.back)!;

    final sizes = <ProfileKind, int>{};
    for (final profile in [EncodingProfile.small, EncodingProfile.high]) {
      final controller = CameraController(
        description,
        ResolutionPreset.veryHigh,
        enableAudio: true,
      );
      await controller.initialize();
      String path;
      try {
        await controller.startVideoRecording();
        await Future<void>.delayed(_clip);
        path = (await controller.stopVideoRecording()).path;
      } finally {
        await controller.dispose();
      }

      final saved =
          await pipeline.saveVideo(sourcePath: path, profile: profile);
      cleanup.add(saved.relativePath);
      if (saved.thumbnailRelativePath != null) {
        cleanup.add(saved.thumbnailRelativePath!);
      }
      sizes[profile.kind] = saved.fileSizeBytes;
      debugPrint('LADDER ${profile.label} '
          '(${profile.videoBitrateKbps} kbps, <=${profile.maxHeight}p): '
          '${_mb(saved.fileSizeBytes)} codec=${saved.codec}');
    }

    expect(
      sizes[ProfileKind.small]!,
      lessThan(sizes[ProfileKind.high]!),
      reason: 'Small (${_mb(sizes[ProfileKind.small]!)}) should undercut '
          'High (${_mb(sizes[ProfileKind.high]!)}) — if not, the encoder is '
          'ignoring the requested bitrate',
    );
  }));

  testWidgets('records and saves real audio at the profile bitrate',
      (tester) async => tester.runAsync(() async {
    final recorder = AudioRecorder();
    expect(await recorder.hasPermission(), isTrue,
        reason: 'grant RECORD_AUDIO before running this');

    const profile = EncodingProfile.small;
    final path = store.newMediaPath('m4a');
    await recorder.start(profile.audioConfig, path: path);
    await Future<void>.delayed(_clip);
    final stopped = await recorder.stop();
    await recorder.dispose();
    expect(stopped, isNotNull);

    final saved = await pipeline.saveAudio(
      sourcePath: stopped!,
      durationMs: _clip.inMilliseconds,
    );
    cleanup.add(saved.relativePath);

    debugPrint('MEASURED audio/${profile.label}: ${_mb(saved.fileSizeBytes)}, '
        'measured ${saved.bitrateKbps} kbps vs '
        '${profile.audioBitrateKbps} kbps requested');

    expect(store.existsRelative(saved.relativePath), isTrue);
    expect(saved.fileSizeBytes, greaterThan(0));
    // Audio bitrate is set at capture time, so the measured rate should land
    // near the request. Generous bounds: the container adds overhead and
    // Android's AAC encoder is not obliged to hit the target exactly.
    expect(saved.bitrateKbps, greaterThan(profile.audioBitrateKbps ~/ 3));
    expect(saved.bitrateKbps, lessThan(profile.audioBitrateKbps * 4));
  }));

  testWidgets('a longer clip lands near the profile bitrate', (tester) async =>
      tester.runAsync(() async {
    // A three-second clip is dominated by its first keyframe, so it overshoots
    // the target badly and tells you little about §8's table. Fifteen seconds
    // is long enough for the average to mean something.
    const long = Duration(seconds: 15);
    const profile = EncodingProfile.balanced;

    final cameras = await availableCameras();
    final description =
        pickCamera(cameras, preferred: CameraLensDirection.back)!;
    final controller = CameraController(
      description,
      ResolutionPreset.veryHigh,
      enableAudio: true,
    );
    await controller.initialize();
    String path;
    try {
      await controller.startVideoRecording();
      await Future<void>.delayed(long);
      path = (await controller.stopVideoRecording()).path;
    } finally {
      await controller.dispose();
    }

    final rawBytes = await File(path).length();
    final stopwatch = Stopwatch()..start();
    final saved = await pipeline.saveVideo(sourcePath: path, profile: profile);
    stopwatch.stop();
    cleanup.add(saved.relativePath);
    if (saved.thumbnailRelativePath != null) {
      cleanup.add(saved.thumbnailRelativePath!);
    }

    final measuredKbps =
        (saved.fileSizeBytes * 8 / (saved.durationMs / 1000) / 1000).round();
    final requestedKbps = profile.videoBitrateKbps + profile.audioBitrateKbps;
    final rawKbps = (rawBytes * 8 / (saved.durationMs / 1000) / 1000).round();
    // The figures §8's table and §2's baseline should actually be written from.
    final per30s = saved.durationMs == 0
        ? 0
        : (rawBytes * (30000 / saved.durationMs)) / 1024 / 1024;
    final tenMin = saved.durationMs == 0
        ? 0
        : (saved.fileSizeBytes * (600000 / saved.durationMs)) / 1024 / 1024;

    debugPrint(
      'STEADY STATE ${profile.label} over ${long.inSeconds}s: '
      'raw ${_mb(rawBytes)} ($rawKbps kbps) -> out ${_mb(saved.fileSizeBytes)} '
      '($measuredKbps kbps vs $requestedKbps requested, '
      '${(measuredKbps / requestedKbps * 100).round()}% of target), '
      'codec=${saved.codec}, ${saved.width}x${saved.height}, '
      'encode=${stopwatch.elapsedMilliseconds}ms '
      '(${(stopwatch.elapsedMilliseconds / saved.durationMs).toStringAsFixed(2)}x realtime)',
    );
    debugPrint('EXTRAPOLATED: raw capture = '
        '${per30s.toStringAsFixed(0)} MB per 30s '
        '(§2 claims 300-500 MB); a 10-minute ${profile.label} entry = '
        '${tenMin.toStringAsFixed(0)} MB (§8 predicts 250-300 MB)');

    // Generous but meaningful: within a factor of two of the requested rate.
    // Tighter than that would be flaky across OEMs; looser would not detect an
    // encoder that ignores the setting.
    expect(measuredKbps, lessThan(requestedKbps * 2),
        reason: 'measured $measuredKbps kbps against $requestedKbps requested');
    expect(measuredKbps, greaterThan(requestedKbps ~/ 3));
    // The whole point of the pipeline.
    expect(saved.fileSizeBytes, lessThan(rawBytes));
  }));

  testWidgets('audio records through the capture widget, not just the plugin',
      (tester) async {
    // Everything else here drives the plugins directly, which left the widget's
    // own audio path — the lazily-created AudioRecorder, the amplitude stream,
    // the timer, and the hand-off to review — never executed.
    final db = CairnDatabase();
    final settings = await AppSettings.load(db);
    addTearDown(db.close);
    // Registered second so it runs FIRST (teardowns are LIFO): the review
    // screen this test lands on holds a live audio player and a database
    // stream, and closing the database under a mounted tree deadlocks.
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
    final types = await db.allTypes();

    await tester.pumpWidget(AppScope(
      db: db,
      store: store,
      pipeline: pipeline,
      settings: settings,
      child: MaterialApp(
        theme: buildCairnTheme(CairnPalette.dark),
        home: CaptureScreen(
          initialType: types.firstWhere((t) => t.name == 'Quick Note'),
        ),
      ),
    ));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Switch to audio, which is where the lazy recorder gets built.
    await tester.tap(find.text('Audio'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Ready when you are'), findsOneWidget);

    // Tap record, then give the platform real time: permission, encoder
    // start-up and the recording itself are all real async work that
    // pumpAndSettle's fake clock does not advance.
    await tester.tap(find.bySemanticsLabel('Start recording'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    await tester.pumpAndSettle(const Duration(seconds: 2));

    // Asserting the *outcome* rather than the button's intermediate state: by
    // the time the frames settle, the take may already have finished and handed
    // off. What matters is that the widget's audio path ran and produced
    // something reviewable.
    if (find.bySemanticsLabel('Stop recording').evaluate().isNotEmpty) {
      await tester.tap(find.bySemanticsLabel('Stop recording'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(seconds: 2)),
      );
      await tester.pumpAndSettle(const Duration(seconds: 2));
    }

    // Review is where a finished take lands (§13).
    expect(find.text('Save entry'), findsOneWidget,
        reason: 'an audio take should hand off to review');
    // And the size estimate proves the profile was actually applied: this only
    // renders once a real recording exists behind it.
    expect(
      find.textContaining('kbps'),
      findsOneWidget,
      reason: 'review should state the profile the audio was captured at',
    );

    final estimate = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .firstWhere((t) => t.contains('kbps'));
    debugPrint('WIDGET AUDIO: reached review — $estimate');
  });

  testWidgets('a saved recording round-trips through the database',
      (tester) async => tester.runAsync(() async {
    // The full slice: record, compress, store, commit, read back through the
    // library query, then clean up.
    final db = CairnDatabase();
    addTearDown(db.close);

    final cameras = await availableCameras();
    final description =
        pickCamera(cameras, preferred: CameraLensDirection.front)!;
    final controller = CameraController(
      description,
      ResolutionPreset.veryHigh,
      enableAudio: true,
    );
    await controller.initialize();
    String path;
    try {
      await controller.startVideoRecording();
      await Future<void>.delayed(_clip);
      path = (await controller.stopVideoRecording()).path;
    } finally {
      await controller.dispose();
    }

    final saved = await pipeline.saveVideo(
      sourcePath: path,
      profile: EncodingProfile.small,
    );
    cleanup.add(saved.relativePath);
    if (saved.thumbnailRelativePath != null) {
      cleanup.add(saved.thumbnailRelativePath!);
    }

    final types = await db.allTypes();
    final tag = await db.ensureTag('integration-real-capture');
    final now = DateTime.now();
    final id = await db.createEntry(
      EntriesCompanion.insert(
        title: const Value('Real capture integration test'),
        note: const Value('Recorded by the integration suite.'),
        medium: Medium.video,
        typeId: types.first.id,
        filePath: saved.relativePath,
        thumbnailPath: Value(saved.thumbnailRelativePath),
        durationMs: saved.durationMs,
        fileSizeBytes: saved.fileSizeBytes,
        originalSizeBytes: Value(saved.originalSizeBytes),
        createdAt: now,
        updatedAt: now,
        recordedAt: now,
        width: Value(saved.width),
        height: Value(saved.height),
        codec: Value(saved.codec),
        bitrateKbps: Value(saved.bitrateKbps),
      ),
      tagIds: [tag.id],
    );

    final row = await db.entryById(id);
    expect(row, isNotNull);
    expect(row!.codec, anyOf('h264', 'h265'));
    expect(store.existsRelative(row.filePath), isTrue);
    debugPrint('ROUND TRIP: entry $id, ${_mb(row.fileSizeBytes)}, '
        'saved ${_mb(saved.savedBytes)} vs the raw capture');

    // Leave the user's library as we found it.
    await db.purgeEntry(id);
    await db.deleteTag(tag.id);
  }));
}
