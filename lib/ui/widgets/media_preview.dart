/// Playback for a single entry, in both media (requirements.md S4: "playback
/// (audio + video) with basic scrubbing").
///
/// Takes an **absolute** path: callers resolve relative paths through
/// `MediaStore` first. Keeping the resolution out of here means there is exactly
/// one place in the app that knows how a stored path becomes a real one.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:video_player/video_player.dart';

import '../../data/database.dart';
import 'formatting.dart';

class MediaPreview extends StatelessWidget {
  const MediaPreview({
    super.key,
    required this.path,
    required this.medium,
    required this.durationMs,
    this.autoPlay = false,
  });

  final String path;
  final Medium medium;
  final int durationMs;
  final bool autoPlay;

  @override
  Widget build(BuildContext context) {
    return medium == Medium.video
        ? _VideoPreview(path: path, autoPlay: autoPlay)
        : _AudioPreview(path: path, fallbackDurationMs: durationMs);
  }
}

class _VideoPreview extends StatefulWidget {
  const _VideoPreview({required this.path, required this.autoPlay});

  final String path;
  final bool autoPlay;

  @override
  State<_VideoPreview> createState() => _VideoPreviewState();
}

class _VideoPreviewState extends State<_VideoPreview> {
  VideoPlayerController? _controller;
  String? _error;

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
      setState(() => _controller = controller);
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      // S17 flags HEVC playback on old devices as a risk. A device that can
      // *encode* HEVC but not decode it fails exactly here, so the message says
      // so rather than showing a silent black rectangle.
      setState(() => _error = 'This video would not open.\n'
          'If it was encoded as HEVC, this device may not be able to play it '
          'back. $e');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = _controller;

    if (_error != null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer,
            borderRadius: BorderRadius.circular(16),
          ),
          padding: const EdgeInsets.all(20),
          child: Center(
            child: Text(
              _error!,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
        ),
      );
    }

    if (controller == null) {
      return AspectRatio(
        aspectRatio: 16 / 9,
        child: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Center(child: CircularProgressIndicator()),
        ),
      );
    }

    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
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
        // allowScrubbing is the "basic scrubbing" in S4.
        VideoProgressIndicator(controller, allowScrubbing: true),
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
      ],
    );
  }
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview({required this.path, required this.fallbackDurationMs});

  final String path;

  /// Used until the player reports the real duration, so the UI never shows
  /// 0:00 for a file that plainly has content.
  final int fallbackDurationMs;

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> {
  final _player = AudioPlayer();
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      await _player.setFilePath(widget.path);
    } catch (e) {
      if (mounted) setState(() => _error = 'This audio would not open. $e');
    }
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_error != null) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(_error!,
            style: TextStyle(color: theme.colorScheme.onErrorContainer)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
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
                        final position =
                            positionSnapshot.data ?? Duration.zero;
                        final total = _player.duration ??
                            Duration(milliseconds: widget.fallbackDurationMs);
                        final max = total.inMilliseconds.toDouble();
                        return Column(
                          children: [
                            Slider(
                              // Clamped: a position past the reported duration
                              // (which happens on some encoders) would other-
                              // wise throw an assertion inside Slider.
                              value: position.inMilliseconds
                                  .clamp(0, total.inMilliseconds)
                                  .toDouble(),
                              max: max <= 0 ? 1 : max,
                              onChanged: (value) => _player
                                  .seek(Duration(milliseconds: value.round())),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 8),
                              child: Row(
                                children: [
                                  Text(
                                      formatClock(position.inMilliseconds),
                                      style: theme.textTheme.labelSmall),
                                  const Spacer(),
                                  Text(formatClock(total.inMilliseconds),
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
            ],
          );
        },
      ),
    );
  }
}
