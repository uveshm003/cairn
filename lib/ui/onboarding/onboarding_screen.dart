/// Onboarding (requirements.md §10): short, warm, benefit-led, skippable, no
/// account.
///
/// Three screens, not four. §10 lists permissions as a step but also says to ask
/// for mic and camera *at first record* — so there is no permissions screen
/// here. The one-line rationale that raises grant rates lives next to the OS
/// prompt in the capture screen, where it is actually relevant.
///
/// Each page carries a small painted illustration rather than an icon. Three
/// stock glyphs would say "template"; three drawings say someone made this.
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../library/library_screen.dart';
import '../theme/cairn_theme.dart';
import '../theme/tokens.dart';
import '../widgets/cairn_mark.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pageCount = 3;

  Future<void> _finish() async {
    await AppScope.of(context).settings.completeOnboarding();
    if (!mounted) return;
    // Replaces rather than pushes: onboarding should not be reachable with the
    // back button once it is done.
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => const LibraryScreen()),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final last = _page == _pageCount - 1;

    return Scaffold(
      backgroundColor: palette.canvas,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.gutter, Space.sm, Space.sm, 0),
              child: Row(
                children: [
                  const CairnMark(size: 22),
                  const SizedBox(width: Space.sm + 2),
                  Text(
                    'Cairn',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const Spacer(),
                  // Skippable, per §10.
                  TextButton(onPressed: _finish, child: const Text('Skip')),
                ],
              ),
            ),
            Expanded(
              child: PageView(
                controller: _controller,
                onPageChanged: (page) => setState(() => _page = page),
                children: const [
                  _Page(
                    art: _TrailArt(),
                    title: 'For the things you\nwant to find again',
                    body: 'A spoken thought, a practice run, a moment worth '
                        'keeping. Give it a type and a couple of tags, and it '
                        'stops being a file you never open again.',
                  ),
                  _Page(
                    art: _PrivateArt(),
                    title: 'Everything stays\non this phone',
                    body: 'No account, no cloud, no subscription. Cairn makes '
                        'no network requests at all — which also means you are '
                        'the only backup, so exporting now and then is a habit '
                        'worth keeping.',
                  ),
                  _Page(
                    art: _CompressArt(),
                    title: 'Small on disk',
                    body: 'The type you pick decides how it is compressed. A '
                        'minute-long note is a few megabytes, not a few '
                        'hundred — so a year of entries still fits.',
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Space.gutter,
                Space.lg,
                Space.gutter,
                Space.xl,
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      for (var i = 0; i < _pageCount; i++)
                        AnimatedContainer(
                          duration: Motion.normal,
                          curve: Motion.curve,
                          // The current dot stretches into a dash rather than
                          // just changing colour — clearer at a glance.
                          width: i == _page ? 20 : 6,
                          height: 6,
                          margin: const EdgeInsets.symmetric(horizontal: 3),
                          decoration: BoxDecoration(
                            color: i == _page
                                ? palette.accent
                                : palette.hairline,
                            borderRadius: BorderRadius.circular(Radii.pill),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: Space.xl),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: last
                          ? _finish
                          : () => _controller.nextPage(
                                duration: Motion.slow,
                                curve: Motion.curve,
                              ),
                      // §10 ends on a CTA that drops into capture. The library's
                      // empty state carries the same action, so landing there is
                      // still one tap from recording.
                      child: Text(last ? 'Record your first entry' : 'Continue'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.art, required this.title, required this.body});

  final Widget art;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    // Centred vertically when it fits, scrollable when it does not -- so a
    // large text scale degrades into scrolling rather than overflowing (§14),
    // and normal sizes do not leave a dead gap above the page dots.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: Space.xxl),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Center(child: art),
              const SizedBox(height: Space.huge),
              Text(title, style: text.displaySmall),
              const SizedBox(height: Space.lg),
              Text(
                body,
                style: text.bodyLarge?.copyWith(
                  color: context.palette.inkSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Page one: the trail of markers. Reuses the mark so onboarding and the app
/// icon and the empty state are visibly the same object.
class _TrailArt extends StatelessWidget {
  const _TrailArt();

  @override
  Widget build(BuildContext context) => const CairnScene(size: 104);
}

/// Page two: a phone with the contents held inside it, and a severed link —
/// "nothing leaves" said as a picture rather than a cloud-with-a-slash cliché.
class _PrivateArt extends StatelessWidget {
  const _PrivateArt();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 200,
      height: 104,
      child: CustomPaint(
        painter: _PrivatePainter(
          ink: palette.inkTertiary,
          accent: palette.accent,
          hairline: palette.hairline,
        ),
      ),
    );
  }
}

class _PrivatePainter extends CustomPainter {
  const _PrivatePainter({
    required this.ink,
    required this.accent,
    required this.hairline,
  });

  final Color ink;
  final Color accent;
  final Color hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = ink;

    // The phone, left of centre.
    final phone = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width * 0.10, size.height * 0.10,
          size.width * 0.30, size.height * 0.80),
      const Radius.circular(10),
    );
    canvas.drawRRect(phone, stroke);

    // Three stones inside it: the entries, safe where they are.
    final fill = Paint()..color = accent;
    for (var i = 0; i < 3; i++) {
      final w = size.width * (0.18 - i * 0.035);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(
              size.width * 0.25,
              size.height * (0.66 - i * 0.16),
            ),
            width: w,
            height: size.height * 0.085,
          ),
          Radius.circular(size.height * 0.05),
        ),
        i == 2 ? fill : (Paint()..color = ink.withValues(alpha: 0.55)),
      );
    }

    // A dashed line heading out, stopped short.
    final dash = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = hairline;
    var x = size.width * 0.47;
    while (x < size.width * 0.74) {
      canvas.drawLine(
        Offset(x, size.height * 0.5),
        Offset(x + 6, size.height * 0.5),
        dash,
      );
      x += 12;
    }

    // The stop: a small cross where the line would have left the device.
    final cross = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round
      ..color = ink;
    final c = Offset(size.width * 0.84, size.height * 0.5);
    const r = 7.0;
    canvas.drawLine(c + const Offset(-r, -r), c + const Offset(r, r), cross);
    canvas.drawLine(c + const Offset(r, -r), c + const Offset(-r, r), cross);
  }

  @override
  bool shouldRepaint(_PrivatePainter old) =>
      old.ink != ink || old.accent != accent || old.hairline != hairline;
}

