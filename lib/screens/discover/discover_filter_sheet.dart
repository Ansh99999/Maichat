import 'package:flutter/material.dart';

import 'discover_controller.dart';

/// How a tag is being used in the current query.
enum _TagState { off, include, exclude }

/// Opens the filter sheet for [controller]: ordering, adult content and tags.
///
/// Nothing is applied until "Show results", so changing three things reloads the
/// feed once instead of three times.
Future<void> showDiscoverFilters(
  BuildContext context,
  DiscoverController controller,
) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _DiscoverFilterSheet(controller: controller),
    );

class _DiscoverFilterSheet extends StatefulWidget {
  const _DiscoverFilterSheet({required this.controller});

  final DiscoverController controller;

  @override
  State<_DiscoverFilterSheet> createState() => _DiscoverFilterSheetState();
}

class _DiscoverFilterSheetState extends State<_DiscoverFilterSheet> {
  late String _sort;
  late bool _nsfw;
  late Set<String> _include;
  late Set<String> _exclude;

  List<String> _suggestions = const <String>[];
  bool _loadingTags = true;
  String _tagFilter = '';

  static const int _shown = 40;

  @override
  void initState() {
    super.initState();
    final c = widget.controller;
    _sort = c.sort;
    _nsfw = c.nsfw;
    _include = c.includeTags.toSet();
    _exclude = c.excludeTags.toSet();
    _loadTags();
  }

  Future<void> _loadTags() async {
    final tags = await widget.controller.tagSuggestions();
    if (!mounted) return;
    setState(() {
      _suggestions = tags;
      _loadingTags = false;
    });
  }

  _TagState _stateOf(String tag) {
    if (_include.contains(tag)) return _TagState.include;
    if (_exclude.contains(tag)) return _TagState.exclude;
    return _TagState.off;
  }

  /// Off → include → exclude → off. Sources that cannot subtract a tag skip the
  /// middle step, so a tap is never a no-op.
  void _cycle(String tag) {
    final canExclude = widget.controller.source?.supportsTagExclusion ?? false;
    setState(() {
      switch (_stateOf(tag)) {
        case _TagState.off:
          _include.add(tag);
        case _TagState.include:
          _include.remove(tag);
          if (canExclude) _exclude.add(tag);
        case _TagState.exclude:
          _exclude.remove(tag);
      }
    });
  }

  void _apply() {
    widget.controller.applyFilters(
      sort: _sort,
      nsfw: _nsfw,
      include: _include.toList(growable: false),
      exclude: _exclude.toList(growable: false),
    );
    Navigator.of(context).pop();
  }

  void _reset() {
    setState(() {
      _include = <String>{};
      _exclude = <String>{};
      _tagFilter = '';
      final options = widget.controller.sortOptions;
      if (options.isNotEmpty) _sort = options.first.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final controller = widget.controller;
    final options = controller.sortOptions;
    // Chosen tags stay visible even when the search box excludes them.
    final chosen = <String>{..._include, ..._exclude};
    final matches = _suggestions
        .where((t) =>
            _tagFilter.isEmpty || t.toLowerCase().contains(_tagFilter))
        .take(_shown)
        .toList();
    final tags = <String>[...chosen, ...matches.where((t) => !chosen.contains(t))];

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 12, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Filters', style: theme.textTheme.titleLarge),
                  ),
                  TextButton(onPressed: _reset, child: const Text('Reset')),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                children: [
                  if (options.isNotEmpty) ...[
                    _SectionLabel('Sort by'),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final option in options)
                          ChoiceChip(
                            label: Text(option.label),
                            selected: option.value == _sort,
                            onSelected: (_) =>
                                setState(() => _sort = option.value),
                          ),
                      ],
                    ),
                    const SizedBox(height: 20),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Show adult content'),
                    subtitle: const Text('Includes NSFW and NSFL results'),
                    value: _nsfw,
                    onChanged: (value) => setState(() => _nsfw = value),
                  ),
                  const SizedBox(height: 12),
                  _SectionLabel('Tags'),
                  const SizedBox(height: 4),
                  Text(
                    controller.source?.supportsTagExclusion == true
                        ? 'Tap once to require a tag, twice to exclude it.'
                        : 'Tap a tag to require it.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (_suggestions.length > _shown)
                    TextField(
                      decoration: const InputDecoration(
                        isDense: true,
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Find a tag',
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (value) => setState(
                        () => _tagFilter = value.trim().toLowerCase(),
                      ),
                    ),
                  const SizedBox(height: 12),
                  if (_loadingTags)
                    const Center(
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else if (tags.isEmpty)
                    Text(
                      'This catalogue does not publish a tag list.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  else
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final tag in tags) _TagChip(
                          tag: tag,
                          state: _stateOf(tag),
                          onTap: () => _cycle(tag),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _apply,
                  child: const Text('Show results'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.tag,
    required this.state,
    required this.onTap,
  });

  final String tag;
  final _TagState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final excluded = state == _TagState.exclude;
    return FilterChip(
      label: Text(excluded ? '− $tag' : tag),
      selected: state != _TagState.off,
      selectedColor: excluded ? scheme.errorContainer : scheme.secondaryContainer,
      checkmarkColor: excluded ? scheme.onErrorContainer : null,
      showCheckmark: !excluded,
      onSelected: (_) => onTap(),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
      );
}
