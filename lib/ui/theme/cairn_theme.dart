/// Builds `ThemeData` from the tokens, and exposes the palette to widgets.
///
/// Material's `ColorScheme` is still populated — enough of the framework reads
/// it that fighting that is pointless — but the palette is the source of truth,
/// reached through `context.palette`.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';

import 'tokens.dart';

/// Carries the palette down the tree so widgets can reach tokens Material's
/// `ColorScheme` has no slot for (`inkTertiary`, `hairline`, `record`).
class CairnColors extends ThemeExtension<CairnColors> {
  const CairnColors(this.palette);

  final CairnPalette palette;

  @override
  CairnColors copyWith({CairnPalette? palette}) =>
      CairnColors(palette ?? this.palette);

  @override
  CairnColors lerp(CairnColors? other, double t) =>
      // Palettes swap wholesale on a theme change rather than interpolating
      // through muddy intermediate colours.
      t < 0.5 ? this : (other ?? this);
}

extension PaletteAccess on BuildContext {
  /// The active palette. `context.palette.ink` reads better at the call site
  /// than a chain through `Theme.of`.
  CairnPalette get palette =>
      Theme.of(this).extension<CairnColors>()?.palette ?? CairnPalette.light;
}

ThemeData buildCairnTheme(CairnPalette palette) {
  final text = CairnType.textTheme(palette);
  final isDark = palette.isDark;

  final scheme = ColorScheme(
    brightness: palette.brightness,
    primary: palette.accent,
    onPrimary: palette.onAccent,
    primaryContainer: palette.accentSoft,
    onPrimaryContainer: palette.accent,
    secondary: palette.inkSecondary,
    onSecondary: palette.canvas,
    error: palette.danger,
    onError: palette.onAccent,
    errorContainer: palette.dangerSoft,
    onErrorContainer: palette.onDangerSoft,
    surface: palette.canvas,
    onSurface: palette.ink,
    onSurfaceVariant: palette.inkSecondary,
    surfaceContainerLowest: palette.canvas,
    surfaceContainerLow: palette.surface,
    surfaceContainer: palette.surface,
    surfaceContainerHigh: palette.surfaceSunken,
    surfaceContainerHighest: palette.surfaceSunken,
    outline: palette.inkTertiary,
    outlineVariant: palette.hairline,
    inverseSurface: palette.ink,
    onInverseSurface: palette.canvas,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: palette.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: palette.canvas,
    canvasColor: palette.canvas,
    extensions: [CairnColors(palette)],
    textTheme: text,
    fontFamily: CairnType.body,

    // Flat. Elevation is expressed with surface colour and hairlines, not
    // shadows -- shadows on a warm paper canvas read as grime.
    appBarTheme: AppBarTheme(
      backgroundColor: palette.canvas,
      surfaceTintColor: Colors.transparent,
      foregroundColor: palette.ink,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      iconTheme: IconThemeData(color: palette.ink, size: 22),
      actionsIconTheme: IconThemeData(color: palette.ink, size: 22),
    ),

    cardTheme: CardThemeData(
      elevation: 0,
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: palette.hairline),
      ),
    ),

    dividerTheme: DividerThemeData(
      color: palette.hairline,
      thickness: 1,
      space: 1,
    ),

    iconTheme: IconThemeData(color: palette.inkSecondary, size: 22),

    // Chips carry a lot of this UI (tags, filters, type marks), so they get a
    // deliberate flat treatment rather than Material's default tonal fill.
    chipTheme: ChipThemeData(
      backgroundColor: palette.surface,
      selectedColor: palette.accentSoft,
      disabledColor: palette.surfaceSunken,
      side: BorderSide(color: palette.hairline),
      labelStyle: text.labelMedium!.copyWith(color: palette.ink),
      secondaryLabelStyle: text.labelMedium!.copyWith(color: palette.accent),
      padding: const EdgeInsets.symmetric(horizontal: Space.sm, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.pill),
      ),
      showCheckmark: false,
      iconTheme: IconThemeData(size: 15, color: palette.inkSecondary),
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: palette.surfaceSunken,
      hintStyle: text.bodyMedium!.copyWith(color: palette.inkTertiary),
      labelStyle: text.labelMedium,
      floatingLabelStyle: text.labelMedium!.copyWith(color: palette.accent),
      helperStyle: text.labelSmall!.copyWith(color: palette.inkTertiary),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.lg,
        vertical: Space.md + 2,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide(color: palette.accent, width: 1.5),
      ),
    ),

    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: palette.accent,
        foregroundColor: palette.onAccent,
        disabledBackgroundColor: palette.surfaceSunken,
        disabledForegroundColor: palette.inkTertiary,
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        textStyle: text.labelLarge!.copyWith(fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),

    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: palette.ink,
        side: BorderSide(color: palette.hairline),
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: Space.xl),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
      ),
    ),

    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: palette.accent,
        textStyle: text.labelLarge!.copyWith(color: palette.accent),
        padding: const EdgeInsets.symmetric(horizontal: Space.md),
      ),
    ),

    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Space.gutter,
        vertical: Space.xs,
      ),
      iconColor: palette.inkSecondary,
      titleTextStyle: text.titleSmall,
      subtitleTextStyle: text.bodySmall!.copyWith(color: palette.inkTertiary),
      minVerticalPadding: Space.md,
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.onAccent
            : palette.surface,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? palette.accent
            : palette.surfaceSunken,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? Colors.transparent
            : palette.hairline,
      ),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: palette.accent,
      inactiveTrackColor: palette.hairline,
      thumbColor: palette.accent,
      overlayColor: palette.accentSoft,
      trackHeight: 3,
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: palette.accent,
      linearMinHeight: 4,
      linearTrackColor: palette.surfaceSunken,
      circularTrackColor: Colors.transparent,
    ),

    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: palette.canvas,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      showDragHandle: true,
      dragHandleColor: palette.hairline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xl)),
      ),
    ),

    dialogTheme: DialogThemeData(
      backgroundColor: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      titleTextStyle: text.headlineSmall,
      contentTextStyle: text.bodyMedium,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.lg),
        side: BorderSide(color: palette.hairline),
      ),
    ),

    snackBarTheme: SnackBarThemeData(
      backgroundColor: palette.ink,
      contentTextStyle: text.bodySmall!.copyWith(color: palette.canvas),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
      ),
    ),

    popupMenuTheme: PopupMenuThemeData(
      color: palette.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      textStyle: text.bodyMedium!.copyWith(color: palette.ink),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: palette.hairline),
      ),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: palette.ink,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      textStyle: text.labelSmall!.copyWith(color: palette.canvas),
    ),

    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accentSoft
              : Colors.transparent,
        ),
        foregroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.inkSecondary,
        ),
        side: WidgetStatePropertyAll(BorderSide(color: palette.hairline)),
        textStyle: WidgetStatePropertyAll(text.labelMedium),
      ),
    ),

    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: palette.ink,
      foregroundColor: palette.canvas,
      elevation: 0,
      focusElevation: 0,
      hoverElevation: 0,
      highlightElevation: 0,
      extendedTextStyle: text.labelLarge!.copyWith(
        color: palette.canvas,
        fontWeight: FontWeight.w600,
      ),
      shape: const StadiumBorder(),
    ),

    // Shared-axis-ish transitions rather than Material's vertical slide, which
    // feels heavy for a two-tap capture flow.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: _FadeThroughTransitions(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      },
    ),

    splashFactory: isDark ? InkSparkle.splashFactory : InkRipple.splashFactory,
  );
}

/// Fade + slight rise. Quiet, and quick enough not to sit between the user and
/// the record button.
class _FadeThroughTransitions extends PageTransitionsBuilder {
  const _FadeThroughTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Motion.curve);
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, 0.018),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
