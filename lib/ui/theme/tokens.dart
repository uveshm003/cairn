/// Design tokens.
///
/// The whole visual language lives here, so a screen never invents a colour, a
/// gap, or a radius. `requirements.md` §14 asks for "monochrome-friendly", and
/// the name does the rest of the work: a cairn is a stack of weathered stones,
/// so the palette is warm stone and paper with one trail-marker accent, and the
/// only saturated colours in the app are the per-type marks.
///
/// Every text token was checked against both its surfaces for WCAG AA (4.5:1) —
/// a warm low-contrast neutral palette is exactly where secondary text quietly
/// falls below the line, so the ramp is tuned rather than eyeballed.
library;

import 'package:flutter/material.dart';

/// Vertical and horizontal rhythm. One scale, used everywhere, so spacing looks
/// deliberate instead of arbitrary.
abstract final class Space {
  /// 2 — hairline nudges.
  static const xxs = 2.0;

  /// 4
  static const xs = 4.0;

  /// 8
  static const sm = 8.0;

  /// 12
  static const md = 12.0;

  /// 16 — the default gutter.
  static const lg = 16.0;

  /// 20 — screen edge padding.
  static const gutter = 20.0;

  /// 24
  static const xl = 24.0;

  /// 32 — between major blocks.
  static const xxl = 32.0;

  /// 48
  static const huge = 48.0;
}

abstract final class Radii {
  static const sm = 8.0;
  static const md = 12.0;

  /// Cards and sheets.
  static const lg = 18.0;
  static const xl = 26.0;

  /// Pills, chips, the record button.
  static const pill = 999.0;
}

/// Motion. Short and unshowy — this is a recorder, not a toy. Durations are on
/// the fast side of Material's defaults because every one of these sits between
/// a user and their recording.
abstract final class Motion {
  static const fast = Duration(milliseconds: 140);
  static const normal = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 340);

  /// Default easing: quick out, gentle settle.
  static const curve = Curves.easeOutCubic;

  /// For things that grow or pop (the record button, chips).
  static const emphasis = Curves.easeOutBack;
}

/// One palette, two moods. Named for what they are rather than for a Material
/// role, because the roles here are ours.
class CairnPalette {
  const CairnPalette({
    required this.brightness,
    required this.canvas,
    required this.surface,
    required this.surfaceSunken,
    required this.ink,
    required this.inkSecondary,
    required this.inkTertiary,
    required this.hairline,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.danger,
    required this.dangerSoft,
    required this.onDangerSoft,
    required this.record,
  });

  final Brightness brightness;

  /// The page.
  final Color canvas;

  /// Cards and raised things.
  final Color surface;

  /// Inputs and wells — recessed rather than raised.
  final Color surfaceSunken;

  /// Primary text. 16:1 on canvas.
  final Color ink;

  /// Supporting text. ~6.7:1.
  final Color inkSecondary;

  /// Faintest text. Tuned to clear 4.5:1 on *both* canvas and surface.
  final Color inkTertiary;

  /// Dividers and borders. Not a text colour — never used for type.
  final Color hairline;

  /// Trail-marker ochre. Actions, selection, focus.
  final Color accent;
  final Color onAccent;

  /// Accent at low opacity, for selected chips and quiet fills.
  final Color accentSoft;

  final Color danger;
  final Color dangerSoft;
  final Color onDangerSoft;

  /// The record button. Deliberately the one alarming red in the app.
  final Color record;

  static const light = CairnPalette(
    brightness: Brightness.light,
    canvas: Color(0xFFF6F4F0),
    surface: Color(0xFFFCFBF9),
    surfaceSunken: Color(0xFFEDEAE4),
    ink: Color(0xFF1A1815),
    inkSecondary: Color(0xFF5A554C),
    inkTertiary: Color(0xFF756F64),
    hairline: Color(0xFFE3DFD7),
    // Darkened from the original #9C5A32: accent-coloured text on an
    // accentSoft fill (selected chips) measured 4.27:1, under AA. This clears
    // 4.8:1 there with margin, and 5.5:1 on the plain surfaces.
    accent: Color(0xFF915229),
    onAccent: Color(0xFFFFFBF7),
    accentSoft: Color(0x1A915229),
    danger: Color(0xFF9B3A32),
    dangerSoft: Color(0xFFF7E4E1),
    onDangerSoft: Color(0xFF6E2A24),
    record: Color(0xFFC0392B),
  );

