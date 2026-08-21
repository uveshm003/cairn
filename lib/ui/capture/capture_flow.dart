/// Entry point into capture, plus the type picker.
///
/// S5 is strict about this: "cold-start to recording in <=2 taps." So the FAB
/// goes *straight* to the capture screen with the last-used type already
/// selected — tap one is the FAB, tap two is the record button. Choosing a type
/// is an optional detour from inside capture, not a gate in front of it (S13:
/// "pick type (remembers last)").
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';
import '../widgets/formatting.dart';
import 'capture_screen.dart';

Future<void> startCapture(BuildContext context) async {
  final scope = AppScope.of(context);
  final types = await scope.db.allTypes();
  if (types.isEmpty || !context.mounted) return;

  final preferredId = scope.settings.defaultTypeId.value;
  final type = types.firstWhere(
    (t) => t.id == preferredId,
    orElse: () => types.first,
  );

  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => CaptureScreen(initialType: type)),
  );
}

/// Type picker, shown from inside capture when the user wants a different one.
Future<EntryTypeRow?> showTypePicker(
  BuildContext context, {
  required EntryTypeRow current,
  Medium? forMedium,
}) async {
  final db = AppScope.of(context).db;
  final types = await db.allTypes();
  if (!context.mounted) return null;

  return showModalBottomSheet<EntryTypeRow>(
    context: context,
    useSafeArea: true,
    builder: (context) {
      final theme = Theme.of(context);
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Entry type', style: theme.textTheme.titleLarge),
                  ),
                ],
              ),
            ),
            for (final type in types)
              _TypeOption(
                type: type,
                selected: type.id == current.id,
                // A video-only type cannot take an audio recording (S6), so it
                // is shown greyed rather than hidden -- hiding it would leave
                // the user wondering where How-to went.
                enabled: forMedium == null || _allows(type, forMedium),
                onTap: () => Navigator.of(context).pop(type),
              ),
            const SizedBox(height: 12),
          ],
        ),
      );
    },
  );
}

bool _allows(EntryTypeRow type, Medium medium) => switch (type.allowedMedium) {
      AllowedMedium.both => true,
      AllowedMedium.audioOnly => medium == Medium.audio,
      AllowedMedium.videoOnly => medium == Medium.video,
    };

/// Whether a type accepts this medium. Exported for the capture screen.
bool typeAllowsMedium(EntryTypeRow type, Medium medium) =>
    _allows(type, medium);

class _TypeOption extends StatelessWidget {
  const _TypeOption({
    required this.type,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final EntryTypeRow type;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = colorForKey(type.colorKey, theme.brightness);

    return ListTile(
      enabled: enabled,
      leading: Icon(iconForKey(type.iconKey), color: enabled ? accent : null),
      title: Text(type.name),
      subtitle: Text(
        enabled
            ? 'Up to ${formatDuration(type.maxDurationMs)}'
            : 'Video only',
      ),
      trailing: selected ? const Icon(Icons.check) : null,
      onTap: enabled ? onTap : null,
    );
  }
}
