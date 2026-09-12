import 'package:cairn/data/database.dart';
import 'package:cairn/services/quick_capture.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The widget/tile bridge.
///
/// The native half (`QuickCapture.kt`, `QuickRecordWidget.kt`,
/// `QuickRecordTileService.kt`) cannot be exercised from a host test -- a real
/// widget tap needs a launcher. What is checked here is the Dart half: the
/// mapping from the intent's string to a medium, and that a missing or broken
/// channel never blocks getting into the app.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('cairn/quick_capture');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answerWith(Object? Function() reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'consumePendingCapture');
      return reply();
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('an audio request opens on audio', () async {
    answerWith(() => 'audio');
    final request = await consumePendingQuickCapture();
    expect(request, QuickCaptureRequest.audio);
    expect(request!.medium, Medium.audio);
  });

  test('a video request opens on video', () async {
    answerWith(() => 'video');
    expect((await consumePendingQuickCapture())!.medium, Medium.video);
  });

  test('the tile leaves the medium to the remembered setting', () async {
    // The quick-settings tile has room for one action, so it sends `any` and
    // lets capture use whatever the user last chose. A null medium is how that
    // is expressed -- not a default of video.
    answerWith(() => 'any');
    final request = await consumePendingQuickCapture();
    expect(request, QuickCaptureRequest.any);
    expect(request!.medium, isNull);
  });

  test('nothing pending is the ordinary case', () async {
    answerWith(() => null);
    expect(await consumePendingQuickCapture(), isNull);
  });

  test('an unrecognised value is ignored rather than guessed at', () async {
    answerWith(() => 'transcribe');
    expect(await consumePendingQuickCapture(), isNull);
  });

  test('no native side is not an error', () async {
    // iOS has no widget yet, and a host test has no plugin at all. Both surface
    // as MissingPluginException, which means "nothing pending", not a failure.
    messenger.setMockMethodCallHandler(channel, null);
    expect(await consumePendingQuickCapture(), isNull);
  });

  test('a broken channel never blocks the app from opening', () async {
    answerWith(() => throw PlatformException(code: 'boom'));
    expect(await consumePendingQuickCapture(), isNull);
  });
}
