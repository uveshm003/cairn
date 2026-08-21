/// The Compression Lab — Milestone 1's harness.
///
/// Pick or record one clip, run all three rungs of the S8 ladder against it,
/// then read the table *and watch the outputs*. The table settles size, codec
/// and encode time; only playback settles whether 1.75 Mbps looks acceptable
/// for a talking-head note, which is the part no amount of arithmetic decides.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../widgets/player_sheet.dart';
import 'lab_capture_screen.dart';
import 'compression_runner.dart';
import '../../media/media_store.dart';
import '../../domain/encoding_profile.dart';
import '../widgets/formatting.dart';
import 'report.dart';

class LabScreen extends StatefulWidget {
  const LabScreen({super.key});

  @override
  State<LabScreen> createState() => _LabScreenState();
}

class _LabScreenState extends State<LabScreen> {
  MediaStore? _store;
  CompressionRunner? _runner;

  String? _sourcePath;
  String? _sourceLabel;

  LadderReport? _report;
  bool _running = false;
  EncodingProfile? _currentRung;
  double _progress = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    MediaStore.open().then((store) {
      if (!mounted) return;
      setState(() {
        _store = store;
        _runner = CompressionRunner(store);
      });
    });
  }

  Future<void> _recordInApp() async {
    final path = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const LabCaptureScreen()),
    );
    if (path == null || !mounted) return;
    setState(() {
      _sourcePath = path;
      _sourceLabel = 'in-app capture (camera plugin, ResolutionPreset.veryHigh ~1080p)';
      _report = null;
      _error = null;
    });
  }

  /// The only path that tests requirements.md S2's 300-500 MB claim: a clip the
  /// *native camera app* produced, at whatever bitrate the OEM chose.
  Future<void> _pickFromGallery() async {
    final file = await ImagePicker().pickVideo(source: ImageSource.gallery);
    if (file == null || !mounted) return;
    setState(() {
      _sourcePath = file.path;
      _sourceLabel = 'gallery pick (native camera app — tests the S2 baseline)';
      _report = null;
      _error = null;
    });
  }

  Future<void> _run() async {
    final runner = _runner;
    final source = _sourcePath;
    if (runner == null || source == null || _running) return;

    // Discard any previous run's outputs before starting a new one, so the
    // media dir does not accumulate three files per attempt.
    final previous = _report;
    if (previous != null) await runner.discardOutputs(previous);

    setState(() {
      _running = true;
      _report = null;
      _error = null;
      _progress = 0;
    });

    try {
      final report = await runner.run(
        source,
        onRungStart: (profile) {
          if (mounted) {
            setState(() {
              _currentRung = profile;
              _progress = 0;
            });
          }
        },
        onProgress: (profile, progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (!mounted) return;
      setState(() => _report = report);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _currentRung = null;
        });
      }
    }
  }

  Future<void> _copyReport() async {
    final report = _report;
    if (report == null) return;
    await Clipboard.setData(ClipboardData(
      text: buildMarkdownReport(report, sourceLabel: _sourceLabel),
    ));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Markdown report copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compression Lab'),
        actions: [
          if (_report != null)
            IconButton(
              icon: const Icon(Icons.copy_all),
              tooltip: 'Copy markdown report',
              onPressed: _copyReport,
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Milestone 1', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text(
                    'Runs the S8 ladder (Small / Balanced / High) over one clip '
                    'on this device. Bytes-out is arithmetic; what this actually '
                    'measures is whether HEVC hardware encode exists here, how '
                    'long it takes, and — once you play the outputs back — '
                    'whether the bitrates look good enough.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _running ? null : _recordInApp,
                  icon: const Icon(Icons.videocam),
                  label: const Text('Record in-app'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _running ? null : _pickFromGallery,
                  icon: const Icon(Icons.photo_library_outlined),
                  label: const Text('Pick a clip'),
                ),
              ),
            ],
          ),
          if (_sourceLabel != null) ...[
            const SizedBox(height: 12),
            Text('Source: $_sourceLabel', style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _sourcePath == null || _running ? null : _run,
            icon: const Icon(Icons.play_arrow),
            label: Text(_running ? 'Encoding…' : 'Run the ladder'),
          ),
          if (_running) ...[
            const SizedBox(height: 16),
            Text(
              _currentRung == null
                  ? 'Probing source…'
                  : '${_currentRung!.label} — '
                      '${(_progress * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: _progress == 0 ? null : _progress),
            const SizedBox(height: 8),
            Text(
              'Rungs run one at a time — parallel hardware encodes contend for '
              'the same encoder and come out slower.',
              style: theme.textTheme.bodySmall,
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          if (_report != null) ...[
            const SizedBox(height: 24),
            _SourceSummary(report: _report!),
            const SizedBox(height: 16),
            for (final rung in _report!.rungs)
              _RungCard(
                rung: rung,
                sourceDurationMs: _report!.source.durationMs,
                store: _store,
              ),
          ],
        ],
      ),
    );
  }
}

