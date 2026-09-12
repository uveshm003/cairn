/// Review & save (requirements.md S13): preview, metadata, compression
/// progress, save or discard.
///
/// Compression runs here rather than at capture time, off the UI thread and with
/// a cancel (S8: "compress off the UI thread, after recording... never block
/// capture"). The user can be typing a title while the encoder works.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_compress/flutter_compress.dart' show CancellationToken;

import '../../app.dart';
import '../../data/database.dart';
import '../../domain/encoding_profile.dart';
import '../../domain/recording_markers.dart';
import '../../media/save_pipeline.dart';
import '../../services/location_service.dart';
import '../widgets/formatting.dart';
import '../widgets/marker_review.dart';
import '../widgets/media_preview.dart';
import '../widgets/tag_editor.dart';
import 'capture_flow.dart';

class ReviewScreen extends StatefulWidget {
  const ReviewScreen({
    super.key,
    required this.sourcePath,
    required this.medium,
    required this.type,
    required this.durationMs,
    this.markerOffsetsMs = const [],
    this.amplitudeEnvelope,
  });

  final String sourcePath;
  final Medium medium;
  final EntryTypeRow type;
  final int durationMs;

  /// Raw stopwatch offsets from capture, still unclamped. They are normalized
  /// against the *stored* file's duration at save time, not here -- that
  /// duration is not known until the encode finishes.
  final List<int> markerOffsetsMs;

  /// Collected during capture; null for video and for audio recorded before
  /// the envelope existed.
  final Uint8List? amplitudeEnvelope;

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen> {
  final _titleController = TextEditingController();
  final _noteController = TextEditingController();

  /// A working copy, so removing a stray marker here does not require going
  /// back and re-recording. Only committed on save.
  late final List<int> _markerOffsets = List.of(widget.markerOffsetsMs);

  late EntryTypeRow _type = widget.type;
  List<String> _tagNames = [];

  SaveProgress? _progress;
  bool _saving = false;
  bool _discarded = false;
  String? _error;
  CancellationToken? _token;

  @override
  void dispose() {
    _titleController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  EncodingProfile get _profile {
    final override = AppScope.of(context).settings.profileOverride.value;
    return EncodingProfile.of(override ?? _type.encodingProfile);
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });

    final scope = AppScope.of(context);
    final token = CancellationToken();
    _token = token;

    SavedMedia? media;
    try {
      media = widget.medium == Medium.video
          ? await scope.pipeline.saveVideo(
              sourcePath: widget.sourcePath,
              profile: _profile,
              keepOriginal: scope.settings.keepOriginals.value,
              cancellationToken: token,
              onProgress: (p) {
                if (mounted) setState(() => _progress = p);
              },
            )
          : await scope.pipeline.saveAudio(
              sourcePath: widget.sourcePath,
              durationMs: widget.durationMs,
              onProgress: (p) {
                if (mounted) setState(() => _progress = p);
              },
            );

      // Tags are resolved after the media is safely stored, so a typo in a tag
      // name cannot cost the user their recording.
      final tagIds = <int>[];
      for (final name in _tagNames) {
        final tag = await scope.db.ensureTag(name);
        tagIds.add(tag.id);
      }

      // Only asks for a fix -- and only asks for the permission -- when the
      // user has turned location on (S5: off by default). A null result is
      // normal and saves without coordinates.
      final coordinates = await LocationService.tryFix(
        enabled: scope.settings.locationEnabled.value,
      );

      final now = DateTime.now();
      final title = _titleController.text.trim();
      final note = _noteController.text.trim();

      await scope.db.createEntry(
        EntriesCompanion.insert(
          // Left null rather than filled with the auto-title: storing the
          // fallback would make it look like the user chose it, and would go
          // stale if the type were renamed. It is computed at display time.
          title: Value(title.isEmpty ? null : title),
          note: Value(note.isEmpty ? null : note),
          medium: widget.medium,
          typeId: _type.id,
          filePath: media.relativePath,
          thumbnailPath: Value(media.thumbnailRelativePath),
          durationMs: media.durationMs,
          fileSizeBytes: media.fileSizeBytes,
          originalSizeBytes: Value(media.originalSizeBytes),
          createdAt: now,
          updatedAt: now,
          recordedAt: now,
          width: Value(media.width),
          height: Value(media.height),
          codec: Value(media.codec),
          bitrateKbps: Value(media.bitrateKbps),
          latitude: Value(coordinates?.latitude),
          longitude: Value(coordinates?.longitude),
          amplitudeEnvelope: Value(widget.amplitudeEnvelope),
        ),
        tagIds: tagIds,
        // Clamped against the *encoded* duration, not the stopwatch: the two
        // can differ (which is why the pipeline measures the output at all),
        // and a marker past the end of the file seeks nowhere.
        markerOffsetsMs: normalizeMarkers(
          _markerOffsets,
          durationMs: media.durationMs,
        ),
      );

      await scope.settings.noteEntryAdded();
      if (mounted) Navigator.of(context).pop(true);
    } on IntegrityException catch (e) {
      // S6: reject the save if the encode fails its integrity check. The
      // recording itself is untouched, so the user can try again.
      await _reportFailure('That file did not come out right — ${e.reason}. '
          'Your recording is still here, so you can try saving again.');
    } catch (e) {
      // If the media was stored but the row failed, the file would be an
      // orphan. Clean it up rather than leaving it to the sweep.
      if (media != null) {
        await scope.store.deleteRelative(media.relativePath);
        await scope.store.deleteRelative(media.thumbnailRelativePath);
      }
      await _reportFailure('Could not save: $e');
    }
  }

