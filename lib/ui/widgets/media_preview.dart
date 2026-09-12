/// Playback for a single entry, in both media (requirements.md S4: "playback
/// (audio + video) with basic scrubbing").
///
/// Takes an **absolute** path: callers resolve relative paths through
/// `MediaStore` first. Keeping the resolution out of here means there is exactly
/// one place in the app that knows how a stored path becomes a real one.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../data/database.dart';
import '../theme/tokens.dart';
import 'formatting.dart';
import 'playback_controls.dart';
import 'waveform.dart';

class MediaPreview extends StatelessWidget {
  const MediaPreview({
    super.key,
    required this.path,
    required this.medium,
    required this.durationMs,
    this.autoPlay = false,
    this.markerOffsetsMs = const [],
    this.amplitudeEnvelope,
    this.transport = false,
  });

  final String path;
  final Medium medium;
  final int durationMs;
  final bool autoPlay;

  /// Drawn as ticks over the timeline, and offered as chips to jump to.
  final List<int> markerOffsetsMs;

  /// Enables waveform scrubbing when present. Null -- video, or audio recorded
  /// before the envelope existed -- falls back to the plain slider.
  final Uint8List? amplitudeEnvelope;

  /// Whether to show speed, A-B loop and skip-silence.
  ///
  /// Off on the review screen: that screen is for deciding whether to keep the
  /// take, and a transport row there invites fiddling with playback instead.
  final bool transport;

