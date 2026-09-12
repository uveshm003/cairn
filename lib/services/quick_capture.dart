/// The bridge for the home-screen widget and the quick-settings tile.
///
/// Principle #4 is "cold-start to recording in <=2 taps"; these entry points get
/// it to one. The native side (`QuickCapture.kt`) puts the requested medium on
/// the launch intent, and this pulls it across.
///
/// **Pull, not push.** A cold start from the widget races the Flutter engine:
/// pushing the request would fire before Dart had a listener, and the tap would
/// be lost -- which is the exact case the feature exists for. So the request
/// waits natively until something asks for it, and asking consumes it.
library;

import 'package:flutter/services.dart';

import '../data/database.dart';

/// What the user asked for, if anything.
enum QuickCaptureRequest {
  /// The remembered medium -- what the quick-settings tile sends.
  any,
  audio,
  video;

  /// The medium to open on, or null to keep whatever capture would have used.
  Medium? get medium => switch (this) {
        QuickCaptureRequest.any => null,
        QuickCaptureRequest.audio => Medium.audio,
        QuickCaptureRequest.video => Medium.video,
      };
}

/// iOS has no widget yet, so this is Android-only in practice. It is not
/// platform-gated here: the channel simply goes unanswered elsewhere, and
/// `MissingPluginException` is handled below as "nothing pending" -- which is
/// the truth on a platform with no widget.
const _channel = MethodChannel('cairn/quick_capture');

/// Takes the pending request, clearing it.
///
/// Returns null when there is nothing pending, which is the overwhelmingly
/// common case -- every ordinary launch of the app.
Future<QuickCaptureRequest?> consumePendingQuickCapture() async {
  try {
    final raw = await _channel.invokeMethod<String>('consumePendingCapture');
    return switch (raw) {
      'audio' => QuickCaptureRequest.audio,
      'video' => QuickCaptureRequest.video,
      'any' => QuickCaptureRequest.any,
      _ => null,
    };
  } on MissingPluginException {
    // No native side: iOS, or a host test. Not an error.
    return null;
  } on PlatformException {
    // A broken channel must never block getting into the app.
    return null;
  }
}
