/// App shell: theme, and the scope that hands the database and media services
/// down the tree.
///
/// No state-management package. Drift's `.watch()` already returns streams, so
/// `StreamBuilder` covers the reactive library list, and an `InheritedWidget`
/// covers the handful of long-lived services. Adding a second reactive system
/// on top of the one the database already provides would be cost without
/// benefit at this size.
library;

import 'package:flutter/material.dart';

import 'data/database.dart';
import 'media/media_store.dart';
import 'media/save_pipeline.dart';
import 'settings/app_settings.dart';
import 'ui/library/library_screen.dart';
import 'ui/onboarding/onboarding_screen.dart';

/// The services that live as long as the app does.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.db,
    required this.store,
    required this.pipeline,
    required this.settings,
    required super.child,
  });

  final CairnDatabase db;
  final MediaStore store;
  final SavePipeline pipeline;
  final AppSettings settings;

  static AppScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'No AppScope in the widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) =>
      db != oldWidget.db ||
      store != oldWidget.store ||
      settings != oldWidget.settings;
}

/// Cairn's palette leans monochrome (S14), with type colours as the only
/// saturated accents — so the content stands out and the chrome does not.
const _seed = Color(0xFF4A5A63);

ThemeData _theme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
  return ThemeData(
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      elevation: 0,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      margin: EdgeInsets.zero,
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    ),
  );
}

class CairnApp extends StatelessWidget {
  const CairnApp({
    super.key,
    required this.db,
    required this.store,
    required this.settings,
    required this.showOnboarding,
  });

  final CairnDatabase db;
  final MediaStore store;
  final AppSettings settings;
  final bool showOnboarding;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      db: db,
      store: store,
      pipeline: SavePipeline(store),
      settings: settings,
      child: ValueListenableBuilder<ThemeMode>(
        valueListenable: settings.themeMode,
        builder: (context, mode, _) => MaterialApp(
          title: 'Cairn',
          debugShowCheckedModeBanner: false,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          themeMode: mode,
          home: showOnboarding
              ? const OnboardingScreen()
              : const LibraryScreen(),
        ),
      ),
    );
  }
}