/// Page three: a large block becoming a small one. The compression story told
/// with the two sizes side by side, which is the whole claim.
class _CompressArt extends StatelessWidget {
  const _CompressArt();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return SizedBox(
      width: 200,
      height: 104,
      child: CustomPaint(
        painter: _CompressPainter(
          ink: palette.inkTertiary,
          accent: palette.accent,
          hairline: palette.hairline,
        ),
      ),
    );
  }
}

class _CompressPainter extends CustomPainter {
  const _CompressPainter({
    required this.ink,
    required this.accent,
    required this.hairline,
  });

  final Color ink;
  final Color accent;
  final Color hairline;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height * 0.92;

    // Before: a tall outlined block.
    final big = Rect.fromLTRB(
      size.width * 0.06,
      size.height * 0.06,
      size.width * 0.34,
      baseline,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(big, const Radius.circular(6)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = hairline,
    );

    // After: a short solid block, same width, sitting on the same baseline so
    // the difference reads as height rather than as two unrelated shapes.
    final small = Rect.fromLTRB(
      size.width * 0.66,
      size.height * 0.66,
      size.width * 0.94,
      baseline,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(small, const Radius.circular(6)),
      Paint()..color = accent,
    );

    // The arrow between them.
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round
      ..color = ink;
    final y = size.height * 0.5;
    canvas.drawLine(
      Offset(size.width * 0.42, y),
      Offset(size.width * 0.58, y),
      stroke,
    );
    canvas.drawLine(
      Offset(size.width * 0.58, y),
      Offset(size.width * 0.53, y - 4.5),
      stroke,
    );
    canvas.drawLine(
      Offset(size.width * 0.58, y),
      Offset(size.width * 0.53, y + 4.5),
      stroke,
    );

    // Ground line, so both blocks are clearly standing on the same floor.
    canvas.drawLine(
      Offset(size.width * 0.04, baseline),
      Offset(size.width * 0.96, baseline),
      Paint()
        ..strokeWidth = 1
        ..color = hairline,
    );
  }

  @override
  bool shouldRepaint(_CompressPainter old) =>
      old.ink != ink || old.accent != accent || old.hairline != hairline;
}
