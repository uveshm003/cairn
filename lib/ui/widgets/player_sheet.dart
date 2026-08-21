/// Playback for a compressed output.
///
/// This exists because the one thing the measurement table cannot report is
/// whether the ladder *looks* right. 1.75 Mbps at 720p is a number; whether a
/// talking-head note at that bitrate is acceptable is a judgement, and it needs
/// eyes on the actual file.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

Future<void> showPlayerSheet(
  BuildContext context, {
  required String absolutePath,
  required String title,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PlayerSheet(absolutePath: absolutePath, title: title),
  );
}

class _PlayerSheet extends StatefulWidget {
  const _PlayerSheet({required this.absolutePath, required this.title});

  final String absolutePath;
  final String title;

  @override
  State<_PlayerSheet> createState() => _PlayerSheetState();
}

class _PlayerSheetState extends State<_PlayerSheet> {
  VideoPlayerController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final controller = VideoPlayerController.file(File(widget.absolutePath));
    try {
      await controller.initialize();
      if (!mounted) {
        await controller.dispose();
        return;
      }
      await controller.setLooping(true);
      await controller.play();
      setState(() => _controller = controller);
    } catch (e) {
      await controller.dispose();
      if (!mounted) return;
      // A file that encoded, passed the size/duration integrity check, and
      // still won't open is exactly the HEVC-playback risk in S17 — worth
      // seeing plainly rather than as a silent black rectangle.
      setState(() => _error = 'Could not play this file: $e\n\n'
          'If the codec was HEVC, this device may encode it but not decode it '
          'in the player — the H.264 fallback path matters.');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            if (_error != null)
              Text(_error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            else if (controller == null)
              const SizedBox(
                height: 200,
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              AspectRatio(
                aspectRatio: controller.value.aspectRatio,
                child: VideoPlayer(controller),
              ),
              VideoProgressIndicator(controller, allowScrubbing: true),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    icon: Icon(controller.value.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow),
                    onPressed: () => setState(() {
                      controller.value.isPlaying
                          ? controller.pause()
                          : controller.play();
                    }),
                  ),
                  Text('${controller.value.size.width.round()}'
                      'x${controller.value.size.height.round()}'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
