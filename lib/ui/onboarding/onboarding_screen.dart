/// Onboarding (requirements.md S10): short, warm, benefit-led, skippable, no
/// account.
///
/// Three screens, not four. S10 lists permissions as a step, but it also says to
/// request mic/camera *at first record* rather than up front — so there is no
/// permissions screen here at all. The one-line rationale that raises grant
/// rates lives next to the OS prompt, in the capture screen, which is where it
/// is actually relevant.
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../library/library_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _controller = PageController();
  int _page = 0;

  static const _pages = <_Page>[
    _Page(
      icon: Icons.graphic_eq,
      title: 'For the things you want to find again',
      body: 'Record a spoken thought, a practice run, a moment worth keeping. '
          'Give it a type and a couple of tags, and it stops being a file you '
          'will never open again.',
    ),
    _Page(
      icon: Icons.phonelink_lock_outlined,
      title: 'Everything stays on this phone',
      body: 'No account, no cloud, no subscription. Cairn makes no network '
          'requests at all — which also means you are the only backup, so '
          'exporting now and then is worth the habit.',
    ),
    _Page(
      icon: Icons.compress,
      title: 'Small on disk',
      body: 'The type you pick decides how it is compressed. A minute-long '
          'note is a few megabytes, not a few hundred — so a year of entries '
          'still fits comfortably.',
    ),
  ];

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
    final theme = Theme.of(context);
    final last = _page == _pages.length - 1;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.all(8),
                // Skippable, per S10.
                child: TextButton(
                  onPressed: _finish,
                  child: const Text('Skip'),
                ),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _controller,
                itemCount: _pages.length,
                onPageChanged: (page) => setState(() => _page = page),
                itemBuilder: (context, index) => _pages[index].build(context),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _pages.length; i++)
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: i == _page
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outlineVariant,
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(24),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: last
                      ? _finish
                      : () => _controller.nextPage(
                            duration: const Duration(milliseconds: 260),
                            curve: Curves.easeOut,
                          ),
                  icon: Icon(last ? Icons.fiber_manual_record : Icons.arrow_forward),
                  // S10: end on a CTA that drops straight into capture. The
                  // library's empty state carries the same action, so landing
                  // there is one tap from recording either way.
                  label: Text(last ? 'Record your first entry' : 'Next'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page {
  const _Page({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: theme.colorScheme.primary),
          const SizedBox(height: 40),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}
