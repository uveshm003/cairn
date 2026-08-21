/// Tag entry, used on review and on entry detail.
///
/// S3 sets the bar: "organization must be cheap (type + tags applied in
/// seconds)". So this shows existing tags as one-tap chips and only falls back
/// to typing for a genuinely new one. Tags are held as *names* rather than ids
/// while editing, because a tag the user is inventing has no id yet — it is
/// resolved to a row on save via `ensureTag`, which also collapses
/// case-variants.
library;

import 'package:flutter/material.dart';

import '../../app.dart';
import '../../data/database.dart';

class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.selected,
    required this.onChanged,
  });

  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  bool _adding = false;

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  bool _isSelected(String name) => widget.selected
      .any((s) => s.toLowerCase() == name.toLowerCase());

  void _toggle(String name) {
    final next = widget.selected.toList();
    final existing = next.indexWhere(
      (s) => s.toLowerCase() == name.toLowerCase(),
    );
    if (existing >= 0) {
      next.removeAt(existing);
    } else {
      next.add(name);
    }
    widget.onChanged(next);
  }

  void _commitTyped() {
    final raw = _controller.text.trim();
    _controller.clear();
    if (raw.isEmpty) {
      setState(() => _adding = false);
      return;
    }
    // Comma-separated entry, so "guitar, scales" in one go does the obvious
    // thing rather than creating one oddly-named tag.
    final parts = raw
        .split(',')
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList();

    final next = widget.selected.toList();
    for (final part in parts) {
      if (!next.any((s) => s.toLowerCase() == part.toLowerCase())) {
        next.add(part);
      }
    }
    widget.onChanged(next);
    setState(() {});
    // Keep focus so several tags can be added in a row without re-tapping.
    _focus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final db = AppScope.of(context).db;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'TAGS',
          style: theme.textTheme.labelSmall?.copyWith(
            letterSpacing: 1.1,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        StreamBuilder<List<TagRow>>(
          stream: db.watchTags(),
          builder: (context, snapshot) {
            final existing = snapshot.data ?? const <TagRow>[];
            // Names the user typed that are not yet rows, so a brand-new tag
            // still shows as a selected chip before it is saved.
            final unsaved = widget.selected.where(
              (name) => !existing.any(
                (tag) => tag.name.toLowerCase() == name.toLowerCase(),
              ),
            );

            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in existing)
                  FilterChip(
                    label: Text(tag.name),
                    selected: _isSelected(tag.name),
                    onSelected: (_) => _toggle(tag.name),
                  ),
                for (final name in unsaved)
                  FilterChip(
                    label: Text(name),
                    selected: true,
                    avatar: const Icon(Icons.add, size: 14),
                    onSelected: (_) => _toggle(name),
                  ),
                if (_adding)
                  SizedBox(
                    width: 160,
                    child: TextField(
                      controller: _controller,
                      focusNode: _focus,
                      autofocus: true,
                      textInputAction: TextInputAction.done,
                      textCapitalization: TextCapitalization.none,
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'New tag',
                      ),
                      onSubmitted: (_) => _commitTyped(),
                      onTapOutside: (_) => _commitTyped(),
                    ),
                  )
                else
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 16),
                    label: const Text('Add'),
                    onPressed: () => setState(() => _adding = true),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
