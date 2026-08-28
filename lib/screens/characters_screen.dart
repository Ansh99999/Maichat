import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/character.dart';
import '../models/view_prefs.dart';
import '../services/character_codec.dart';
import '../services/character_sources.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/avatar_image.dart';
import '../widgets/character_avatar.dart';
import '../widgets/tag_filter_sheet.dart';
import 'character_actions.dart';
import 'character_edit_screen.dart';

/// How the roster is ordered.
enum CharacterSort {
  recent('Recently updated'),
  added('Recently added'),
  name('Name (A–Z)');

  const CharacterSort(this.label);
  final String label;
}

/// The Characters section: a search bar, sort / tag / view controls, a starred
/// shelf pinned above the rest, and per-character actions. Characters show as
/// an avatar grid or a names list; import, create and multi-select live in the
/// app bar.
class CharactersScreen extends StatefulWidget {
  const CharactersScreen({super.key});

  @override
  State<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends State<CharactersScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  CharacterSort _sort = CharacterSort.recent;
  final Set<String> _tagFilter = <String>{};
  bool _selecting = false;
  final Set<String> _selection = <String>{};

  /// Cards or rows, read live from the stored preference rather than mirrored in
  /// a field — the choice outlives the screen, so the screen must not own it.
  bool _avatarView(AppState state) =>
      state.browseLayout(BrowseSection.characters) == BrowseLayout.grid;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // --- filtering / sorting -------------------------------------------------