  static const dark = CairnPalette(
    brightness: Brightness.dark,
    canvas: Color(0xFF121110),
    surface: Color(0xFF1C1B18),
    surfaceSunken: Color(0xFF262421),
    ink: Color(0xFFF2EFE9),
    inkSecondary: Color(0xFFA9A298),
    inkTertiary: Color(0xFF898278),
    hairline: Color(0xFF2E2C28),
    accent: Color(0xFFD8946A),
    onAccent: Color(0xFF241208),
    accentSoft: Color(0x24D8946A),
    danger: Color(0xFFE98A7E),
    dangerSoft: Color(0xFF33201D),
    onDangerSoft: Color(0xFFF6C9C2),
    record: Color(0xFFD9483A),
  );

  bool get isDark => brightness == Brightness.dark;

  /// Accent for a per-type mark. The only saturated colours in the app, kept
  /// muted so they read as labels rather than decoration.
  Color typeColor(String key) => switch (key) {
        'amber' => isDark ? const Color(0xFFD9A441) : const Color(0xFF8E6410),
        'indigo' => isDark ? const Color(0xFF93A4E8) : const Color(0xFF44529E),
        'teal' => isDark ? const Color(0xFF6FC0B0) : const Color(0xFF176B61),
        'rose' => isDark ? const Color(0xFFDE8B9E) : const Color(0xFF9E3F5C),
        'slate' => isDark ? const Color(0xFF9FAEB6) : const Color(0xFF4E5D64),
        // An unknown key can arrive from an imported archive written by another
        // build, so it degrades to the neutral rather than throwing.
        _ => isDark ? const Color(0xFF9FAEB6) : const Color(0xFF4E5D64),
      };
}

/// Type scale. Fraunces for display, Inter for everything else.
///
/// Sizes are not scaled here — Flutter applies the user's text scale on top,
/// which §14 requires. Layouts must therefore be intrinsic-height wherever text
/// sits, not fixed boxes.
abstract final class CairnType {
  static const display = 'Fraunces';
  static const body = 'Inter';

  static TextTheme textTheme(CairnPalette palette) {
    final ink = palette.ink;
    final secondary = palette.inkSecondary;

    return TextTheme(
      // --- Fraunces. Screen titles and the few editorial moments.
      displaySmall: TextStyle(
        fontFamily: display,
        fontSize: 34,
        height: 1.14,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.6,
        color: ink,
      ),
      headlineMedium: TextStyle(
        fontFamily: display,
        fontSize: 27,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.3,
        color: ink,
      ),
      headlineSmall: TextStyle(
        fontFamily: display,
        fontSize: 21,
        height: 1.25,
        fontWeight: FontWeight.w500,
        letterSpacing: -0.1,
        color: ink,
      ),

      // --- Inter. Everything functional.
      titleLarge: TextStyle(
        fontFamily: body,
        fontSize: 18,
        height: 1.3,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.2,
        color: ink,
      ),
      titleMedium: TextStyle(
        fontFamily: body,
        fontSize: 15.5,
        height: 1.35,
        fontWeight: FontWeight.w600,
        letterSpacing: -0.1,
        color: ink,
      ),
      titleSmall: TextStyle(
        fontFamily: body,
        fontSize: 14,
        height: 1.35,
        fontWeight: FontWeight.w500,
        color: ink,
      ),
      bodyLarge: TextStyle(
        fontFamily: body,
        fontSize: 16,
        height: 1.5,
        fontWeight: FontWeight.w400,
        color: ink,
      ),
      bodyMedium: TextStyle(
        fontFamily: body,
        fontSize: 14.5,
        height: 1.45,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      bodySmall: TextStyle(
        fontFamily: body,
        fontSize: 13,
        height: 1.4,
        fontWeight: FontWeight.w400,
        color: secondary,
      ),
      labelLarge: TextStyle(
        fontFamily: body,
        fontSize: 14.5,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: ink,
      ),
      labelMedium: TextStyle(
        fontFamily: body,
        fontSize: 12.5,
        height: 1.25,
        fontWeight: FontWeight.w500,
        color: secondary,
      ),
      labelSmall: TextStyle(
        fontFamily: body,
        fontSize: 11.5,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: secondary,
      ),
    );
  }

  /// Small all-caps section label. Used for the section headers that give the
  /// settings and detail screens their structure.
  static TextStyle eyebrow(CairnPalette palette) => TextStyle(
        fontFamily: body,
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.3,
        color: palette.inkTertiary,
      );

  /// Tabular figures, so a running timer does not jitter as digits change.
  static TextStyle timer(CairnPalette palette, {double size = 30}) => TextStyle(
        fontFamily: body,
        fontSize: size,
        height: 1.1,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.5,
        color: palette.ink,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
}
