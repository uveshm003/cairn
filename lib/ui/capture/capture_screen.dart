/// Capture (requirements.md §13): live duration against the type's limit,
/// auto-stop at the cap, then straight into review.
///
/// Video and audio share one screen so the medium is a toggle rather than a
/// separate destination — which is what keeps capture inside §5's two-tap budget
/// whichever one the user wants.
///
/// The chrome is dark in both themes. A viewfinder with a paper-white surround
/// fights the image, and every camera the user already knows is dark here.
library;

import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../../domain/camera_choice.dart';
import '../../domain/encoding_profile.dart';
import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';
import '../widgets/cairn_mark.dart';
import '../widgets/formatting.dart';
import 'capture_flow.dart';
import 'review_screen.dart';

/// Fixed chrome colours: this screen does not follow the light/dark palette.
const _chrome = Color(0xFF0B0B0C);
const _chromeText = Color(0xFFF4F2EE);
const _chromeMuted = Color(0xFF9A968F);

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

  /// Cached so the flip button can be shown or hidden without re-enumerating,
  /// and so the flip itself does not have to await `availableCameras()` again.
  List<CameraDescription> _cameras = const [];
  CameraLensDirection? _lens;

  /// Created on first audio use, not up front.
  ///
  /// The constructor starts a platform call, so building one for a video
  /// capture that never records audio is both wasteful and a failure point on
  /// platforms where the plugin is absent.
  AudioRecorder? _recorder;

  AudioRecorder get _audio => _recorder ??= AudioRecorder();

  bool _recording = false;
  bool _initialising = true;
  String? _error;

  Stopwatch? _stopwatch;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  double _level = 0;
  StreamSubscription<Amplitude>? _amplitudeSub;

  String? _pendingPath;

  int get _maxMs {
    // The type's cap, never above the global ceiling (§6).
    final hardCap = AppScope.of(context).settings.hardCapMs.value;
    return _type.maxDurationMs < hardCap ? _type.maxDurationMs : hardCap;
  }

  double get _progress =>
      (_elapsed.inMilliseconds / _maxMs).clamp(0.0, 1.0).toDouble();

  bool get _nearLimit => _elapsed.inMilliseconds > _maxMs - 10000;

  /// The overlay style to put back on the way out.
  ///
  /// Captured from the theme while the context is still valid, because dispose()
  /// must not read inherited widgets — and because a hardcoded value is wrong
  /// half the time. The library screen uses a custom header rather than an
  /// AppBar, so Material's automatic overlay handling does not restore this.
  SystemUiOverlayStyle? _restoreOverlayStyle;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Light *glyphs*, because this screen's chrome is dark in either theme.
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle.light);
    if (_type.allowedMedium == AllowedMedium.audioOnly) _medium = Medium.audio;
    // NB: _prepare() is deliberately *not* called here. It reads the remembered
    // lens from AppScope, and touching an inherited widget before initState
    // returns throws.
  }

  bool _prepared = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Dark canvas wants light glyphs, and vice versa.
    _restoreOverlayStyle = context.palette.isDark
        ? SystemUiOverlayStyle.light
        : SystemUiOverlayStyle.dark;

    // First legal moment to read inherited widgets, so this is where capture
    // actually starts up.
    if (!_prepared) {
      _prepared = true;
      _prepare();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    SystemChrome.setSystemUIOverlayStyle(
      _restoreOverlayStyle ?? SystemUiOverlayStyle.dark,
    );
    _ticker?.cancel();
    _amplitudeSub?.cancel();
    _camera?.dispose();
    _recorder?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // §14: survive a mid-record interruption without corrupting anything. A call
    // or task switch releases the camera, so stop cleanly and keep what was
    // captured rather than losing the file.
    if (state == AppLifecycleState.inactive && _recording) _stop();
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
    // Read the remembered lens before awaiting: reaching for an inherited
    // widget after an async gap is exactly how a disposed context gets used.
    final remembered = AppScope.of(context).settings.preferredLens.value;
    try {
      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _error = 'No camera on this device.';
            _initialising = false;
          });
        }
        return;
      }

      // Opens with the remembered lens: a diary user should not have to flip to
      // the front camera on every capture.
      final wanted = _lens ?? remembered;
      final description = pickCamera(_cameras, preferred: wanted);
      if (description == null) {
        if (mounted) {
          setState(() {
            _error = 'No usable camera on this device.';
            _initialising = false;
          });
        }
        return;
      }
      _lens = description.lensDirection;

      final controller = CameraController(
        description,
        // 1080p. Note that ResolutionPreset.high is ~720p, not 1080p — with
        // that, the Balanced and High profiles' 1080p caps never engaged and
        // the pipeline was compressing 720p into 720p. §8 says to capture near
        // the phone's normal quality and let the profile do the shrinking, so
        // the source has to be at least as large as the largest rung.
        ResolutionPreset.veryHigh,
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
            ? 'Cairn needs the camera to record video entries. You can allow '
                'it in Settings.'
            : 'Camera unavailable (${e.code}).';
        _initialising = false;
      });
    } catch (e) {
      // Anything else the platform throws -- a missing plugin, a vendor
      // surprise. An unreachable camera must land the user on the retry state,
      // never on a spinner that never resolves.
      if (!mounted) return;
      setState(() {
        _error = 'The camera could not be opened on this device.';
        _initialising = false;
      });
    }
  }

  /// Flips to the next lens the device actually has.
  ///
  /// Uses `setDescription` rather than rebuilding the controller: it disposes
  /// and re-initialises internally, which is fewer moving parts than managing
  /// two controllers.
  Future<void> _flipCamera() async {
    final controller = _camera;
    final current = _lens;
    if (controller == null || current == null) return;

    final next = nextLens(_cameras, current: current);
    if (next == null) return;
    final description = pickCamera(_cameras, preferred: next);
    if (description == null) return;

    setState(() => _lens = description.lensDirection);
    try {
      await controller.setDescription(description);
      // Remembered only on success, so a lens that fails to open does not
      // become the setting the app keeps retrying.
      if (mounted) {
        await AppScope.of(context).settings.setPreferredLens(
              description.lensDirection,
            );
      }
    } on CameraException catch (e) {
      if (!mounted) return;
      // Deliberately not `_error`: that replaces the viewfinder with the retry
      // panel, and the original camera is still open and working. `_error` only
      // clears on a full re-prepare, so one transient flip failure would strand
      // the screen. A snackbar says what happened and leaves capture usable.
      setState(() => _lens = current);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not switch camera (${e.code}).')),
      );
    }
  }

  Future<void> _switchMedium(Medium medium) async {
    if (_recording || medium == _medium) return;
    setState(() => _medium = medium);

    // A video-only type cannot hold an audio entry, so move to one that can
    // rather than recording something that will fail validation.
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
        // §10.4: the OS prompt appears here, at first record, rather than on an
        // up-front permissions screen.
        if (!await _audio.hasPermission()) {
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
        // audioBitrateKbps on iOS only, so capture time is the only place §8's
        // audio ladder can be applied on both platforms.
        await _audio.start(profile.audioConfig, path: path);
        _amplitudeSub = _audio
            .onAmplitudeChanged(const Duration(milliseconds: 90))
            .listen((amp) {
          if (!mounted) return;
          // dBFS, roughly -60..0, mapped to 0..1 for the meter.
          setState(() => _level = ((amp.current + 50) / 50).clamp(0.0, 1.0));
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start recording: $e');
      return;
    }

    HapticFeedback.mediumImpact();
    _stopwatch = Stopwatch()..start();
    setState(() => _recording = true);

    _ticker = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted || !_recording) return;
      setState(() => _elapsed = _stopwatch?.elapsed ?? Duration.zero);
      // §6: auto-stop at the limit rather than letting it run over.
      if (_elapsed.inMilliseconds >= _maxMs) _stop();
    });
  }

  EncodingProfile _profile(AppScope scope) {
    // The type decides, unless the user set an explicit override (§8).
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
    HapticFeedback.lightImpact();

    String? path;
    try {
      if (_medium == Medium.video) {
        final file = await _camera?.stopVideoRecording();
        path = file?.path;
      } else {
        path = await _audio.stop() ?? _pendingPath;
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not finish recording: $e');
      return;
    }

    if (path == null || !mounted) return;

    // A recording too short to hold anything is a mis-tap, not an entry.
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
      setState(() {
        _elapsed = Duration.zero;
        _pendingPath = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _chrome,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildViewfinder(),
          // Gradient scrims top and bottom so the chrome stays legible over any
          // frame, without a solid bar cropping the picture.
          const _Scrim(alignment: Alignment.topCenter),
          const _Scrim(alignment: Alignment.bottomCenter),
          SafeArea(
            child: Column(
              children: [
                _buildTopBar(),
                const Spacer(),
                _buildControls(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewfinder() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(Space.xxl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.videocam_off_outlined,
                  size: 34, color: _chromeMuted),
              const SizedBox(height: Space.lg),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: CairnType.body,
                  color: _chromeText,
                  fontSize: 14.5,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: Space.xl),
              OutlinedButton(
                onPressed: _prepare,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _chromeText,
                  side: const BorderSide(color: Color(0xFF3A3A3C)),
                ),
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }

    if (_initialising) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: _chromeMuted),
        ),
      );
    }

    if (_medium == Medium.audio) {
      return _AudioStage(level: _level, recording: _recording);
    }

    final camera = _camera;
    if (camera == null) return const SizedBox.shrink();
    // Cover rather than contain: a letterboxed preview inside a dark screen
    // looks like a bug, and the crop matches what a camera app would show.
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: camera.value.previewSize?.height ?? 1080,
        height: camera.value.previewSize?.width ?? 1920,
        child: CameraPreview(camera),
      ),
    );
  }

  Widget _buildTopBar() {
    final accent = context.palette.typeColor(_type.colorKey);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.sm, Space.xs, Space.sm, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: _chromeText),
            tooltip: 'Cancel',
            onPressed: _recording ? null : () => Navigator.of(context).pop(),
          ),
          const Spacer(),
          // Type is the one thing worth changing mid-flow, so it sits front and
          // centre as a tappable pill rather than buried in a menu.
          _TypePill(
            label: _type.name,
            accent: accent,
            enabled: !_recording,
            onTap: () async {
              final picked = await showTypePicker(
                context,
                current: _type,
                forMedium: _medium,
              );
              if (picked != null && mounted) setState(() => _type = picked);
            },
          ),
          const Spacer(),
          // Occupies the close button's mirror position, so the type pill stays
          // centred whether or not the device can flip.
          SizedBox(
            width: 48,
            child: _medium == Medium.video && canFlipCamera(_cameras)
                ? IconButton(
                    icon: Icon(
                      Icons.cameraswitch_outlined,
                      color: _recording ? _chromeMuted : _chromeText,
                    ),
                    tooltip: 'Switch to '
                        '${(nextLens(_cameras, current: _lens ?? CameraLensDirection.back) ?? CameraLensDirection.front).label}',
                    // Disabled mid-take, like every other control here (close,
                    // type pill, medium toggle).
                    //
                    // Not for fear of losing the recording: camera 0.12's
                    // `startVideoRecording` defaults `enablePersistentRecording`
                    // to true, and a persistent recording explicitly ignores
                    // `setDescription` calls made while it runs. The reason is
                    // simpler — a take that changes lens halfway is a feature
                    // nobody asked for, and the mid-record path is untested.
                    onPressed: _recording ? null : _flipCamera,
                  )
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    final remaining = _maxMs - _elapsed.inMilliseconds;
    final canRecord = _error == null && !_initialising;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.gutter, 0, Space.gutter, Space.xl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Medium toggle, hidden while recording — switching mid-take is not a
          // thing, and removing it keeps the running screen quiet.
          _FadeSlot(
            visible: !_recording,
            child: _MediumToggle(
              medium: _medium,
              onChanged: _switchMedium,
            ),
          ),
          const SizedBox(height: Space.lg),
          _TimeReadout(
            elapsedMs: _elapsed.inMilliseconds,
            maxMs: _maxMs,
            progress: _progress,
            recording: _recording,
            nearLimit: _nearLimit,
            remainingMs: remaining,
          ),
          const SizedBox(height: Space.lg),
          RecordButton(
            recording: _recording,
            enabled: canRecord,
            onTap: _recording ? _stop : _start,
          ),
        ],
      ),
    );
  }
}

