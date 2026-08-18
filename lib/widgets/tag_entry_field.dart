import 'package:flutter/material.dart';

/// A tag field: type, press enter or comma, get a chip.
///
/// Tags are the only way to find one picture among hundreds, so entering them has
/// to be quick — commas commit, so does leaving the field, and a chip can be
/// removed with one tap. Mirrors Agnai's `TagEntry`, which is the behaviour a user
/// coming from there will expect.
class TagEntryField extends StatefulWidget {
  const TagEntryField({
    super.key,
    required this.tags,
    required this.onChanged,
    this.label = 'Tags',
    this.hint = 'e.g. beach, swimsuit, smile',
  });

  /// The tags so far; the field never mutates this list, it hands back a new one.
  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final String label;
  final String hint;

  @override
  State<TagEntryField> createState() => _TagEntryFieldState();
}

class _TagEntryFieldState extends State<TagEntryField> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Leaving the field commits what was typed, so a half-entered tag is not
    // silently lost when the user reaches for Save.
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final parts = _controller.text
        .split(',')
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty);
    if (parts.isEmpty) {
      if (_controller.text.isNotEmpty) _controller.clear();
      return;
    }
    final next = <String>[...widget.tags];
    for (final tag in parts) {
      // Case-insensitive de-dupe: "Beach" and "beach" are one tag, and the first
      // spelling wins so the filter sheet does not list both.
      if (next.any((t) => t.toLowerCase() == tag.toLowerCase())) continue;
      next.add(tag);
    }
    _controller.clear();
    widget.onChanged(next);
  }

  void _remove(String tag) =>
      widget.onChanged(widget.tags.where((t) => t != tag).toList());

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _controller,
          focusNode: _focus,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            helperText: 'Separate several with commas',
            border: const OutlineInputBorder(),
            suffixIcon: IconButton(
              tooltip: 'Add tag',
              icon: const Icon(Icons.add),
              onPressed: _commit,
            ),
          ),
          onChanged: (value) {
            // A typed comma commits immediately, so a list can be entered in one
            // breath without reaching for the keyboard's action key.
            if (value.endsWith(',')) _commit();
          },
          onSubmitted: (_) => _commit(),
        ),
        if (widget.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final tag in widget.tags)
                  InputChip(
                    label: Text(tag),
                    onDeleted: () => _remove(tag),
                    deleteIcon: const Icon(Icons.close, size: 16),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'No tags yet',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}
