/// Capture (requirements.md S13): live duration against the type's limit,
/// auto-stop at the cap, then straight into review.
///
/// Video and audio share one screen so the medium is a toggle rather than a
/// separate destination — which is what keeps capture within the two-tap budget
/// in S5 regardless of which one the user wants.
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../../domain/encoding_profile.dart';
import '../widgets/formatting.dart';
import 'capture_flow.dart';
import 'review_screen.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key, required this.initialType});

  final EntryTypeRow initialType;

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen>
    with WidgetsBindingObserver {
  late EntryTypeRow _type = widget.initialType;
  Medium _medium = Medium.video;

  CameraController? _camera;
  final _recorder = AudioRecorder();

  bool _recording = false;
  bool _initialising = true;
  String? _error;

  Stopwatch? _stopwatch;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  double _level = 0;
  StreamSubscription<Amplitude>? _amplitudeSub;

  /// Path the recorder is writing to, so it can be cleaned up on a discard.
  String? _pendingPath;

  int get _maxMs {
    // The type's cap, but never above the global hard ceiling (S6).
    final hardCap = AppScope.of(context).settings.hardCapMs.value;
    return _type.maxDurationMs < hardCap ? _type.maxDurationMs : hardCap;
  }

  bool get _nearLimit => _elapsed.inMilliseconds > _maxMs - 10000;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // If the remembered type is video-only there is nothing to decide; if it is
    // audio-only, start in audio so the first tap does the right thing.
    if (_type.allowedMedium == AllowedMedium.audioOnly) _medium = Medium.audio;
    _prepare();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    _camera?.dispose();
    _recorder.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // S14: survive a mid-record interruption without corrupting anything. A
    // call or a task switch releases the camera, so stop cleanly and keep what
    // was captured rather than losing the file.
    if (state == AppLifecycleState.inactive && _recording) {
      _stop();
    }
  }

  Future<void> _prepare() async {
    setState(() {
      _initialising = true;
      _error = null;
    });
    if (_medium == Medium.video) {
      await _prepareCamera();
    } else {
      await _camera?.dispose();
      _camera = null;
      if (mounted) setState(() => _initialising = false);
    }
  }

  Future<void> _prepareCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _error = 'No camera on this device.';
            _initialising = false;
          });
        }
        return;
      }
      final controller = CameraController(
        cameras.first,
        // Capture near the phone's normal quality; the profile does the
        // shrinking afterwards (S8). Capturing low would throw away detail the
        // compressor could have spent its bitrate on.
        ResolutionPreset.high,
        enableAudio: true,
      );
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      setState(() {
        _camera = controller;
        _initialising = false;
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code == 'CameraAccessDenied'
            ? 'Cairn needs the camera to record video entries. '
                'You can allow it in Settings.'
            : 'Camera unavailable (${e.code}).';
        _initialising = false;
      });
    }
  }

  Future<void> _switchMedium(Medium medium) async {
    if (_recording || medium == _medium) return;
    setState(() => _medium = medium);

    // A video-only type cannot hold an audio entry, so move to one that can
    // rather than silently recording something that will fail validation.
    if (!typeAllowsMedium(_type, medium)) {
      final types = await AppScope.of(context).db.allTypes();
      final fallback = types.firstWhere(
        (t) => typeAllowsMedium(t, medium),
        orElse: () => _type,
      );
      if (mounted) setState(() => _type = fallback);
    }
    await _prepare();
  }

  Future<void> _start() async {
    if (_recording) return;
    final scope = AppScope.of(context);

    try {
      if (_medium == Medium.video) {
        final camera = _camera;
        if (camera == null) return;
        await camera.startVideoRecording();
      } else {
        // S10.4: the OS prompt appears here, at first record, rather than up
        // front on a permissions screen.
        if (!await _recorder.hasPermission()) {
          if (mounted) {
            setState(() => _error =
                'Cairn needs the microphone to record audio entries.');
          }
          return;
        }
        final profile = _profile(scope);
        final path = scope.store.newMediaPath('m4a');
        _pendingPath = path;
        // Audio bitrate is set HERE, not in post: flutter_compress exposes
        // audioBitrateKbps on iOS only, so capture time is the only place the
        // S8 audio ladder can be applied on both platforms.
        await _recorder.start(profile.audioConfig, path: path);
        _amplitudeSub = _recorder
            .onAmplitudeChanged(const Duration(milliseconds: 120))
            .listen((amp) {
          if (!mounted) return;
          // dBFS, roughly -60..0. Mapped to 0..1 for the level meter.
          final normalised = ((amp.current + 50) / 50).clamp(0.0, 1.0);
          setState(() => _level = normalised);
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start recording: $e');
      return;
    }

    _stopwatch = Stopwatch()..start();
    setState(() => _recording = true);

    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_recording) return;
      setState(() => _elapsed = _stopwatch?.elapsed ?? Duration.zero);
      // S6: auto-stop at the limit rather than letting it run over.
      if (_elapsed.inMilliseconds >= _maxMs) _stop();
    });
  }

  EncodingProfile _profile(AppScope scope) {
    // The type decides, unless the user has set an explicit override (S8).
    final override = scope.settings.profileOverride.value;
    return EncodingProfile.of(override ?? _type.encodingProfile);
  }

  Future<void> _stop() async {
    if (!_recording) return;
    _ticker?.cancel();
    _stopwatch?.stop();
    await _amplitudeSub?.cancel();
    _amplitudeSub = null;
    final duration = _stopwatch?.elapsed ?? Duration.zero;
    setState(() => _recording = false);

    String? path;
    try {
      if (_medium == Medium.video) {
        final file = await _camera?.stopVideoRecording();
        path = file?.path;
      } else {
        path = await _recorder.stop() ?? _pendingPath;
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not finish recording: $e');
      return;
    }

    if (path == null || !mounted) return;

    // A recording so short it holds nothing is a mis-tap, not an entry.
    if (duration.inMilliseconds < 400) {
      await File(path).delete().catchError((_) => File(path!));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Too short — hold on a moment longer.')),
        );
        setState(() => _elapsed = Duration.zero);
      }
      return;
    }

    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ReviewScreen(
          sourcePath: path!,
          medium: _medium,
          type: _type,
          durationMs: duration.inMilliseconds,
        ),
      ),
    );

    if (!mounted) return;
    if (saved == true) {
      Navigator.of(context).pop();
    } else {
      // Discarded: back to a clean capture screen for another take.
      setState(() {
        _elapsed = Duration.zero;
        _pendingPath = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = colorForKey(_type.colorKey, theme.brightness);
    final dark = _medium == Medium.video;

    return Scaffold(
      backgroundColor: dark ? Colors.black : theme.colorScheme.surface,
      appBar: AppBar(
        backgroundColor: dark ? Colors.black : theme.colorScheme.surface,
        foregroundColor: dark ? Colors.white : theme.colorScheme.onSurface,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _recording ? null : () => Navigator.of(context).pop(),
        ),
        title: TextButton.icon(
          onPressed: _recording
              ? null
              : () async {
                  final picked = await showTypePicker(
                    context,
                    current: _type,
                    forMedium: _medium,
                  );
                  if (picked != null && mounted) {
                    setState(() => _type = picked);
                  }
                },
          icon: Icon(iconForKey(_type.iconKey), size: 18, color: accent),
          label: Text(
            _type.name,
            style: TextStyle(
              color: dark ? Colors.white : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          Expanded(child: _buildViewfinder(theme, accent)),
          _buildControls(theme, dark),
        ],
      ),
    );
  }

  Widget _buildViewfinder(ThemeData theme, Color accent) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off_outlined,
                  size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: _medium == Medium.video ? Colors.white70 : null,
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton(onPressed: _prepare, child: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_initialising) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_medium == Medium.audio) {
      return _AudioViewfinder(
        level: _level,
        recording: _recording,
        accent: accent,
      );
    }

    final camera = _camera;
    if (camera == null) return const SizedBox.shrink();
    return Center(child: CameraPreview(camera));
  }

  Widget _buildControls(ThemeData theme, bool dark) {
    final onDark = dark ? Colors.white : theme.colorScheme.onSurface;
    final remaining = _maxMs - _elapsed.inMilliseconds;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      color: dark ? Colors.black : theme.colorScheme.surface,
      child: Column(
        children: [
          // Live duration against the limit (S13).
          Text(
            '${formatClock(_elapsed.inMilliseconds)} / ${formatClock(_maxMs)}',
            style: theme.textTheme.titleMedium?.copyWith(
              color: _nearLimit && _recording ? theme.colorScheme.error : onDark,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 18,
            child: _recording && _nearLimit
                // S6 calls for a warning near the limit, not just a silent cut.
                ? Text(
                    'Stopping in ${(remaining / 1000).ceil()}s',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(color: theme.colorScheme.error),
                  )
                : _recording
                    ? const SizedBox.shrink()
                    : SegmentedButton<Medium>(
                        style: const ButtonStyle(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        segments: const [
                          ButtonSegment(
                            value: Medium.video,
                            icon: Icon(Icons.videocam_outlined, size: 16),
                            label: Text('Video'),
                          ),
                          ButtonSegment(
                            value: Medium.audio,
                            icon: Icon(Icons.mic_none, size: 16),
                            label: Text('Audio'),
                          ),
                        ],
                        selected: {_medium},
                        onSelectionChanged: (s) => _switchMedium(s.first),
                      ),
          ),
          const SizedBox(height: 20),
          Semantics(
            button: true,
            label: _recording ? 'Stop recording' : 'Start recording',
            child: GestureDetector(
              onTap: _error != null || _initialising
                  ? null
                  : (_recording ? _stop : _start),
              child: Container(
                width: 74,
                height: 74,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _recording ? Colors.white : const Color(0xFFD64545),
                  border: Border.all(
                    color: dark ? Colors.white24 : theme.colorScheme.outline,
                    width: 3,
                  ),
                ),
                child: Icon(
                  _recording ? Icons.stop_rounded : Icons.fiber_manual_record,
                  color: _recording ? const Color(0xFFD64545) : Colors.white,
                  size: 34,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Audio has no picture, so it gets a level meter — enough to confirm the mic is
/// actually hearing something, which is the one thing that goes wrong silently.
class _AudioViewfinder extends StatelessWidget {
  const _AudioViewfinder({
    required this.level,
    required this.recording,
    required this.accent,
  });

  final double level;
  final bool recording;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            height: 90,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                for (var i = 0; i < 13; i++)
                  _Bar(
                    // A fixed shape scaled by the live level, so the meter
                    // reads as one waveform rather than 13 unrelated bars.
                    height: recording
                        ? 8 + 70 * level * _shape(i)
                        : 8,
                    color: accent,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Text(
            recording ? 'Listening' : 'Ready',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Taller in the middle, tapering out — a plausible waveform envelope.
  double _shape(int i) {
    const weights = [
      0.25, 0.4, 0.55, 0.7, 0.85, 0.95, 1.0, 0.95, 0.85, 0.7, 0.55, 0.4, 0.25,
    ];
    return weights[i];
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.height, required this.color});

  final double height;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      width: 6,
      height: height,
      margin: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}
