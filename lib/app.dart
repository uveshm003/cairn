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
import 'ui/theme/cairn_theme.dart';
import 'ui/theme/tokens.dart';

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
          theme: buildCairnTheme(CairnPalette.light),
          darkTheme: buildCairnTheme(CairnPalette.dark),
          themeMode: mode,
          home: showOnboarding
              ? const OnboardingScreen()
              : const LibraryScreen(),
        ),
      ),
    );
  }
}
