/// Settings (requirements.md S13): defaults, privacy, storage, backup, theme.
library;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../backup/backup_service.dart';
import '../../data/database.dart';
import '../../domain/encoding_profile.dart';
import '../lab/lab_screen.dart';
import '../widgets/formatting.dart';
import 'storage_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;
  String? _busyMessage;

  @override
  Widget build(BuildContext context) {
    final scope = AppScope.of(context);
    final settings = scope.settings;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Stack(
        children: [
          ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              const _SectionHeader('Capture'),
              FutureBuilder<List<EntryTypeRow>>(
                future: scope.db.allTypes(),
                builder: (context, snapshot) {
                  final types = snapshot.data ?? const <EntryTypeRow>[];
                  return ValueListenableBuilder<int?>(
                    valueListenable: settings.defaultTypeId,
                    builder: (context, selected, _) {
                      final type = types.firstWhere(
                        (t) => t.id == selected,
                        orElse: () => types.isEmpty
                            ? throw StateError('no types')
                            : types.first,
                      );
                      if (types.isEmpty) return const SizedBox.shrink();
                      return ListTile(
                        leading: const Icon(Icons.category_outlined),
                        title: const Text('Default type'),
                        subtitle: Text(type.name),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _pickDefaultType(types, type),
                      );
                    },
                  );
                },
              ),
              ValueListenableBuilder<ProfileKind?>(
                valueListenable: settings.profileOverride,
                builder: (context, override, _) => ListTile(
                  leading: const Icon(Icons.compress),
                  title: const Text('Quality'),
                  subtitle: Text(
                    override == null
                        // The intended path: S8 says the type decides, and the
                        // user never has to think about bitrate.
                        ? 'Chosen by entry type'
                        : '${EncodingProfile.of(override).label} for everything',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickProfile,
                ),
              ),
              ValueListenableBuilder<int>(
                valueListenable: settings.hardCapMs,
                builder: (context, cap, _) => ListTile(
                  leading: const Icon(Icons.timer_outlined),
                  title: const Text('Maximum length'),
                  subtitle: Text(
                    '${formatDuration(cap)} — a ceiling across all types',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickHardCap,
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: settings.keepOriginals,
                builder: (context, keep, _) => SwitchListTile(
                  secondary: const Icon(Icons.save_outlined),
                  title: const Text('Keep uncompressed originals'),
                  subtitle: const Text(
                    'Off by default — keeping them undoes the space saving.',
                  ),
                  value: keep,
                  onChanged: settings.setKeepOriginals,
                ),
              ),

              const _SectionHeader('Privacy'),
              ValueListenableBuilder<bool>(
                valueListenable: settings.locationEnabled,
                builder: (context, enabled, _) => SwitchListTile(
                  secondary: const Icon(Icons.location_on_outlined),
                  title: const Text('Record location'),
                  subtitle: const Text(
                    'Off by default. Stored on this device only, like '
                    'everything else.',
                  ),
                  value: enabled,
                  onChanged: settings.setLocationEnabled,
                ),
              ),
              const ListTile(
                leading: Icon(Icons.cloud_off),
                title: Text('No network access'),
                subtitle: Text(
                  'Cairn makes no network requests. Nothing is uploaded, and '
                  'there is no account to sign in to.',
                ),
              ),

              const _SectionHeader('Storage'),
              ListTile(
                leading: const Icon(Icons.pie_chart_outline),
                title: const Text('Storage usage'),
                subtitle: const Text('What is taking up space, and how much '
                    'compression has saved'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const StorageScreen(),
                )),
              ),
              ValueListenableBuilder<int>(
                valueListenable: settings.trashRetentionDays,
                builder: (context, days, _) => ListTile(
                  leading: const Icon(Icons.auto_delete_outlined),
                  title: const Text('Empty trash after'),
                  subtitle: Text('$days days'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickRetention,
                ),
              ),

              const _SectionHeader('Backup'),
              ValueListenableBuilder<DateTime?>(
                valueListenable: settings.lastBackupAt,
                builder: (context, last, _) => ListTile(
                  leading: const Icon(Icons.ios_share),
                  title: const Text('Export everything'),
                  subtitle: Text(
                    last == null
                        // Blunt on purpose: this is the only safety net there is.
                        ? 'Never exported. You are the only backup.'
                        : 'Last export ${formatWhen(last)}',
                  ),
                  onTap: _export,
                ),
              ),
              ListTile(
                leading: const Icon(Icons.download_outlined),
                title: const Text('Import from a backup'),
                subtitle: const Text('Restore entries from a Cairn zip'),
                onTap: _import,
              ),

              const _SectionHeader('Appearance'),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: settings.themeMode,
                builder: (context, mode, _) => ListTile(
                  leading: const Icon(Icons.contrast),
                  title: const Text('Theme'),
                  subtitle: Text(switch (mode) {
                    ThemeMode.light => 'Light',
                    ThemeMode.dark => 'Dark',
                    ThemeMode.system => 'Match the system',
                  }),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _pickTheme,
                ),
              ),

              const _SectionHeader('Maintenance'),
              ListTile(
                leading: const Icon(Icons.healing_outlined),
                title: const Text('Check for orphaned files'),
                subtitle: const Text(
                  'Finds media with no entry, and entries with no media',
                ),
                onTap: _runOrphanSweep,
              ),
              ListTile(
                leading: const Icon(Icons.manage_search),
                title: const Text('Rebuild search index'),
                subtitle: const Text('If search results look wrong'),
                onTap: _rebuildIndex,
              ),
              ListTile(
                leading: const Icon(Icons.science_outlined),
                title: const Text('Compression lab'),
                subtitle: const Text(
                  'Developer tool: measure the encoding ladder on this device',
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const LabScreen()),
                ),
              ),

              const _SectionHeader('About'),
              const ListTile(
                leading: Icon(Icons.terrain_outlined),
                title: Text('Cairn'),
                subtitle: Text(
                  'A cairn is the small stack of stones walkers leave to mark a '
                  'trail, so they can find the way back.',
                ),
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          const SizedBox(height: 16),
                          Text(_busyMessage ?? 'Working…'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------- pickers

  Future<void> _pickDefaultType(
    List<EntryTypeRow> types,
    EntryTypeRow current,
  ) async {
    final picked = await showDialog<EntryTypeRow>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Default type'),
        children: [
          for (final type in types)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(type),
              child: ListTile(
                title: Text(type.name),
                subtitle: Text('Up to ${formatDuration(type.maxDurationMs)}'),
                trailing:
                    type.id == current.id ? const Icon(Icons.check) : null,
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await AppScope.of(context).settings.setDefaultTypeId(picked.id);
  }

  Future<void> _pickProfile() async {
    final settings = AppScope.of(context).settings;
    final picked = await showDialog<Object?>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Quality'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop('auto'),
            child: const ListTile(
              title: Text('Chosen by entry type'),
              subtitle: Text('Recommended'),
            ),
          ),
          for (final profile in EncodingProfile.ladder)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(profile.kind),
              child: ListTile(
                title: Text(profile.label),
                subtitle: Text(profile.description),
              ),
            ),
        ],
      ),
    );
    if (picked == null) return;
    await settings.setProfileOverride(picked is ProfileKind ? picked : null);
  }

  Future<void> _pickHardCap() async {
    const options = [5, 10, 20, 30, 60];
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Maximum length'),
        children: [
          for (final minutes in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(minutes),
              child: ListTile(title: Text('$minutes minutes')),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await AppScope.of(context).settings.setHardCapMs(picked * 60 * 1000);
  }

  Future<void> _pickRetention() async {
    const options = [7, 14, 30, 90];
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Empty trash after'),
        children: [
          for (final days in options)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(days),
              child: ListTile(title: Text('$days days')),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await AppScope.of(context).settings.setTrashRetentionDays(picked);
  }

  Future<void> _pickTheme() async {
    final picked = await showDialog<ThemeMode>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Theme'),
        children: [
          for (final mode in ThemeMode.values)
            SimpleDialogOption(
              onPressed: () => Navigator.of(context).pop(mode),
              child: ListTile(
                title: Text(switch (mode) {
                  ThemeMode.light => 'Light',
                  ThemeMode.dark => 'Dark',
                  ThemeMode.system => 'Match the system',
                }),
              ),
            ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    await AppScope.of(context).settings.setThemeMode(picked);
  }

  // ------------------------------------------------------------- actions

  void _setBusy(String? message) {
    if (!mounted) return;
    setState(() {
      _busy = message != null;
      _busyMessage = message;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export() async {
    final scope = AppScope.of(context);
    final service = BackupService(scope.db, scope.store);
    _setBusy('Preparing export…');
    try {
      final result = await service.exportArchive(
        onProgress: (p) => _setBusy(p.message),
      );
      _setBusy(null);
      await service.shareArchive(result);
      await scope.settings.noteBackupTaken();
      _toast('Exported ${result.entryCount} entries '
          '(${formatBytes(result.bytes)}).');
    } catch (e) {
      _setBusy(null);
      _toast('Export failed: $e');
    }
  }

  Future<void> _import() async {
    final mode = await showDialog<ImportMode>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import a backup'),
        content: const Text(
          'Merge adds anything missing and leaves what you already have alone. '
          'Replace deletes everything currently in Cairn first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(ImportMode.replace),
            child: const Text('Replace'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ImportMode.merge),
            child: const Text('Merge'),
          ),
        ],
      ),
    );
    if (mode == null || !mounted) return;

    // file_picker 12 is federated: static methods, and no FilePickerResult.
    final picked = await FilePicker.pickFile(type: FileType.any);
    final path = picked?.path;
    if (path == null || !mounted) return;

    final scope = AppScope.of(context);
    final service = BackupService(scope.db, scope.store);
    _setBusy('Importing…');
    try {
      final result = await service.importArchive(
        path,
        mode: mode,
        onProgress: (p) => _setBusy(p.message),
      );
      _setBusy(null);
      _toast([
        'Imported ${result.imported}',
        if (result.skipped > 0) '${result.skipped} already here',
        if (result.missingMedia > 0)
          '${result.missingMedia} had no media in the archive',
      ].join(' · '));
    } on BackupException catch (e) {
      _setBusy(null);
      _toast(e.message);
    } catch (e) {
      _setBusy(null);
      _toast('Import failed: $e');
    }
  }

  Future<void> _runOrphanSweep() async {
    final scope = AppScope.of(context);
    _setBusy('Checking files…');

    final entries = await scope.db.allEntriesIncludingTrash();
    final referenced = <String>{};
    final byEntry = <int, List<String>>{};
    for (final entry in entries) {
      referenced.add(entry.filePath);
      final paths = [entry.filePath];
      if (entry.thumbnailPath != null) {
        referenced.add(entry.thumbnailPath!);
        paths.add(entry.thumbnailPath!);
      }
      byEntry[entry.id] = paths;
    }

    final report = scope.store.findOrphans(
      referencedPaths: referenced,
      pathsByEntry: byEntry,
    );
    _setBusy(null);
    if (!mounted) return;

    if (report.isClean) {
      _toast('Everything is accounted for.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Found some loose ends'),
        content: Text([
          if (report.filesWithoutRows.isNotEmpty)
            '${report.filesWithoutRows.length} file(s) on disk belong to no '
                'entry. These can be deleted to free space.',
          if (report.rowsWithoutFiles.isNotEmpty)
            '${report.rowsWithoutFiles.length} entr(ies) point at a file that '
                'is gone. Their notes and tags are shown but there is nothing '
                'to play — they are left alone here so you can decide.',
        ].join('\n\n')),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Leave it'),
          ),
          if (report.filesWithoutRows.isNotEmpty)
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete loose files'),
            ),
        ],
      ),
    );

    if (confirmed != true) return;
    for (final path in report.filesWithoutRows) {
      await scope.store.deleteRelative(path);
    }
    _toast('Freed ${report.filesWithoutRows.length} file(s).');
  }

  Future<void> _rebuildIndex() async {
    _setBusy('Rebuilding search index…');
    await AppScope.of(context).db.rebuildSearchIndex();
    _setBusy(null);
    _toast('Search index rebuilt.');
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          letterSpacing: 1.2,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
