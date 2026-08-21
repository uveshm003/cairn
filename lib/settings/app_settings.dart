/// AppSettings (requirements.md S7), backed by the key-value `settings` table.
///
/// Values are cached in `ValueNotifier`s so the UI can bind to them directly and
/// writes are fire-and-forget — a settings toggle should never make the user
/// wait on a disk write.
library;

import 'package:camera/camera.dart' show CameraLensDirection;
import 'package:flutter/material.dart';

import '../data/database.dart';
import '../domain/camera_choice.dart';
import '../domain/entry_filter.dart';
import 'dart:convert';

class AppSettings {
  AppSettings._(this._db);

  final CairnDatabase _db;

  static const _kOnboarded = 'onboarded';
  static const _kThemeMode = 'themeMode';
  static const _kDefaultTypeId = 'defaultTypeId';
  static const _kLocationEnabled = 'locationEnabled';
  static const _kKeepOriginals = 'keepOriginals';
  static const _kHardCapMs = 'hardCapMs';
  static const _kTrashRetentionDays = 'trashRetentionDays';
  static const _kLastFilter = 'lastFilter';
  static const _kEntriesSinceBackup = 'entriesSinceBackup';
  static const _kLastBackupAt = 'lastBackupAt';
  static const _kGridView = 'gridView';
  static const _kProfileOverride = 'profileOverride';
  static const _kPreferredLens = 'preferredLens';

  /// S6: a hard ceiling across all types, to protect storage and encode time.
  static const defaultHardCapMs = 30 * 60 * 1000;

  /// S9: purge trash after N days.
  static const defaultTrashRetentionDays = 30;

  /// S11: nudge for a backup after this many new entries.
  static const backupNudgeAfterEntries = 25;

  final themeMode = ValueNotifier(ThemeMode.system);
  final defaultTypeId = ValueNotifier<int?>(null);

  /// Off by default — a non-negotiable (S5).
  final locationEnabled = ValueNotifier(false);

  /// Off by default: keeping originals defeats the point of compressing (S8).
  final keepOriginals = ValueNotifier(false);

  final hardCapMs = ValueNotifier(defaultHardCapMs);
  final trashRetentionDays = ValueNotifier(defaultTrashRetentionDays);
  final gridView = ValueNotifier(false);

  /// Advanced override of the type's profile (S8 allows this for power users).
  /// Null means "let the type decide", which is the intended path.
  final profileOverride = ValueNotifier<ProfileKind?>(null);

  /// Which camera to open with. Remembered, because a user who records diary
  /// entries wants the front lens every time and should not re-flip on each
  /// capture. Defaults to back: of the jobs in §3, more of them point away from
  /// you (practice, how-to, milestones) than at you.
  final preferredLens = ValueNotifier(CameraLensDirection.back);

  final entriesSinceBackup = ValueNotifier(0);
  final lastBackupAt = ValueNotifier<DateTime?>(null);
  final lastFilter = ValueNotifier<EntryFilter>(EntryFilter.empty);

  bool onboarded = false;

  static Future<AppSettings> load(CairnDatabase db) async {
    final settings = AppSettings._(db);
    await settings._read();
    return settings;
  }

  Future<void> _read() async {
    Future<String?> get(String key) => _db.settingValue(key);

    onboarded = await get(_kOnboarded) == 'true';

    final theme = await get(_kThemeMode);
    themeMode.value = switch (theme) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };

    defaultTypeId.value = int.tryParse(await get(_kDefaultTypeId) ?? '');
    locationEnabled.value = await get(_kLocationEnabled) == 'true';
    keepOriginals.value = await get(_kKeepOriginals) == 'true';
    gridView.value = await get(_kGridView) == 'true';
    hardCapMs.value =
        int.tryParse(await get(_kHardCapMs) ?? '') ?? defaultHardCapMs;
    trashRetentionDays.value =
        int.tryParse(await get(_kTrashRetentionDays) ?? '') ??
            defaultTrashRetentionDays;
    entriesSinceBackup.value =
        int.tryParse(await get(_kEntriesSinceBackup) ?? '') ?? 0;

    final backupAt = int.tryParse(await get(_kLastBackupAt) ?? '');
    lastBackupAt.value =
        backupAt == null ? null : DateTime.fromMillisecondsSinceEpoch(backupAt);

    final override = await get(_kProfileOverride);
    profileOverride.value = switch (override) {
      'small' => ProfileKind.small,
      'balanced' => ProfileKind.balanced,
      'high' => ProfileKind.high,
      _ => null,
    };

    preferredLens.value =
        LensLabel.fromStorage(await get(_kPreferredLens)) ??
            CameraLensDirection.back;

    final storedFilter = await get(_kLastFilter);
    if (storedFilter != null) {
      try {
        lastFilter.value = EntryFilter.fromJson(
          jsonDecode(storedFilter) as Map<String, dynamic>,
        );
      } catch (_) {
        // A filter written by a different build should not stop the app
        // opening. Fall back to showing everything.
        lastFilter.value = EntryFilter.empty;
      }
    }
  }

  Future<void> completeOnboarding() async {
    onboarded = true;
    await _db.setSetting(_kOnboarded, 'true');
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await _db.setSetting(_kThemeMode, mode.name);
  }

  Future<void> setDefaultTypeId(int? id) async {
    defaultTypeId.value = id;
    await _db.setSetting(_kDefaultTypeId, id?.toString() ?? '');
  }

  Future<void> setLocationEnabled(bool value) async {
    locationEnabled.value = value;
    await _db.setSetting(_kLocationEnabled, '$value');
  }

  Future<void> setKeepOriginals(bool value) async {
    keepOriginals.value = value;
    await _db.setSetting(_kKeepOriginals, '$value');
  }

  Future<void> setGridView(bool value) async {
    gridView.value = value;
    await _db.setSetting(_kGridView, '$value');
  }

  Future<void> setHardCapMs(int value) async {
    hardCapMs.value = value;
    await _db.setSetting(_kHardCapMs, '$value');
  }

  Future<void> setTrashRetentionDays(int value) async {
    trashRetentionDays.value = value;
    await _db.setSetting(_kTrashRetentionDays, '$value');
  }

  Future<void> setProfileOverride(ProfileKind? kind) async {
    profileOverride.value = kind;
    await _db.setSetting(_kProfileOverride, kind?.name ?? '');
  }

  Future<void> setPreferredLens(CameraLensDirection lens) async {
    preferredLens.value = lens;
    await _db.setSetting(_kPreferredLens, lens.storageKey);
  }

  Future<void> saveFilter(EntryFilter filter) async {
    lastFilter.value = filter;
    await _db.setSetting(_kLastFilter, jsonEncode(filter.toJson()));
  }

  /// Called after each save, to drive the gentle backup nudge (S11).
  Future<void> noteEntryAdded() async {
    entriesSinceBackup.value += 1;
    await _db.setSetting(_kEntriesSinceBackup, '${entriesSinceBackup.value}');
  }

  Future<void> noteBackupTaken() async {
    entriesSinceBackup.value = 0;
    lastBackupAt.value = DateTime.now();
    await _db.setSetting(_kEntriesSinceBackup, '0');
    await _db.setSetting(
      _kLastBackupAt,
      '${lastBackupAt.value!.millisecondsSinceEpoch}',
    );
  }

  /// S11: "gentle, dismissible nudge every N days or after M new entries."
  bool get shouldNudgeBackup =>
      entriesSinceBackup.value >= backupNudgeAfterEntries;
}
