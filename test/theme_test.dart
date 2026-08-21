import 'dart:math' as math;

import 'package:cairn/ui/theme/cairn_theme.dart';
import 'package:cairn/ui/theme/tokens.dart';
import 'package:cairn/ui/widgets/formatting.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// §14 asks for "sufficient contrast", and a warm low-contrast neutral palette
/// is exactly where secondary text quietly drops below the line. These tests
/// compute the real WCAG ratios, so a future palette tweak fails here rather
/// than shipping an unreadable label.
double _relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double contrastRatio(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  const palettes = {'light': CairnPalette.light, 'dark': CairnPalette.dark};

  group('contrast (WCAG AA)', () {
    test('every text token clears 4.5:1 on both canvas and surface', () {
      for (final entry in palettes.entries) {
        final p = entry.value;
        final tokens = {
          'ink': p.ink,
          'inkSecondary': p.inkSecondary,
          'inkTertiary': p.inkTertiary,
          'accent': p.accent,
        };
        for (final token in tokens.entries) {
          for (final surface in {'canvas': p.canvas, 'surface': p.surface}.entries) {
            final ratio = contrastRatio(token.value, surface.value);
            expect(
              ratio,
              greaterThanOrEqualTo(4.5),
              reason: '${entry.key}.${token.key} on ${surface.key} '
                  'is ${ratio.toStringAsFixed(2)}:1',
            );
          }
        }
      }
    });

    test('accent text on an accent-soft fill stays readable', () {
      // Selected chips draw accent-coloured text on accentSoft. That pairing is
      // easy to get wrong because accentSoft is nearly the background.
      for (final entry in palettes.entries) {
        final p = entry.value;
        final composited = Color.alphaBlend(p.accentSoft, p.canvas);
        final ratio = contrastRatio(p.accent, composited);
        expect(ratio, greaterThanOrEqualTo(4.5),
            reason: '${entry.key}: accent on accentSoft is '
                '${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('on-danger text is readable on the danger fill', () {
      for (final entry in palettes.entries) {
        final p = entry.value;
        final ratio = contrastRatio(p.onDangerSoft, p.dangerSoft);
        expect(ratio, greaterThanOrEqualTo(4.5), reason: entry.key);
      }
    });

    test('type marks clear 3:1, the bar for non-text UI', () {
      // Type colours are used for small dots and short bold labels, not body
      // copy, so 3:1 is the applicable threshold rather than 4.5:1.
      for (final entry in palettes.entries) {
        final p = entry.value;
        for (final key in ['amber', 'indigo', 'teal', 'rose', 'slate']) {
          final ratio = contrastRatio(p.typeColor(key), p.canvas);
          expect(ratio, greaterThanOrEqualTo(3.0),
              reason: '${entry.key}.$key is ${ratio.toStringAsFixed(2)}:1');
        }
      }
    });

    test('hairlines are visible but not mistaken for text', () {
      for (final entry in palettes.entries) {
        final p = entry.value;
        final ratio = contrastRatio(p.hairline, p.canvas);
        // Visible enough to read as a border, quiet enough not to shout.
        expect(ratio, greaterThan(1.05), reason: '${entry.key} hairline invisible');
        expect(ratio, lessThan(4.5), reason: '${entry.key} hairline too loud');
      }
    });
  });

  group('theme wiring', () {
    test('exposes the palette through the extension', () {
      for (final entry in palettes.entries) {
        final theme = buildCairnTheme(entry.value);
        expect(theme.extension<CairnColors>()?.palette, entry.value);
        expect(theme.brightness, entry.value.brightness);
        // Scaffold background must come from the palette, not Material's
        // default -- a transparent or grey canvas would break the paper look.
        expect(theme.scaffoldBackgroundColor, entry.value.canvas);
      }
    });

    test('uses the bundled families, so a missing asset shows up as a failure',
        () {
      final theme = buildCairnTheme(CairnPalette.light);
      expect(theme.textTheme.displaySmall?.fontFamily, 'Fraunces');
      expect(theme.textTheme.bodyMedium?.fontFamily, 'Inter');
      expect(theme.textTheme.titleMedium?.fontFamily, 'Inter');
    });

    test('type scale is monotonic from body up to display', () {
      final t = buildCairnTheme(CairnPalette.light).textTheme;
      final sizes = [
        t.labelSmall!.fontSize!,
        t.bodySmall!.fontSize!,
        t.bodyLarge!.fontSize!,
        t.titleLarge!.fontSize!,
        t.headlineSmall!.fontSize!,
        t.headlineMedium!.fontSize!,
        t.displaySmall!.fontSize!,
      ];
      expect(sizes, orderedEquals([...sizes]..sort()));
    });

    test('flat by design — no shadow elevation anywhere', () {
      // Elevation is expressed with surface colour and hairlines. A stray
      // shadow on the warm canvas reads as grime.
      for (final entry in palettes.entries) {
        final theme = buildCairnTheme(entry.value);
        expect(theme.appBarTheme.elevation, 0, reason: entry.key);
        expect(theme.cardTheme.elevation, 0, reason: entry.key);
        expect(theme.dialogTheme.elevation, 0, reason: entry.key);
        expect(theme.floatingActionButtonTheme.elevation, 0, reason: entry.key);
      }
    });
  });

  group('formatDayHeading', () {
    test('names the recent days rather than dating them', () {
      final now = DateTime.now();
      expect(formatDayHeading(now), 'Today');
      expect(
        formatDayHeading(now.subtract(const Duration(days: 1))),
        'Yesterday',
      );
      // Inside the week, a weekday name is what people actually remember.
      final threeDaysAgo = now.subtract(const Duration(days: 3));
      expect(formatDayHeading(threeDaysAgo), isNot(contains('Today')));
      expect(formatDayHeading(threeDaysAgo).length, greaterThan(4));
    });

    test('falls back to a date beyond a week, and includes the year beyond one',
        () {
      final old = DateTime.now().subtract(const Duration(days: 40));
      expect(formatDayHeading(old), isNot('Today'));

      final ancient = DateTime(DateTime.now().year - 2, 3, 14);
      expect(formatDayHeading(ancient), contains('${DateTime.now().year - 2}'));
    });
  });

  group('type colour lookup', () {
    test('is identical whether reached through the palette or the helper', () {
      // colorForKey delegates to the palette; if that ever forks, the type marks
      // and the rest of the theme drift apart.
      for (final key in ['amber', 'indigo', 'teal', 'rose', 'slate', 'unknown']) {
        expect(
          colorForKey(key, Brightness.light),
          CairnPalette.light.typeColor(key),
        );
        expect(
          colorForKey(key, Brightness.dark),
          CairnPalette.dark.typeColor(key),
        );
      }
    });

    test('an unknown key degrades to the neutral instead of throwing', () {
      // Keys can arrive from an archive written by a different build.
      expect(
        CairnPalette.light.typeColor('from-the-future'),
        CairnPalette.light.typeColor('slate'),
      );
    });
  });
}