  Future<void> _reportFailure(String message) async {
    if (!mounted) return;
    setState(() {
      _saving = false;
      _progress = null;
      _error = message;
    });
  }

  Future<void> _discard() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard this recording?'),
        content: const Text('It will not be saved anywhere.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _discarded = true;
    await _token?.cancel();
    // The source is a temp/capture file that no row references, so deleting it
    // here is the whole cleanup.
    await File(widget.sourcePath).delete().catchError((_) {
      return File(widget.sourcePath);
    });
    if (mounted) Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final predicted = widget.medium == Medium.video
        ? _profile.predictedVideoBytes(widget.durationMs)
        : _profile.predictedAudioBytes(widget.durationMs);

    return PopScope(
      // Backing out silently would leave the capture file behind with no row,
      // so the discard path is the only way out.
      canPop: _discarded,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_saving) _discard();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Save entry'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: _saving ? null : _discard,
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 120),
          children: [
            MediaPreview(
              path: widget.sourcePath,
              medium: widget.medium,
              durationMs: widget.durationMs,
            ),
            // Only present when the user actually dropped markers, so the
            // screen does not grow a section explaining a feature they did not
            // use during this take.
            if (_markerOffsets.isNotEmpty) ...[
              const SizedBox(height: 16),
              MarkerReview(
                offsetsMs: _markerOffsets,
                enabled: !_saving,
                onRemove: (offset) =>
                    setState(() => _markerOffsets.remove(offset)),
              ),
            ],
            const SizedBox(height: 20),
            TextField(
              controller: _titleController,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                labelText: 'Title',
                hintText: autoTitle(_type.name, DateTime.now()),
                helperText: 'Optional — a date and type is used if you skip it.',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _noteController,
              minLines: 3,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Note',
                alignLabelWithHint: true,
                helperText: 'Searchable later.',
              ),
            ),
            const SizedBox(height: 20),
            TagEditor(
              selected: _tagNames,
              onChanged: (tags) => setState(() => _tagNames = tags),
            ),
            const SizedBox(height: 20),
            _TypeRow(
              type: _type,
              enabled: !_saving,
              onChange: () async {
                final picked = await showTypePicker(
                  context,
                  current: _type,
                  forMedium: widget.medium,
                );
                if (picked != null && mounted) setState(() => _type = picked);
              },
            ),
            const SizedBox(height: 12),
            _SizeEstimate(
              predictedBytes: predicted,
              profile: _profile,
              medium: widget.medium,
            ),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ],
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: _saving
                ? _SavingBar(
                    progress: _progress,
                    onCancel: () async {
                      await _token?.cancel();
                      if (mounted) {
                        setState(() {
                          _saving = false;
                          _progress = null;
                        });
                      }
                    },
                  )
                : Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: _discard,
                          child: const Text('Discard'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: FilledButton.icon(
                          onPressed: _save,
                          icon: const Icon(Icons.check),
                          label: const Text('Save'),
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _TypeRow extends StatelessWidget {
  const _TypeRow({
    required this.type,
    required this.enabled,
    required this.onChange,
  });

  final EntryTypeRow type;
  final bool enabled;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = colorForKey(type.colorKey, theme.brightness);
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        enabled: enabled,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        leading: Icon(iconForKey(type.iconKey), color: accent),
        title: Text(type.name),
        subtitle: const Text('Type'),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled ? onChange : null,
      ),
    );
  }
}

/// S8 wants the "space saved" delta surfaced. Before the encode has run there is
/// nothing measured yet, so this is explicitly an estimate — and for audio it is
/// exact, because constant-bitrate AAC has no hardware variance.
class _SizeEstimate extends StatelessWidget {
  const _SizeEstimate({
    required this.predictedBytes,
    required this.profile,
    required this.medium,
  });

  final int predictedBytes;
  final EncodingProfile profile;
  final Medium medium;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Icon(Icons.compress,
            size: 16, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            medium == Medium.video
                ? '${profile.label} profile — about '
                    '${formatBytes(predictedBytes)} after compressing'
                : '${profile.label} profile — '
                    '${formatBytes(predictedBytes)} at '
                    '${profile.audioBitrateKbps} kbps',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}

class _SavingBar extends StatelessWidget {
  const _SavingBar({required this.progress, required this.onCancel});

  final SaveProgress? progress;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final stage = progress?.stage ?? SaveStage.probing;
    final fraction = progress?.fraction;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                fraction == null
                    ? stage.label
                    : '${stage.label} — ${(fraction * 100).round()}%',
                style: theme.textTheme.bodyMedium,
              ),
            ),
            TextButton(onPressed: onCancel, child: const Text('Cancel')),
          ],
        ),
        const SizedBox(height: 8),
        // Indeterminate for the stages the platform cannot report on, rather
        // than a fake animation that implies progress it does not know about.
        LinearProgressIndicator(value: fraction),
      ],
    );
  }
}
