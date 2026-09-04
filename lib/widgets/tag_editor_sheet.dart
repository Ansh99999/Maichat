import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Opens the tag engine over [known], toggling membership of [selected] in place
/// and calling [onChanged] after every tap so whatever is behind the sheet
/// updates live.
///
/// The sibling of the tag *filter* sheet, and deliberately the same window: this
/// is where you already go to pick tags, so picking the tags a character *has*
/// should not be a different place with different manners. The one difference is
/// that this one can invent a tag — typing a word nobody has used yet offers to
/// add it, because a new character is exactly where a new tag comes from.
Future<void> showTagEditorSheet(
  BuildContext context, {
  required List<String> known,
  required Set<String> selected,
  required VoidCallback onChanged,
  String title = 'Tags',
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TagEditorSheet(
        known: known,
        selected: selected,
        onChanged: onChanged,
        title: title,
      ),
    );

/// How many chips one query renders. A roster of imported cards can carry
/// thousands of tags; narrowing the search, not scrolling, is how you reach one.
const int kTagsOffered = 60;

/// The body of [showTagEditorSheet], exposed for tests.
class TagEditorSheet extends StatefulWidget {
  const TagEditorSheet({
    super.key,
    required this.known,
    required this.selected,
    required this.onChanged,
    this.title = 'Tags',
  });

  /// Every tag already in use anywhere, for picking rather than retyping.
  final List<String> known;

  /// The tags on the thing being edited. Mutated in place.
  final Set<String> selected;

  final VoidCallback onChanged;
  final String title;

  @override
  State<TagEditorSheet> createState() => _TagEditorSheetState();
}

class _TagEditorSheetState extends State<TagEditorSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _toggle(String tag, bool on) {
    setState(() {
      if (on) {
        widget.selected.add(tag);
      } else {
        widget.selected.remove(tag);
      }
    });
    widget.onChanged();
  }

  /// Whether the typed word is a tag nobody has yet — the case the "Add" row is
  /// for. Compared case-insensitively against both lists, so "Sci-Fi" does not
  /// offer to be added beside "sci-fi".
  bool get _isNew {
    final typed = _search.text.trim();
    if (typed.isEmpty) return false;
    final needle = typed.toLowerCase();
    return !widget.selected.any((t) => t.toLowerCase() == needle) &&
        !widget.known.any((t) => t.toLowerCase() == needle);
  }

  void _addTyped() {
    final typed = _search.text.trim();
    if (typed.isEmpty) return;
    _toggle(typed, true);
    _search.clear();
    setState(() => _query = '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    // Three-quarters of the screen is the ceiling, less the drag handle the sheet
    // stacks above this child. The keyboard eats into it rather than pushing the
    // sheet off the top — this one is typed into, so that matters more here than
    // it does on the filter sheet.
    const handle = kMinInteractiveDimension;
    final ceiling = media.size.height * 0.75 - handle;
    final free =
        media.size.height - media.viewInsets.bottom - media.padding.top - handle;
    final maxHeight = math.max(200.0, math.min(ceiling, free));

    final chosen = widget.selected.toList()..sort();
    final matches = widget.known
        .where((t) => !widget.selected.contains(t))
        .where((t) => _query.isEmpty || t.toLowerCase().contains(_query))
        .take(math.max(0, kTagsOffered - chosen.length))
        .toList();

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.title,
                        style: theme.textTheme.titleMedium),
                  ),
                  if (widget.selected.isNotEmpty)
                    TextButton(
                      onPressed: () {
                        setState(widget.selected.clear);
                        widget.onChanged();
                      },
                      child: const Text('Clear'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: TextField(
                key: const Key('tag-editor-search'),
                controller: _search,
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.none,
                decoration: InputDecoration(
                  hintText: 'Search or write a tag',
                  prefixIcon: const Icon(Icons.search),
                  isDense: true,
                  border: const OutlineInputBorder(),
                  suffixIcon: _search.text.trim().isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Clear',
                          icon: const Icon(Icons.close),
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                ),
                onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                onSubmitted: (_) {
                  if (_isNew) _addTyped();
                },
              ),
            ),
            if (_isNew)
              ListTile(
                key: const Key('tag-editor-add'),
                dense: true,
                leading: const Icon(Icons.add),
                title: Text('Add "${_search.text.trim()}"'),
                onTap: _addTyped,
              ),
            Flexible(
              child: ListView(
                // Shrink-wrapped so a handful of tags makes a short sheet; the
                // constraint above is what stops a long list running past three
                // quarters of the screen.
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                children: [
                  if (chosen.isEmpty && matches.isEmpty && !_isNew)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        _query.isEmpty
                            ? 'No tags yet — write one above.'
                            : 'No tag matches that. Type it out to add it.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      // Chosen tags stay listed whatever the query says, so a tag
                      // can always be taken off again from here.
                      for (final tag in chosen)
                        InputChip(
                          label: Text(tag),
                          selected: true,
                          onSelected: (_) => _toggle(tag, false),
                          onDeleted: () => _toggle(tag, false),
                        ),
                      for (final tag in matches)
                        FilterChip(
                          label: Text(tag),
                          selected: false,
                          onSelected: (on) => _toggle(tag, on),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: media.padding.bottom + 8),
          ],
        ),
      ),
    );
  }
}