  /// Every tag across the roster, for the tag-filter sheet.
  List<String> _allTags(List<Character> characters) {
    final tags = <String>{};
    for (final c in characters) {
      tags.addAll(c.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  /// Applies the text query and tag filter, then the chosen sort.
  List<Character> _visible(List<Character> characters) {
    final q = _query.trim().toLowerCase();
    final result = characters.where((c) {
      if (_tagFilter.isNotEmpty &&
          !_tagFilter.every((t) => c.tags.contains(t))) {
        return false;
      }
      if (q.isEmpty) return true;
      return c.name.toLowerCase().contains(q) ||
          c.blurb.toLowerCase().contains(q) ||
          c.tags.any((t) => t.toLowerCase().contains(q));
    }).toList();

    switch (_sort) {
      case CharacterSort.recent:
        result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case CharacterSort.added:
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case CharacterSort.name:
        result.sort((a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
    }
    return result;
  }

  // --- selection -----------------------------------------------------------

  void _toggleSelect(String id) {
    setState(() {
      if (_selection.contains(id)) {
        _selection.remove(id);
      } else {
        _selection.add(id);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selection.clear();
      });

  Future<void> _deleteSelected(AppState state) async {
    if (_selection.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${_selection.length} character'
            '${_selection.length == 1 ? '' : 's'}?'),
        content: const Text('Existing chats with them are kept.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in _selection.toList()) {
      await state.deleteCharacter(id);
    }
    _exitSelection();
  }

  // --- create / import -----------------------------------------------------

  Future<void> _createNew() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const CharacterEditScreen()),
    );
  }

  void _showImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create new character'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _createNew();
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'IMPORT FROM',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
              ),
            ),
            for (final source in characterSources)
              ListTile(
                leading: Icon(source.icon),
                title: Text(source.label),
                subtitle: Text(source.description),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _runSource(source);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Collects any input the source needs, fetches, parses and stores the
  /// card(s). A file source may return several files, and a single JSON file
  /// may itself hold an array — both fan out into multiple characters.
  Future<void> _runSource(CharacterSource source) async {
    // Capture context-derived objects up front so nothing is read across the
    // input/fetch async gaps.
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);

    String input = '';
    if (source.inputKind != SourceInputKind.none) {
      final entered = await _promptForInput(source);
      if (entered == null) return; // cancelled
      input = entered;
    }

    try {
      final payloads = await source.fetch(input);
      if (payloads.isEmpty) return; // e.g. file picker cancelled
      final imported = <Character>[];
      String? firstError;
      for (final payload in payloads) {
        try {
          imported.addAll(
            CharacterCodec.parseCards(payload.bytes, filename: payload.filename),
          );
        } on CharacterParseException catch (e) {
          firstError ??= e.message;
        }
      }
      if (!mounted) return;
      if (imported.isEmpty) {
        messenger.showSnackBar(SnackBar(
          content: Text(firstError ?? 'Could not import that character.'),
        ));
        return;
      }
      await state.addCharacters(imported);
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(imported.length == 1
            ? 'Imported ${imported.single.displayName}.'
            : 'Imported ${imported.length} characters.'),
      ));
      if (imported.length == 1) openCharacterDetail(context, imported.single.id);
    } on CharacterParseException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not import that character.')),
      );
    }
  }

  /// A dialog that gathers the pasted text / URL a source asked for.
  Future<String?> _promptForInput(CharacterSource source) async {
    final controller = TextEditingController();
    final multiline = source.inputKind == SourceInputKind.text;
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(source.label),
        content: TextField(
          controller: controller,
          autofocus: false,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 10 : 1,
          keyboardType:
              multiline ? TextInputType.multiline : TextInputType.url,
          decoration: InputDecoration(
            hintText: source.inputHint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  // --- tag filter ----------------------------------------------------------

  void _showTagFilter(List<String> tags) {
    if (tags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tags on any character yet.')),
      );
      return;
    }
    showTagFilterSheet(
      context,
      tags: tags,
      selected: _tagFilter,
      onChanged: () => setState(() {}),
    );
  }
  // --- build ---------------------------------------------------------------

  void _onItemTap(AppState state, Character c) {
    if (_selecting) {
      _toggleSelect(c.id);
    } else {
      openCharacterDetail(context, c.id);
    }
  }

  void _onItemLongPress(Character c) {
    setState(() {
      _selecting = true;
      _selection.add(c.id);
    });
  }

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<CharacterSort>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in CharacterSort.values)
              ListTile(
                title: Text(s.label),
                trailing: _sort == s ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _sort = picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final all = state.characters;
    final tags = _allTags(all);
    final visible = _visible(all);
    final starred = visible.where((c) => c.starred).toList();
    final others = visible.where((c) => !c.starred).toList();
    final hasStar = starred.isNotEmpty;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      drawer: _selecting
          ? null
          : const AppDrawer(selected: DrawerSection.characters),
      appBar: _selecting ? _selectionAppBar(state) : _mainAppBar(),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _showImportSheet,
              icon: const Icon(Icons.add),
              label: const Text('Add'),
            ),
      // The search bar and controls ride at the top of the scroll view (not a
      // fixed header), so they scroll away as the roster is browsed.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _searchAndControls(state, tags)),
          if (all.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyRoster(onAdd: _showImportSheet),
            )
          else if (visible.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _NoMatches())
          else ...[
            if (hasStar) ...[
              _header('Starred'),
              _grid(state, starred),
            ],
            if (others.isNotEmpty) ...[
              if (hasStar) _header('All characters'),
              _grid(state, others),
            ],
            SliverToBoxAdapter(child: SizedBox(height: 96 + bottom)),
          ],
        ],
      ),
    );
  }

  AppBar _mainAppBar() => AppBar(
        title: const Text('Characters'),
        actions: [
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.download_outlined),
            onPressed: _showImportSheet,
          ),
          IconButton(
            tooltip: 'New character',
            icon: const Icon(Icons.person_add_alt_1_outlined),
            onPressed: _createNew,
          ),
          IconButton(
            tooltip: 'Select multiple',
            icon: const Icon(Icons.checklist_outlined),
            onPressed: () => setState(() => _selecting = true),
          ),
        ],
      );

  AppBar _selectionAppBar(AppState state) => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('${_selection.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Export selected',
            icon: const Icon(Icons.download_outlined),
            onPressed: _selection.isEmpty ? null : () => _exportSelected(state),
          ),
          IconButton(
            tooltip: 'Delete selected',
            icon: const Icon(Icons.delete_outline),
            onPressed: _selection.isEmpty ? null : () => _deleteSelected(state),
          ),
        ],
      );

  Future<void> _exportSelected(AppState state) async {
    final chosen =
        state.characters.where((c) => _selection.contains(c.id)).toList();
    if (chosen.isEmpty) return;
    await exportCharacters(context, chosen);
  }

  Widget _searchAndControls(AppState state, List<String> tags) {
    final avatarView = _avatarView(state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        children: [
          SearchBar(
            controller: _search,
            hintText: 'Search characters',
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 14),
            ),
            leading: const Icon(Icons.search),
            trailing: [
              if (_query.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
            ],
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _ControlChip(
                icon: Icons.sort,
                label: _sort.label,
                onTap: _pickSort,
              ),
              const SizedBox(width: 8),
              _ControlChip(
                icon: Icons.label_outline,
                label: _tagFilter.isEmpty
                    ? 'Tags'
                    : '${_tagFilter.length} tag${_tagFilter.length == 1 ? '' : 's'}',
                selected: _tagFilter.isNotEmpty,
                onTap: () => _showTagFilter(tags),
              ),
              const Spacer(),
              IconButton(
                tooltip: avatarView ? 'Show as list' : 'Show as grid',
                icon: Icon(avatarView
                    ? Icons.view_list_outlined
                    : Icons.grid_view_outlined),
                onPressed: () => state.setBrowseLayout(
                  BrowseSection.characters,
                  avatarView ? BrowseLayout.list : BrowseLayout.grid,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header(String text) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      );

  Widget _grid(AppState state, List<Character> list) {
    void tap(Character c) => _onItemTap(state, c);
    void long(Character c) => _onItemLongPress(c);

    if (_avatarView(state)) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.66,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) => _CharacterCard(
            character: list[i],
            selecting: _selecting,
            selected: _selection.contains(list[i].id),
            onTap: () => tap(list[i]),
            onLongPress: () => long(list[i]),
            onToggleStar: () => state.toggleCharacterStar(list[i].id),
            onAction: (a) => runCharacterAction(context, state, list[i], a),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      sliver: SliverList.builder(
        itemCount: list.length,
        itemBuilder: (context, i) => _CharacterTile(
          character: list[i],
          selecting: _selecting,
          selected: _selection.contains(list[i].id),
          onTap: () => tap(list[i]),
          onLongPress: () => long(list[i]),
          onToggleStar: () => state.toggleCharacterStar(list[i].id),
          onAction: (a) => runCharacterAction(context, state, list[i], a),
        ),
      ),
    );
  }
}
// APPEND-MARKER-3

/// A small pill button used for the sort and tag controls under the search bar.
class _ControlChip extends StatelessWidget {
  const _ControlChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(
        icon,
        size: 18,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
      label: Text(label),
      backgroundColor: selected ? scheme.secondaryContainer : null,
      side: selected ? BorderSide.none : null,
      onPressed: onTap,
    );
  }
}

/// A character in the avatar grid: the picture up top, and a card-like slot
/// beneath it carrying the name (with the 3-dot actions menu) and description.
class _CharacterCard extends StatelessWidget {
  const _CharacterCard({
    required this.character,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleStar,
    required this.onAction,
  });

  final Character character;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleStar;
  final ValueChanged<CharacterAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blurb = character.blurb;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _CardImage(character: character),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: _GlassIcon(
                      icon: character.starred ? Icons.star : Icons.star_border,
                      color: character.starred ? Colors.amber : null,
                      onTap: onToggleStar,
                    ),
                  ),
                  if (selecting)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                ],
              ),
            ),
            // The name/description slot sits on a distinct, slightly stronger
            // surface so it reads as a label attached under the avatar.
            Container(
              width: double.infinity,
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          character.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          blurb.isEmpty ? 'No description' : blurb,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (!selecting)
                    SizedBox(
                      width: 32,
                      child: PopupMenuButton<CharacterAction>(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: 'Actions',
                        onSelected: onAction,
                        itemBuilder: (context) => characterMenuItems(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture area of a [_CharacterCard]: the character's image cropped to
/// fill, or a tinted monogram panel when there is none / it fails to load.
class _CardImage extends StatelessWidget {
  const _CardImage({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget fallback() => Container(
          color: scheme.secondaryContainer,
          alignment: Alignment.center,
          child: Text(
            character.displayName.isEmpty
                ? '?'
                : character.displayName.characters.first.toUpperCase(),
            style: TextStyle(
              fontSize: 44,
              fontWeight: FontWeight.w600,
              color: scheme.onSecondaryContainer,
            ),
          ),
        );

    // Shared provider: decoded once, at card size, however many cards show it.
    final provider = avatarImage(
      character.avatar,
      displaySize: 320,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return fallback();
    return Image(
      image: provider,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback(),
    );
  }
}

/// A translucent, tappable circular icon that floats over the card image
/// (used for the star toggle).
class _GlassIcon extends StatelessWidget {
  const _GlassIcon({required this.icon, required this.onTap, this.color});

  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.72),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 18, color: color ?? scheme.onSurface),
        ),
      ),
    );
  }
}

