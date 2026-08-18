import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Opens the "filter by tag" sheet over [tags], toggling membership of
/// [selected] in place and calling [onChanged] after every tap so the list
/// behind the sheet re-filters live.
///
/// The sheet is capped at three-quarters of the screen (a roster with hundreds
/// of imported tags used to fill the display top to bottom), shrinks to fit when
/// there are only a few tags, and offers a search box because a wall of chips is
/// not something you can read. Only [kTagsShown] chips are built for any one
/// query — the chosen ones always among them — so narrowing the search, not
/// scrolling, is how you reach a tag in a long tail.
Future<void> showTagFilterSheet(
  BuildContext context, {
  required List<String> tags,
  required Set<String> selected,
  required VoidCallback onChanged,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => TagFilterSheet(
        tags: tags,
        selected: selected,
        onChanged: onChanged,
      ),
    );

/// How many chips a single query renders.
const int kTagsShown = 50;

/// The body of [showTagFilterSheet], exposed for tests.
class TagFilterSheet extends StatefulWidget {
  const TagFilterSheet({
    super.key,
    required this.tags,
    required this.selected,
    required this.onChanged,
  });

  final List<String> tags;
  final Set<String> selected;
  final VoidCallback onChanged;

  @override
  State<TagFilterSheet> createState() => _TagFilterSheetState();
}

class _TagFilterSheetState extends State<TagFilterSheet> {
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);

    // Three-quarters of the screen is the ceiling, less the drag handle the
    // sheet stacks above this child, so the whole sheet lands on 75%. The
    // keyboard eats into it rather than pushing the sheet off the top.
    const handle = kMinInteractiveDimension;
    final ceiling = media.size.height * 0.75 - handle;
    final free = media.size.height -
        media.viewInsets.bottom -
        media.padding.top -
        handle;
    final maxHeight = math.max(200.0, math.min(ceiling, free));

    // Chosen tags stay listed even when the query would hide them, so a filter
    // can always be switched back off from here.
    final chosen = widget.tags.where(widget.selected.contains);
    final matches = widget.tags
        .where((t) => !widget.selected.contains(t))
        .where((t) => _query.isEmpty || t.toLowerCase().contains(_query));
    final shown = <String>[
      ...chosen,
      ...matches.take(math.max(0, kTagsShown - widget.selected.length)),
    ];
    final total = _query.isEmpty
        ? widget.tags.length
        : widget.tags
            .where((t) =>
                widget.selected.contains(t) || t.toLowerCase().contains(_query))
            .length;

    return ConstrainedBox(
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
                  child: Text('Filter by tag',
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
            child: SearchBar(
              controller: _search,
              hintText: 'Search tags',
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 14),
              ),
              leading: const Icon(Icons.search),
              trailing: [
                if (_query.isNotEmpty)
                  IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
              ],
              onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
            ),
          ),
          Flexible(
            child: shown.isEmpty
                ? Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    child: Text(
                      'No tag matches "${_search.text.trim()}".',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  )
                : ListView(
                    // Shrink-wrapped so a handful of tags makes a short sheet;
                    // the constraint above is what stops a long list growing
                    // past three quarters of the screen.
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final tag in shown)
                            FilterChip(
                              label: Text(tag),
                              selected: widget.selected.contains(tag),
                              onSelected: (on) => _toggle(tag, on),
                            ),
                        ],
                      ),
                      if (total > shown.length)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            'Showing ${shown.length} of $total tags — '
                            'search to narrow it down.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
          SizedBox(height: media.padding.bottom + 8),
        ],
      ),
    );
  }
}
