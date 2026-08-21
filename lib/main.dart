/// Cairn — a private, offline recorder for audio and video entries.
///
/// A filing cabinet for spoken and visual thoughts: private by default, tiny on
/// disk, and it makes no network requests at all.
library;

import 'package:flutter/material.dart';

import 'app.dart';
import 'data/database.dart';
import 'media/media_store.dart';
import 'media/save_pipeline.dart';
import 'settings/app_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = CairnDatabase();
  final store = await MediaStore.open();
  final settings = await AppSettings.load(db);

  // Housekeeping on launch, not on a timer: the trash purge and the orphan
  // sweep both touch the filesystem, and doing them here means they happen
  // exactly once per session instead of competing with capture.
  //
  // Deliberately not awaited -- a slow sweep must not delay first paint, and
  // nothing on screen depends on the result.
  _purgeExpiredTrash(db, store, settings);

  runApp(CairnApp(
    db: db,
    store: store,
    settings: settings,
    showOnboarding: !settings.onboarded,
  ));
}

/// S9: purge soft-deleted entries after N days.
///
/// Files go before rows. A crash between the two leaves a row pointing at a
/// missing file, which the app shows plainly and the orphan sweep can repair.
/// The other order would leave files that no row references — invisible dead
/// weight that only a sweep would ever find.
Future<void> _purgeExpiredTrash(
  CairnDatabase db,
  MediaStore store,
  AppSettings settings,
) async {
  try {
    final pipeline = SavePipeline(store);
    final expired = await db.trashOlderThan(
      Duration(days: settings.trashRetentionDays.value),
    );
    for (final entry in expired) {
      await pipeline.deleteMediaFor(entry);
      await db.purgeEntry(entry.id);
    }
  } catch (_) {
    // Housekeeping is never worth failing a launch over. If it did not run
    // this session it will run the next one.
  }
}
