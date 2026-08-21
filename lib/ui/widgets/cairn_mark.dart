/// The Cairn mark: a stack of weathered stones.
///
/// A cairn is the small pile walkers leave to mark a trail so they can find the
/// way back — which is the whole product in one image, so it is worth drawing
/// properly rather than reaching for a generic waveform icon.
///
/// Painted rather than shipped as an asset: it inherits the palette, scales to
/// any size without a second file, and costs nothing to declare.
library;

import 'package:flutter/material.dart';

import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';

class CairnMark extends StatelessWidget {
  const CairnMark({
    super.key,
    this.size = 40,
    this.color,
    this.accentTop = true,
  });

  final double size;

  /// Defaults to the primary ink.
  final Color? color;

  /// Tints the topmost stone with the accent — the trail marker catching light.
  final bool accentTop;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: _CairnPainter(
          color: color ?? palette.ink,
          accent: accentTop ? palette.accent : (color ?? palette.ink),
        ),
      ),
    );
  }
}

class _CairnPainter extends CustomPainter {
  const _CairnPainter({required this.color, required this.accent});

  final Color color;
  final Color accent;

  /// Four stones, bottom to top. Width and height as fractions of the box, plus
  /// a horizontal nudge — the asymmetry is what makes it read as stacked stones
  /// rather than a bar chart.
  static const _stones = <({double w, double h, double dx, double tilt})>[
    (w: 0.86, h: 0.20, dx: 0.00, tilt: -0.02),
    (w: 0.66, h: 0.18, dx: 0.05, tilt: 0.03),
    (w: 0.48, h: 0.16, dx: -0.04, tilt: -0.04),
    (w: 0.28, h: 0.14, dx: 0.02, tilt: 0.05),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    const gap = 0.035;
    // Stack upward from the base, so the mark sits on its bottom edge.
    var y = size.height;

    for (var i = 0; i < _stones.length; i++) {
      final stone = _stones[i];
      final w = size.width * stone.w;
      final h = size.height * stone.h;
      y -= h;

      final center = Offset(
        size.width / 2 + size.width * stone.dx,
        y + h / 2,
      );

      canvas.save();
      canvas.translate(center.dx, center.dy);
      canvas.rotate(stone.tilt);

      final paint = Paint()
        ..style = PaintingStyle.fill
        // The top stone catches the accent; the rest are ink, fading very
        // slightly down the stack so the base reads as heavier.
        ..color = i == _stones.length - 1
            ? accent
            : color.withValues(alpha: 1 - (0.06 * (_stones.length - 1 - i)));

      // A superellipse-ish rounded form: flatter than a capsule, softer than a
      // rectangle. Reads as river stone.
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: w, height: h),
          Radius.elliptical(h * 0.62, h * 0.5),
        ),
        paint,
      );
      canvas.restore();

      y -= size.height * gap;
    }
  }

  @override
  bool shouldRepaint(_CairnPainter old) =>
      old.color != color || old.accent != accent;
}

/// A larger, quieter version for empty states: the mark plus a faint horizon
/// line, which turns an icon into a small scene without needing an illustration.
class CairnScene extends StatelessWidget {
  const CairnScene({super.key, this.size = 96});

  final double size;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: size * 2.2,
      height: size,
      child: CustomPaint(
        painter: _ScenePainter(
          ink: palette.inkTertiary,
          accent: palette.accent,
          hairline: palette.hairline,
        ),
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  const _ScenePainter({
    required this.ink,
    required this.accent,
    required this.hairline,
  });

  final Color ink;
  final Color accent;
  final Color hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final groundY = size.height * 0.86;

    // Horizon. Fades at both ends so it reads as depth of field rather than a
    // divider someone forgot to remove.
    final horizon = Paint()
      ..shader = LinearGradient(
        colors: [
          hairline.withValues(alpha: 0),
          hairline,
          hairline.withValues(alpha: 0),
        ],
        stops: const [0, 0.5, 1],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, groundY), Offset(size.width, groundY), horizon);

    // The cairn, sitting on the horizon, slightly left of centre.
    final markSize = size.height * 0.78;
    canvas.save();
    canvas.translate(size.width / 2 - markSize * 0.62, groundY - markSize);
    _CairnPainter(color: ink, accent: accent)
        .paint(canvas, Size(markSize, markSize));
    canvas.restore();

    // Two much smaller, fainter cairns further along the trail — the sense that
    // this is one marker in a line of them.
    for (final spec in const [(dx: 0.30, scale: 0.34), (dx: 0.44, scale: 0.20)]) {
      final s = size.height * spec.scale;
      canvas.save();
      canvas.translate(size.width / 2 + size.width * spec.dx, groundY - s);
      _CairnPainter(
        color: ink.withValues(alpha: 0.35 * spec.scale / 0.34),
        accent: ink.withValues(alpha: 0.30),
      ).paint(canvas, Size(s, s));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ScenePainter old) =>
      old.ink != ink || old.accent != accent || old.hairline != hairline;
}

/// The record button. A filled dot that becomes a square when running, with a
/// breathing ring while recording.
///
/// One control, two states, no icon swap — the shape morph *is* the affordance,
/// which is how every camera app the user already knows behaves.
class RecordButton extends StatefulWidget {
  const RecordButton({
    super.key,
    required this.recording,
    required this.onTap,
    this.enabled = true,
    this.diameter = 76,
  });

  final bool recording;
  final VoidCallback onTap;
  final bool enabled;
  final double diameter;

  @override
  State<RecordButton> createState() => _RecordButtonState();
}

class _RecordButtonState extends State<RecordButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.recording) _pulse.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(RecordButton old) {
    super.didUpdateWidget(old);
    if (widget.recording && !_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    } else if (!widget.recording && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final d = widget.diameter;
    final inner = widget.recording ? d * 0.36 : d * 0.78;

    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.recording ? 'Stop recording' : 'Start recording',
      child: GestureDetector(
        onTap: widget.enabled ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: SizedBox.square(
          dimension: d,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Breathing ring. Only while recording, so a still screen is
              // genuinely still.
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) => Container(
                  width: d,
                  height: d,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: widget.recording
                          ? palette.record.withValues(
                              alpha: 0.35 + 0.45 * _pulse.value,
                            )
                          : Colors.white.withValues(alpha: 0.55),
                      width: widget.recording ? 2.5 : 2,
                    ),
                  ),
                ),
              ),
              AnimatedContainer(
                duration: Motion.normal,
                curve: Motion.emphasis,
                width: inner,
                height: inner,
                decoration: BoxDecoration(
                  color: widget.enabled
                      ? palette.record
                      : palette.record.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(
                    // Circle at rest, rounded square while recording.
                    widget.recording ? Radii.sm : Radii.pill,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