  @override
  Widget build(BuildContext context) {
    return medium == Medium.video
        ? _VideoPreview(
            path: path,
            autoPlay: autoPlay,
            markerOffsetsMs: markerOffsetsMs,
            transport: transport,
          )
        : _AudioPreview(
            path: path,
            fallbackDurationMs: durationMs,
            markerOffsetsMs: markerOffsetsMs,
            envelope: amplitudeEnvelope,
            transport: transport,
          );
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({
    required this.path,
    required this.autoPlay,
    required this.markerOffsetsMs,
    required this.transport,
  });

  final String path;
  final bool autoPlay;
  final List<int> markerOffsetsMs;
  final bool transport;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  String? _error;
  String? _errorDetail;

  double _speed = 1.0;
  LoopRegion? _loop;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller = VideoPlayerController.file(File(widget.path));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      if (widget.autoPlay) await controller.play();
      controller.addListener(_enforceLoop);
      setState(() => _controller = controller);
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      // §17 flags HEVC playback on old devices as a risk. A device that can
      // *encode* HEVC but not decode it fails exactly here, so say so rather
      // than showing a silent black rectangle. The raw platform error is kept
      // but demoted -- it is the only diagnostic this offline app will ever
      // produce, and it should not be the first thing the user reads.
      setState(() {
        _error = 'This video would not open. If it was encoded as HEVC, this '
            'device may not be able to play it back.';
        _errorDetail = '$e';
      });
    }
  }

  @override
  void dispose() {
    _controller?.removeListener(_enforceLoop);
    _controller?.dispose();
    super.dispose();
  }

  /// `video_player` has no clip or loop-region concept, so the loop is enforced
  /// by watching the position and seeking back.
  ///
  /// Fires on every position tick, so it must stay cheap and must not seek when
  /// it does not need to -- a redundant seek stutters the picture.
  void _enforceLoop() {
    final controller = _controller;
    final region = _loop;
    if (controller == null || region == null || !region.isComplete) return;
    if (!controller.value.isPlaying) return;

    final position = controller.value.position.inMilliseconds;
    if (position >= region.endMs!) {
      controller.seekTo(Duration(milliseconds: region.startMs));
    }
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await _controller?.setPlaybackSpeed(speed);
  }

  /// Seeks to an absolute position, dropping the loop when the target is
  /// outside it.
  ///
  /// Only the `clearLoop` half of [resolveSeek] applies here: `video_player`
  /// has no clip, so its timeline is always absolute and `seekMs` must not be
  /// rebased. Without this, tapping a marker past the loop's end let
  /// `_enforceLoop` yank the playhead straight back into the loop -- exactly
  /// the clamping [resolveSeek] exists to refuse.
  void _seek(int ms) {
    if (resolveSeek(targetMs: ms, loop: _loop).clearLoop) {
      setState(() => _loop = null);
    }
    _controller?.seekTo(Duration(milliseconds: ms));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    if (_error != null) {
      // Hugs its content rather than reserving a 16:9 box for a message.
      return Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        padding: const EdgeInsets.all(Space.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.play_disabled_outlined,
                    size: 18, color: theme.colorScheme.onErrorContainer),
                const SizedBox(width: Space.sm),
                Expanded(
                  child: Text(
                    _error!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ],
            ),
            if (_errorDetail != null) ...[
              const SizedBox(height: Space.sm),
              Text(
                _errorDetail!,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer
                      .withValues(alpha: 0.65),
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (controller == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(Radii.lg),
          ),
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(Radii.lg),
          child: AspectRatio(
            aspectRatio: controller.value.aspectRatio,
            child: Stack(
              alignment: Alignment.center,
              children: [
                VideoPlayer(controller),
                // Tap the picture to toggle -- the usual gesture, and it keeps
                // the controls out of the way of the content.
                GestureDetector(
                  onTap: () => setState(() {
                    controller.value.isPlaying
                        ? controller.pause()
                        : controller.play();
                  }),
                  child: AnimatedOpacity(
                    opacity: controller.value.isPlaying ? 0 : 1,
                    duration: const Duration(milliseconds: 180),
                    child: Container(
                      color: Colors.black26,
                      child: const Center(
                        child: Icon(Icons.play_arrow,
                            size: 56, color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        // allowScrubbing is the "basic scrubbing" in S4. The marker ticks are
        // painted over it rather than replacing it, so the familiar scrub
        // gesture is untouched.
        Stack(
          children: [
            VideoProgressIndicator(controller, allowScrubbing: true),
            if (widget.markerOffsetsMs.isNotEmpty)
              Positioned.fill(
                child: IgnorePointer(
                  child: ValueListenableBuilder(
                    valueListenable: controller,
                    builder: (context, value, _) => MarkerTicks(
                      offsetsMs: widget.markerOffsetsMs,
                      durationMs: value.duration.inMilliseconds,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
          ],
        ),
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (context, value, _) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              children: [
                Text(formatClock(value.position.inMilliseconds),
                    style: theme.textTheme.labelSmall),
                const Spacer(),
                Text(formatClock(value.duration.inMilliseconds),
                    style: theme.textTheme.labelSmall),
              ],
            ),
          ),
        ),
        if (widget.markerOffsetsMs.isNotEmpty) ...[
          const SizedBox(height: Space.sm),
          MarkerJumpRow(offsetsMs: widget.markerOffsetsMs, onJump: _seek),
        ],
        if (widget.transport) ...[
          const SizedBox(height: Space.md),
          ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, value, _) => PlaybackControls(
              speed: _speed,
              onSpeedChanged: _setSpeed,
              loop: _loop,
              onSetLoopStart: () => setState(() => _loop =
                  LoopRegion(startMs: value.position.inMilliseconds)),
              onSetLoopEnd: () {
                final closed = closeLoop(
                  startMs: _loop!.startMs,
                  atMs: value.position.inMilliseconds,
                );
                if (closed != null) setState(() => _loop = closed);
              },
              onClearLoop: () => setState(() => _loop = null),
              // Skip-silence is audio-only in just_audio and has no
              // video_player equivalent, so it is absent here by nature rather
              // than by platform.
            ),
          ),
        ],
      ],
    );
  }
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({
    required this.path,
    required this.fallbackDurationMs,
    required this.markerOffsetsMs,
    required this.envelope,
    required this.transport,
  });

  final String path;

  /// Used until the player reports the real duration, so the UI never shows
  /// 0:00 for a file that plainly has content.
  final int fallbackDurationMs;

  final List<int> markerOffsetsMs;
  final Uint8List? envelope;
  final bool transport;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

/// Whether this platform can skip silence.
///
/// It is an ExoPlayer feature, so `just_audio` implements it on Android only --
/// its own doc comment says "(Currently Android only)". A dead switch on iOS
/// would be worse than no switch, so the control is hidden rather than
/// disabled.
final _skipSilenceSupported = Platform.isAndroid;

class _AudioPreviewState extends State<_AudioPreview> {
  final _player = AudioPlayer();
  String? _error;

  /// The whole entry's duration, tracked separately from `_player.duration`.
  ///
  /// While a clip is active `just_audio` reports the *clip's* duration -- on
  /// Android that is `ExoPlayer.getDuration()` over a `ClippingMediaSource`,
  /// whose window is `end - start`. The same window is why positions come back
  /// clip-relative. So the player cannot be asked how long the entry is once a
  /// loop is set, and everything drawn here is drawn against the entry.
  int? _fileDurationMs;

  StreamSubscription<Duration?>? _durationSub;

  double _speed = 1.0;
  LoopRegion? _loop;

  /// Whether a clip is actually installed on the player.
  ///
  /// Distinct from `_loop != null`: a half-set loop (A placed, B not yet) is UI
  /// state with no clip behind it, and `setClip()` is not a no-op that can be
  /// called to find out -- see [_applyLoop].
  bool _clipApplied = false;

  bool _skipSilence = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    // Subscribed before the source is set, so the first duration the player
    // reports is not missed.
    _durationSub = _player.durationStream.listen((duration) {
      // Ignored while a clip is active, when this reports the clip's length
      // rather than the entry's.
      if (_clipApplied || duration == null || !mounted) return;
      setState(() => _fileDurationMs = duration.inMilliseconds);
    });
    try {
      await _player.setFilePath(widget.path);
    } catch (e) {
      if (mounted) setState(() => _error = 'This audio would not open. $e');
    }
  }

  @override
  void dispose() {
    _durationSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _setSpeed(double speed) async {
    setState(() => _speed = speed);
    await _player.setSpeed(speed);
  }

  Future<void> _setSkipSilence(bool enabled) async {
    setState(() => _skipSilence = enabled);
    try {
      await _player.setSkipSilenceEnabled(enabled);
    } catch (e) {
      // The platform can refuse. Roll the switch back rather than leaving it
      // showing a state the player is not in.
      if (mounted) setState(() => _skipSilence = !enabled);
    }
  }

  /// Applies the loop by clipping the source, which is what `just_audio` offers
  /// natively -- no position-watching, and the loop is gapless.
  ///
  /// `setClip` reloads the source (`_load` with a null `initialPosition`), so
  /// the playhead and the playing state have to be restored by hand; without
  /// that, closing a loop silently stops playback.
  ///
  /// [resumeAtMs] is an absolute position to restore after clearing a clip.
  /// Clearing reloads the whole file and lands at 0:00, so a caller that is not
  /// about to seek somewhere itself has to say where the playhead was.
  Future<void> _applyLoop(LoopRegion? region, {int? resumeAtMs}) async {
    final complete = region != null && region.isComplete;
    setState(() => _loop = region);

    // The rule lives in [loopNeedsPlayerCall] so it can be tested: placing A
    // with no clip installed must not reach the player at all.
    if (!loopNeedsPlayerCall(region: region, clipApplied: _clipApplied)) return;

    final wasPlaying = _player.playing;
    try {
      if (complete) {
        // Flagged *before* the await, and cleared *after* the one below: both
        // directions err towards ignoring duration updates. `setClip` reloads
        // the source, and the duration event for the clipped source can land
        // while the call is still in flight -- so flagging afterwards left a
        // window where the clip's length was accepted as the entry's, which is
        // the exact confusion this flag exists to prevent.
        _clipApplied = true;
        await _player.setClip(
          start: Duration(milliseconds: region.startMs),
          end: Duration(milliseconds: region.endMs!),
        );
        await _player.setLoopMode(LoopMode.one);
      } else {
        await _player.setLoopMode(LoopMode.off);
        await _player.setClip();
        _clipApplied = false;
        if (resumeAtMs != null) {
          await _player.seek(Duration(milliseconds: resumeAtMs));
        }
      }
      if (wasPlaying) await _player.play();
    } catch (e) {
      // Leave the loop off rather than showing a region the player is not in,
      // and best-effort undo whatever half-landed -- a clip installed while the
      // UI shows no loop would be invisible and unreachable.
      if (mounted) setState(() => _loop = null);
      try {
        await _player.setLoopMode(LoopMode.off);
        await _player.setClip();
      } catch (_) {
        // Nothing further to try; the player is unwell either way.
      }
      _clipApplied = false;
    }
  }

  /// Seeks to an absolute position, correcting for an active clip.
  ///
  /// Callers -- the waveform and the marker chips -- deal in absolute time,
  /// which is not what the player deals in while a loop is set. See
  /// [resolveSeek].
  Future<void> _seek(int ms) async {
    final action = resolveSeek(targetMs: ms, loop: _loop);
    if (action.clearLoop) {
      // The target goes *into* the clear rather than after it. Dropping the clip
      // reloads the file at 0:00 and resumes playback, so seeking afterwards
      // would blip a moment of the entry's opening on the way past.
      await _applyLoop(null, resumeAtMs: action.seekMs);
      return;
    }
    await _player.seek(Duration(milliseconds: action.seekMs));
  }

  /// Position reported relative to the whole file.
  ///
  /// While a clip is active `just_audio` reports positions from the clip's
  /// start, so the raw value would put the playhead at 0:00 for a loop that
  /// begins at 4:12 -- and every marker tick would then sit in the wrong place.
  int _absolutePositionMs(Duration raw) {
    final region = _loop;
    if (region != null && region.isComplete) {
      return raw.inMilliseconds + region.startMs;
    }
    return raw.inMilliseconds;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: Text(_error!,
            style: TextStyle(color: theme.colorScheme.onErrorContainer)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(Radii.lg),
      ),
      child: StreamBuilder<PlayerState>(
        stream: _player.playerStateStream,
        builder: (context, stateSnapshot) {
          final playing = stateSnapshot.data?.playing ?? false;
          final completed =
              stateSnapshot.data?.processingState == ProcessingState.completed;

          return Column(
            children: [
              Row(
                children: [
                  IconButton.filled(
                    iconSize: 30,
                    onPressed: () {
                      if (completed) {
                        // Restart rather than sitting at the end doing nothing.
                        _player.seek(Duration.zero);
                        _player.play();
                      } else {
                        playing ? _player.pause() : _player.play();
                      }
                    },
                    icon: Icon(
                      completed
                          ? Icons.replay
                          : (playing ? Icons.pause : Icons.play_arrow),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: StreamBuilder<Duration>(
                      stream: _player.positionStream,
                      builder: (context, positionSnapshot) {
                        final positionMs = _absolutePositionMs(
                          positionSnapshot.data ?? Duration.zero,
                        );
                        // Never `_player.duration`: see [_fileDurationMs].
                        // Reading it here rescaled the waveform to the loop,
                        // stacked every marker tick on the right edge, and made
                        // a scrub inside a loop resolve to a target outside it
                        // -- which silently dropped the loop.
                        final totalMs =
                            _fileDurationMs ?? widget.fallbackDurationMs;
                        final envelope = widget.envelope;

                        return Column(
                          children: [
                            if (envelope != null && envelope.isNotEmpty)
                              // A real waveform, painted from the envelope
                              // captured while recording.
                              WaveformScrubber(
                                envelope: envelope,
                                positionMs: positionMs,
                                durationMs: totalMs,
                                markerOffsetsMs: widget.markerOffsetsMs,
                                onSeek: _seek,
                                height: 44,
                              )
                            else
                              Stack(
                                children: [
                                  Slider(
                                    // Clamped: a position past the reported
                                    // duration (which happens on some
                                    // encoders) would otherwise throw an
                                    // assertion inside Slider.
                                    value:
                                        positionMs.clamp(0, totalMs).toDouble(),
                                    max: totalMs <= 0
                                        ? 1
                                        : totalMs.toDouble(),
                                    onChanged: (value) =>
                                        _seek(value.round()),
                                  ),
                                  if (widget.markerOffsetsMs.isNotEmpty)
                                    Positioned.fill(
                                      // Inset to the track: a Slider reserves
                                      // padding for its thumb, and ticks drawn
                                      // over the full box would sit off by
                                      // half a thumb at each end.
                                      child: IgnorePointer(
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 14,
                                          ),
                                          child: MarkerTicks(
                                            offsetsMs: widget.markerOffsetsMs,
                                            durationMs: totalMs,
                                            color:
                                                theme.colorScheme.primary,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  Text(formatClock(positionMs),
                                      style: theme.textTheme.labelSmall),
                                  const Spacer(),
                                  Text(formatClock(totalMs),
                                      style: theme.textTheme.labelSmall),
                                ],
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
              if (widget.markerOffsetsMs.isNotEmpty) ...[
                const SizedBox(height: Space.sm),
                MarkerJumpRow(
                  offsetsMs: widget.markerOffsetsMs,
                  onJump: _seek,
                ),
              ],
              if (widget.transport) ...[
                const SizedBox(height: Space.md),
                StreamBuilder<Duration>(
                  stream: _player.positionStream,
                  builder: (context, snapshot) {
                    final atMs = _absolutePositionMs(
                      snapshot.data ?? Duration.zero,
                    );
                    return PlaybackControls(
                      speed: _speed,
                      onSpeedChanged: _setSpeed,
                      loop: _loop,
                      onSetLoopStart: () =>
                          _applyLoop(LoopRegion(startMs: atMs)),
                      onSetLoopEnd: () {
                        final closed =
                            closeLoop(startMs: _loop!.startMs, atMs: atMs);
                        if (closed != null) _applyLoop(closed);
                      },
                      // Told where the playhead is: clearing the clip reloads
                      // the file at 0:00, and nothing seeks afterwards here.
                      onClearLoop: () => _applyLoop(null, resumeAtMs: atMs),
                      skipSilence:
                          _skipSilenceSupported ? _skipSilence : null,
                      onSkipSilenceChanged: _setSkipSilence,
                    );
                  },
                ),
              ],
            ],
          );
        },
      ),
    );
  }
}