/// Fades a control in and out without shifting layout, so the record button
/// never moves as the toggle disappears. Named to avoid shadowing Flutter's
/// AnimatedSwitcher, which does something different.
class _FadeSlot extends StatelessWidget {
  const _FadeSlot({required this.visible, required this.child});

  final bool visible;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: Motion.fast,
      child: IgnorePointer(ignoring: !visible, child: child),
    );
  }
}

class _Scrim extends StatelessWidget {
  const _Scrim({required this.alignment});

  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final top = alignment == Alignment.topCenter;
    return Align(
      alignment: alignment,
      child: IgnorePointer(
        child: Container(
          height: top ? 140 : 260,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: top ? Alignment.topCenter : Alignment.bottomCenter,
              end: top ? Alignment.bottomCenter : Alignment.topCenter,
              colors: [
                Colors.black.withValues(alpha: top ? 0.55 : 0.75),
                Colors.black.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TypePill extends StatelessWidget {
  const _TypePill({
    required this.label,
    required this.accent,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final Color accent;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: Material(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.pill),
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Space.md + 2,
              vertical: Space.sm,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                ),
                const SizedBox(width: Space.sm),
                Text(
                  label,
                  style: const TextStyle(
                    fontFamily: CairnType.body,
                    color: _chromeText,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: Space.xs),
                const Icon(Icons.expand_more, size: 16, color: _chromeMuted),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MediumToggle extends StatelessWidget {
  const _MediumToggle({required this.medium, required this.onChanged});

  final Medium medium;
  final ValueChanged<Medium> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final option in Medium.values)
            _ToggleSegment(
              label: option == Medium.audio ? 'Audio' : 'Video',
              icon: iconForMedium(option),
              selected: option == medium,
              onTap: () => onChanged(option),
            ),
        ],
      ),
    );
  }
}

class _ToggleSegment extends StatelessWidget {
  const _ToggleSegment({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: Motion.fast,
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md + 2,
          vertical: Space.sm - 1,
        ),
        decoration: BoxDecoration(
          color: selected ? _chromeText : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: selected ? _chrome : _chromeMuted),
            const SizedBox(width: Space.xs + 2),
            Text(
              label,
              style: TextStyle(
                fontFamily: CairnType.body,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected ? _chrome : _chromeMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Elapsed time, the limit, and a hairline that fills toward it.
class _TimeReadout extends StatelessWidget {
  const _TimeReadout({
    required this.elapsedMs,
    required this.maxMs,
    required this.progress,
    required this.recording,
    required this.nearLimit,
    required this.remainingMs,
  });

  final int elapsedMs;
  final int maxMs;
  final double progress;
  final bool recording;
  final bool nearLimit;
  final int remainingMs;

  @override
  Widget build(BuildContext context) {
    final warn = recording && nearLimit;
    final record = context.palette.record;

    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (recording) ...[
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: record, shape: BoxShape.circle),
              ),
              const SizedBox(width: Space.sm),
            ],
            Text(
              formatClock(elapsedMs),
              style: TextStyle(
                fontFamily: CairnType.body,
                fontSize: 32,
                height: 1.1,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.5,
                color: warn ? record : _chromeText,
                // Tabular, so the readout does not jitter as digits change.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            Text(
              ' / ${formatClock(maxMs)}',
              style: const TextStyle(
                fontFamily: CairnType.body,
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: _chromeMuted,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: Space.md),
        // The limit made visible, so auto-stop is never a surprise (§6).
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.pill),
          child: SizedBox(
            width: 190,
            height: 3,
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white.withValues(alpha: 0.18),
              valueColor: AlwaysStoppedAnimation(warn ? record : _chromeText),
            ),
          ),
        ),
        // §6 asks for a warning near the limit, not just a silent cut.
        //
        // Always laid out and merely faded, so the record button never shifts
        // when it appears — but *not* inside a fixed-height box, which would
        // clip the warning at a large text scale and hide it from exactly the
        // users who most need it.
        Padding(
          padding: const EdgeInsets.only(top: Space.sm),
          child: AnimatedOpacity(
            opacity: warn ? 1 : 0,
            duration: Motion.fast,
            child: Text(
              // Always the real string: it is invisible at zero opacity, and a
              // single line is the same height whatever it says, so the button
              // below never moves.
              'Stopping in ${(remainingMs / 1000).clamp(0, 9999).ceil()}s',
              style: TextStyle(
                fontFamily: CairnType.body,
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: record,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Audio has no picture, so it gets a level meter — enough to confirm the mic is
/// actually hearing something, which is the one thing that fails silently.
class _AudioStage extends StatelessWidget {
  const _AudioStage({required this.level, required this.recording});

  final double level;
  final bool recording;

  /// A fixed envelope, scaled by the live level, so the meter reads as one
  /// waveform rather than 15 unrelated bars.
  static const _envelope = [
    0.22, 0.34, 0.46, 0.58, 0.72, 0.86, 0.95, 1.0,
    0.95, 0.86, 0.72, 0.58, 0.46, 0.34, 0.22,
  ];

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    return ColoredBox(
      color: _chrome,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              height: 120,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final weight in _envelope)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 110),
                      curve: Curves.easeOut,
                      width: 5,
                      height: recording ? 6 + 108 * level * weight : 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: recording
                            ? accent
                            : _chromeMuted.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Space.xxl),
            Text(
              recording ? 'Listening' : 'Ready when you are',
              style: const TextStyle(
                fontFamily: CairnType.body,
                fontSize: 14,
                color: _chromeMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
