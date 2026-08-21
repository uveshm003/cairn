/// Display helpers shared across screens.
///
/// Centralised so a duration or a byte count reads the same everywhere — a
/// library tile and a detail screen disagreeing about whether 90 seconds is
/// "1m 30s" or "1.5 min" is the kind of small inconsistency that makes an app
/// feel unfinished.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/database.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var value = bytes / 1024;
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  // Drop the decimal once the number is wide enough not to need it.
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}

/// Clock-style duration, for players and recording indicators.
String formatClock(int ms) {
  final total = (ms / 1000).round();
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

/// Prose duration, for lists and metadata.
String formatDuration(int ms) {
  final seconds = ms / 1000;
  if (seconds < 60) return '${seconds.round()}s';
  final minutes = seconds / 60;
  if (minutes < 60) {
    final whole = minutes.floor();
    final rest = (seconds % 60).round();
    return rest == 0 ? '${whole}m' : '${whole}m ${rest}s';
  }
  final hours = minutes ~/ 60;
  return '${hours}h ${(minutes % 60).round()}m';
}

/// Relative for recent entries, absolute once "3 days ago" stops being useful.
String formatWhen(DateTime when) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(when.year, when.month, when.day);
  final dayDelta = today.difference(that).inDays;

  final time = DateFormat.jm().format(when);
  if (dayDelta == 0) return 'Today, $time';
  if (dayDelta == 1) return 'Yesterday, $time';
  if (dayDelta < 7) return '${DateFormat.EEEE().format(when)}, $time';
  if (when.year == now.year) {
    return '${DateFormat.MMMd().format(when)}, $time';
  }
  return '${DateFormat.yMMMd().format(when)}, $time';
}

String formatDateOnly(DateTime when) => DateFormat.yMMMd().format(when);

/// The auto-title fallback from S6: `{Type} · {date} {time}`.
String autoTitle(String typeName, DateTime recordedAt) =>
    '$typeName · ${DateFormat.yMMMd().add_jm().format(recordedAt)}';

/// Resolves an entry's display title, falling back to the auto-title.
String displayTitle(EntryRow entry, String typeName) {
  final title = entry.title?.trim();
  if (title != null && title.isNotEmpty) return title;
  return autoTitle(typeName, entry.recordedAt);
}

/// Icon for a type's `iconKey`.
///
/// Keys rather than raw code points, so the icon survives being written to the
/// database and read back — and so an imported archive from a different build
/// cannot resolve to a garbage glyph.
IconData iconForKey(String key) => switch (key) {
      'bolt' => Icons.bolt_outlined,
      'book' => Icons.menu_book_outlined,
      'music' => Icons.music_note_outlined,
      'steps' => Icons.format_list_numbered,
      'shapes' => Icons.category_outlined,
      _ => Icons.circle_outlined,
    };

/// Accent colour for a type's `colorKey`. Deliberately muted: these are the only
/// saturated colours in the app, so they mark type without shouting (S14).
Color colorForKey(String key, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return switch (key) {
    'amber' => dark ? const Color(0xFFD9A441) : const Color(0xFFA97514),
    'indigo' => dark ? const Color(0xFF8C9EFF) : const Color(0xFF4A5BB5),
    'teal' => dark ? const Color(0xFF63C5B5) : const Color(0xFF17766A),
    'rose' => dark ? const Color(0xFFE288A0) : const Color(0xFFAE4665),
    'slate' => dark ? const Color(0xFF9FB0BA) : const Color(0xFF56676F),
    _ => dark ? const Color(0xFF9FB0BA) : const Color(0xFF56676F),
  };
}

IconData iconForMedium(Medium medium) =>
    medium == Medium.audio ? Icons.mic_none : Icons.videocam_outlined;