class _SourceSummary extends StatelessWidget {
  const _SourceSummary({required this.report});

  final LadderReport report;

  @override
  Widget build(BuildContext context) {
    final s = report.source;
    final theme = Theme.of(context);
    final per30s = s.durationMs == 0
        ? 0
        : (s.sizeBytes * (30000 / s.durationMs)).round();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Source', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('${s.width}x${s.height} · ${formatDuration(s.durationMs)} · '
                '${formatBytes(s.sizeBytes)} · ${s.bitrateKbps} kbps · '
                '${s.codec ?? 'codec n/r'} · '
                '${s.frameRate?.toStringAsFixed(1) ?? 'fps n/r'}'),
            const Divider(height: 24),
            Text('Scaled to 30 seconds: ${formatBytes(per30s)}',
                style: theme.textTheme.bodyMedium),
            const SizedBox(height: 4),
            Text(
              'requirements.md S2 claims 300–500 MB for 30s, which needs '
              '80–133 Mbps. Compare with the source bitrate above — this is the '
              'number that settles whether that claim can stay in the copy.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _RungCard extends StatelessWidget {
  const _RungCard({
    required this.rung,
    required this.sourceDurationMs,
    required this.store,
  });

  final RungResult rung;
  final int sourceDurationMs;
  final MediaStore? store;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = rung.profile;
    final result = rung.result;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('${profile.label} — ${profile.description}',
                      style: theme.textTheme.titleMedium),
                ),
                Text('${rung.encodeDuration.inMilliseconds}ms',
                    style: theme.textTheme.labelLarge),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'requested ${profile.videoBitrateKbps} kbps · '
              '≤${profile.maxHeight}p · predicted '
              '${formatBytes(profile.predictedVideoBytes(sourceDurationMs))}',
              style: theme.textTheme.bodySmall,
            ),
            const Divider(height: 20),
            if (rung.error != null)
              Text('Failed: ${rung.error}',
                  style: TextStyle(color: theme.colorScheme.error))
            else if (rung.integrityFailure != null)
              Text('Integrity check failed: ${rung.integrityFailure}\n'
                  'Output discarded, original untouched.',
                  style: TextStyle(color: theme.colorScheme.error))
            else if (rung.skipped)
              Text(
                'Skipped — compressing would have made this larger, so the '
                'plugin returned the original. Nothing was written and the '
                'source was left alone.',
                style: theme.textTheme.bodyMedium,
              )
            else if (result != null) ...[
              Text(
                '${formatBytes(result.compressedSizeBytes)} · '
                '${result.width}x${result.height} · '
                '${result.savedPercent.toStringAsFixed(1)}% saved',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _Chip(
                    label: result.codec,
                    // The finding that actually varies by OEM.
                    warn: !rung.gotHevc,
                    tooltip: rung.gotHevc
                        ? 'HEVC hardware encode available'
                        : 'HEVC unavailable — silently fell back to H.264',
                  ),
                  _Chip(
                      label: result.frameRate == null
                          ? 'fps n/r'
                          : '${result.frameRate!.toStringAsFixed(1)} fps'),
                  _Chip(
                      label: result.hasAudio == null
                          ? 'audio n/r'
                          : (result.hasAudio! ? 'has audio' : 'no audio')),
                ],
              ),
              if (rung.storedRelativePath != null) ...[
                const SizedBox(height: 12),
                Text('stored at ${rung.storedRelativePath}',
                    style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    final s = store;
                    if (s == null) return;
                    showPlayerSheet(
                      context,
                      absolutePath: s.resolve(rung.storedRelativePath!),
                      title: '${profile.label} — '
                          '${profile.videoBitrateKbps} kbps',
                    );
                  },
                  icon: const Icon(Icons.play_circle_outline),
                  label: const Text('Watch this output'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, this.warn = false, this.tooltip});

  final String label;
  final bool warn;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: warn ? scheme.errorContainer : scheme.surfaceContainerHighest,
      ),
      child: Text(
        warn ? '$label ⚠' : label,
        style: TextStyle(
          fontSize: 12,
          color: warn ? scheme.onErrorContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
    final t = tooltip;
    return t == null ? chip : Tooltip(message: t, child: chip);
  }
}
