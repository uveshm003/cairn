/// Turns a widget or tile tap into a capture screen.
///
/// Wraps the app's home so it sees both cases: a cold start (the request is
/// already on the launch intent) and a tap while Cairn is in the background (the
/// request arrives through `onNewIntent`, and the app resumes). Nothing here
/// runs on an ordinary launch beyond one channel call that returns null.
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../services/quick_capture.dart';
import 'capture_flow.dart';

class QuickCaptureGate extends StatefulWidget {
  const QuickCaptureGate({super.key, required this.child});

  final Widget child;

  @override
  State<QuickCaptureGate> createState() => _QuickCaptureGateState();
}

class _QuickCaptureGateState extends State<QuickCaptureGate>
    with WidgetsBindingObserver {
  /// Guards against a second capture screen while one is already opening. The
  /// resume that *follows* pushing capture would otherwise re-enter here.
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // After the first frame: pushing a route needs a Navigator, and there is
    // none until the MaterialApp below has built.
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A tap on the widget while Cairn is backgrounded brings it to the front,
    // so resume is the only signal that the intent changed.
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    // Consumed unconditionally, before any decision about acting on it. A
    // request left pending natively does not stay harmless: it survives to some
    // later, unrelated resume and opens the viewfinder with no tap behind it.
    final request = await consumePendingQuickCapture();
    if (request == null || !mounted) return;

    // Still in onboarding: S10 puts the offline promise before anything else,
    // so a widget tap is dropped rather than queued.
    //
    // Read live from settings rather than from a flag passed in at launch.
    // `completeOnboarding()` flips this mid-session and onboarding leaves via
    // `pushReplacement`, so a launch-time bool still said "not onboarded" for
    // the rest of the session -- which made quick capture dead until the app
    // was restarted, on exactly the install where someone is trying it out.
    if (!AppScope.of(context).settings.onboarded) return;

    // Already in capture, or on the way there. The tap has done everything it
    // usefully can -- the app is in the foreground showing the viewfinder -- so
    // it is dropped here rather than kept to re-open capture the moment the
    // user closes it.
    if (_opening) return;

    _opening = true;
    try {
      await startCapture(context, medium: request.medium);
    } finally {
      // Cleared only after capture closes, so the resume it triggers on the way
      // back cannot immediately reopen it.
      _opening = false;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
