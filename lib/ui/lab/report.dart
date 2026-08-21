/// Renders a [LadderReport] as markdown, so the numbers measured on a real
/// device can be copied out and pasted back into the requirements discussion.
///
/// This is the actual deliverable of Milestone 1. The spike cannot validate the
/// ladder by itself — it only produces the evidence.
library;

import 'dart:io';

import '../widgets/formatting.dart';
import 'compression_runner.dart';

String buildMarkdownReport(LadderReport report, {String? sourceLabel}) {
  final source = report.source;
  final buffer = StringBuffer()
    ..writeln('## Cairn — Milestone 1 compression measurement')
    ..writeln()
    ..writeln('- Platform: ${Platform.operatingSystem} '
        '${Platform.operatingSystemVersion}')
    ..writeln('- Source: ${sourceLabel ?? 'unknown'}')
    ..writeln('- Source video: ${source.width}x${source.height}, '
        '${formatDuration(source.durationMs)}, '
        '${formatBytes(source.sizeBytes)}, '
        '${source.bitrateKbps} kbps, '
        'codec ${source.codec ?? 'unreported'}, '
        'fps ${source.frameRate?.toStringAsFixed(1) ?? 'unreported'}')
    ..writeln();

  // Raw-bitrate sanity line. requirements.md S2 claims a 30s clip is
  // 300-500 MB, which implies 80-133 Mbps — no phone's standard encoder does
  // that. This line is what settles it for this device.
  final per30s = source.durationMs == 0
      ? 0
      : (source.sizeBytes * (30000 / source.durationMs)).round();
  buffer
    ..writeln('**Raw baseline check (S2).** At this source bitrate, 30 seconds '
        'of capture = ${formatBytes(per30s)}. '
        'requirements.md S2 claims 300-500 MB.')
    ..writeln();

  buffer
    ..writeln('| Profile | Target | Out | Predicted | Measured bitrate | '
        'Codec | fps | Audio | Encode | Saved |')
    ..writeln('|---|---|---|---|---|---|---|---|---|---|');

  for (final rung in report.rungs) {
    final p = rung.profile;
    final target = '${p.videoBitrateKbps} kbps / ${p.maxHeight}p';
    final result = rung.result;

    if (result == null) {
      buffer.writeln('| ${p.label} | $target | — | — | — | — | — | — | '
          '${rung.encodeDuration.inSeconds}s | **${rung.error}** |');
      continue;
    }
    if (rung.skipped) {
      buffer.writeln('| ${p.label} | $target | *skipped — source kept* | '
          '${formatBytes(p.predictedVideoBytes(source.durationMs))} | — | — | — | — | '
          '${rung.encodeDuration.inSeconds}s | none |');
      continue;
    }
    if (rung.integrityFailure != null) {
      buffer.writeln('| ${p.label} | $target | '
          '${formatBytes(result.compressedSizeBytes)} | — | — | ${result.codec} '
          '| — | — | ${rung.encodeDuration.inSeconds}s | '
          '**INTEGRITY: ${rung.integrityFailure}** |');
      continue;
    }

    final measuredKbps = result.durationMs == 0
        ? 0
        : (result.compressedSizeBytes * 8 / (result.durationMs / 1000) / 1000)
            .round();

    buffer.writeln('| ${p.label} '
        '| $target '
        '| ${formatBytes(result.compressedSizeBytes)} '
        '| ${formatBytes(p.predictedVideoBytes(result.durationMs))} '
        '| $measuredKbps kbps '
        '| ${result.codec}${rung.gotHevc ? '' : ' ⚠ fallback'} '
        '| ${result.frameRate?.toStringAsFixed(1) ?? 'n/r'} '
        '| ${result.hasAudio == null ? 'n/r' : (result.hasAudio! ? 'yes' : 'no')} '
        '| ${rung.encodeDuration.inSeconds}s '
        '| ${result.savedPercent.toStringAsFixed(1)}% |');
  }

  buffer
    ..writeln()
    ..writeln('### Notes')
    ..writeln();

  final anyFallback = report.rungs.any((r) => r.ok && !r.gotHevc);
  if (anyFallback) {
    buffer.writeln('- ⚠ **HEVC unavailable on this device** for at least one '
        'rung — the plugin fell back to H.264. Sizes will run larger than the '
        'S8 table, which assumes HEVC throughout.');
  } else if (report.rungs.any((r) => r.ok)) {
    buffer.writeln('- HEVC hardware encode confirmed working on this device.');
  }

  if (Platform.isAndroid) {
    buffer
      ..writeln('- Android ignores `frameRate` and `audioBitrateKbps` '
          '(Media3 exposes neither). The fps and audio-bitrate columns of the '
          'S8 table are therefore **not enforceable here** — audio bitrate has '
          'to be set at capture time instead.')
      ..writeln('- Predicted sizes above include the requested audio bitrate, '
          'so on Android they will read slightly low if the device AAC default '
          'is higher.');
  }

  // A zero-duration output would divide to Infinity here, and .round() throws
  // on that. The integrity check should already have rejected such a file, but
  // the report must not be the thing that crashes if it slips through.
  final scaled = report.rungs
      .where((r) => r.ok && r.result!.durationMs > 0)
      .map((r) {
        final tenMin =
            (r.result!.compressedSizeBytes * (600000 / r.result!.durationMs))
                .round();
        return '${r.profile.label}: ${formatBytes(tenMin)}';
      })
      .toList(growable: false);
  if (scaled.isNotEmpty) {
    buffer.writeln('- Extrapolated to a 10-minute clip: ${scaled.join(' · ')}. '
        'Compare against S8 (Small ~120-150 MB, Balanced ~250-300 MB, '
        'High ~400-450 MB).');
  }

  buffer.writeln('- Perceptual quality is **not** in this table. Play each '
      'output back before accepting the ladder.');

  return buffer.toString();
}