/// A character in the names list: avatar, name (+ star), description and the
/// 3-dot actions menu.
class _CharacterTile extends StatelessWidget {
  const _CharacterTile({
    required this.character,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleStar,
    required this.onAction,
  });

  final Character character;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleStar;
  final ValueChanged<CharacterAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final blurb = character.blurb;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: selecting
            ? Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            : CharacterAvatar(character: character, radius: 22),
        title: Text(
          character.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: blurb.isEmpty
            ? null
            : Text(blurb, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: character.starred ? 'Unstar' : 'Star',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      character.starred ? Icons.star : Icons.star_border,
                      color: character.starred ? Colors.amber : null,
                    ),
                    onPressed: onToggleStar,
                  ),
                  PopupMenuButton<CharacterAction>(
                    tooltip: 'Actions',
                    icon: const Icon(Icons.more_vert),
                    onSelected: onAction,
                    itemBuilder: (context) => characterMenuItems(),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Shown when there are no characters at all — a friendly nudge to add one.
class _EmptyRoster extends StatelessWidget {
  const _EmptyRoster({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.people_alt_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No characters yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Create one, or import a SillyTavern / Agnai card — a .json, a '
              'PNG card, a link, or a JannyAI download.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a character'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a search / tag filter matches nothing.
class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No characters match your search.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

