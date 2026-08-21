/// In-app video capture for the spike.
///
/// This is Cairn's *own* baseline: whatever the `camera` plugin writes is what
/// the real app will be compressing, so it is the right "raw" number for the
/// space-saved stat. It is deliberately **not** the same as a clip from the
/// native camera app — that path exists separately in the lab screen, because
/// only it can test the 300-500 MB claim in requirements.md S2.
library;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

class LabCaptureScreen extends StatefulWidget {
  const LabCaptureScreen({super.key});

  @override
  State<LabCaptureScreen> createState() => _LabCaptureScreenState();
}

class _LabCaptureScreenState extends State<LabCaptureScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _recording = false;
  String? _error;
  Duration _elapsed = Duration.zero;
  Stopwatch? _stopwatch;

  /// Spike ceiling. The real app takes this from the entry type (S6).
  static const _maxDuration = Duration(minutes: 1);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // S14: survive interruption without corrupting anything. Backgrounding
    // mid-record releases the camera, so stop cleanly rather than losing it.
    if (state == AppLifecycleState.inactive && _recording) {
      _stop();
    }
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'No camera available on this device.');
        return;
      }
      final controller = CameraController(
        cameras.first,
        // Capture at a realistic "phone default" so the compression delta the
        // spike measures resembles what real users will see.
        ResolutionPreset.veryHigh,
        enableAudio: true,
      );
      await controller.initialize();
      if (!mounted) return;
      setState(() => _controller = controller);
    } on CameraException catch (e) {
      // Permission denial lands here. The real app requests mic/camera at
      // first record with a one-line rationale first (S10.4).
      setState(() => _error = 'Camera unavailable: ${e.code}');
    }
  }

  Future<void> _start() async {
    final controller = _controller;
    if (controller == null || _recording) return;
    await controller.startVideoRecording();
    _stopwatch = Stopwatch()..start();
    setState(() => _recording = true);
    _tick();
  }

  void _tick() async {
    while (_recording && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!mounted || !_recording) return;
      setState(() => _elapsed = _stopwatch?.elapsed ?? Duration.zero);
      if (_elapsed >= _maxDuration) {
        await _stop(); // auto-stop at the limit (S6)
        return;
      }
    }
  }

  Future<void> _stop() async {
    final controller = _controller;
    if (controller == null || !_recording) return;
    setState(() => _recording = false);
    _stopwatch?.stop();
    final file = await controller.stopVideoRecording();
    if (!mounted) return;
    Navigator.of(context).pop(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: const Text('Record a test clip'),
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            )
          : controller == null
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  alignment: Alignment.bottomCenter,
                  children: [
                    Center(child: CameraPreview(controller)),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 48),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '${_elapsed.inSeconds}s / ${_maxDuration.inSeconds}s',
                            style: const TextStyle(
                              color: Colors.white,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(height: 16),
                          GestureDetector(
                            onTap: _recording ? _stop : _start,
                            child: Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _recording ? Colors.white : Colors.red,
                                border: Border.all(
                                    color: Colors.white70, width: 3),
                              ),
                              child: Icon(
                                _recording ? Icons.stop : Icons.circle,
                                color: _recording ? Colors.red : Colors.white,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _recording
                                ? 'Recording — tap to stop'
                                : 'Tap to record. ~15-20s is plenty.',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
    );
  }
}
