import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/chat_interface.dart';
import '../../models/folder.dart';
import '../../models/view_prefs.dart';
import '../../services/folder_io.dart';
import '../../state/app_state.dart';
import '../../widgets/character_avatar.dart';
import '../../widgets/tag_filter_sheet.dart';
import '../chat_screen.dart';

/// The character roster scoped to one folder and tinted with its seed colour.
class FolderHomeScreen extends StatefulWidget {
  const FolderHomeScreen({super.key, required this.folderId});

  final String folderId;

  @override
  State<FolderHomeScreen> createState() => _FolderHomeScreenState();
}

class _FolderHomeScreenState extends State<FolderHomeScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _tagFilter = <String>{};
  final Set<String> _selection = <String>{};
  String _query = '';
  bool _selecting = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _grid(AppState state) =>
      state.browseLayout(BrowseSection.folders) == BrowseLayout.grid;

  List<Character> _characters(AppState state, Folder folder) =>
      <Character>[
        for (final id in folder.characterIds) ?state.characterById(id),
      ].where((character) {
        final q = _query.trim().toLowerCase();
        final matchesQuery =
            q.isEmpty ||
            character.displayName.toLowerCase().contains(q) ||
            character.description.toLowerCase().contains(q) ||
            character.tags.any((tag) => tag.toLowerCase().contains(q));
        return matchesQuery &&
            _tagFilter.every((tag) => character.tags.contains(tag));
      }).toList();

  void _toggle(String id) => setState(() {
    if (!_selection.remove(id)) _selection.add(id);
  });

  void _openChat(AppState state, Folder folder, Character character) {
    state.startChatWithCharacter(character, folderId: folder.id);
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const ChatScreen()));
  }

  Future<void> _removeSelected(AppState state, Folder folder) async {
    if (_selection.isEmpty) return;
    final count = _selection.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $count character${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They stay in the character roster and are only removed from this folder.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in _selection.toList()) {
      await state.removeFromFolder(folder.id, FolderItemKind.character, id);
    }
    if (mounted) {
      setState(() {
        _selection.clear();
        _selecting = false;
      });
    }
  }

  Future<void> _import(AppState state) async {
    final imported = await FolderIO.importFolder(context, state);
    if (imported == null) return;
    await state.addFolder(imported);
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => FolderHomeScreen(folderId: imported.id),
      ),
    );
  }

  void _showTags(List<String> tags) {
    if (tags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tags on these characters yet.')),
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

  @override
  Widget build(BuildContext context) {
    final appTheme = Theme.of(context);
    final state = context.watch<AppState>();
    final folder = state.folderById(widget.folderId);
    if (folder == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Folder unavailable')),
        body: const Center(child: Text('This folder no longer exists.')),
      );
    }
    final seed = folder.color == 0
        ? appTheme.colorScheme.primary
        : Color(folder.color);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: appTheme.brightness,
    );
    final characters = _characters(state, folder);
    final tags = <String>{
      for (final id in folder.characterIds) ...?state.characterById(id)?.tags,
    }.toList()..sort();
    return Theme(
      data: appTheme.copyWith(colorScheme: scheme),
      child: Scaffold(
        drawer: _selecting ? null : _FolderDrawer(current: folder),
        appBar: AppBar(
          leading: _selecting
              ? IconButton(
                  tooltip: 'Cancel selection',
                  onPressed: () => setState(() {
                    _selecting = false;
                    _selection.clear();
                  }),
                  icon: const Icon(Icons.close),
                )
              : null,
          title: Text(
            _selecting ? '${_selection.length} selected' : folder.displayName,
          ),
          actions: [
            if (_selecting)
              IconButton(
                tooltip: 'Remove selected',
                onPressed: _selection.isEmpty
                    ? null
                    : () => _removeSelected(state, folder),
                icon: const Icon(Icons.delete_outline),
              )
            else ...[
              IconButton(
                tooltip: 'Export folder',
                onPressed: () => FolderIO.exportFolder(context, folder, state),
                icon: const Icon(Icons.download_outlined),
              ),
              IconButton(
                tooltip: 'Import folder',
                onPressed: () => _import(state),
                icon: const Icon(Icons.upload_file_outlined),
              ),
              IconButton(
                tooltip: 'Select characters',
                onPressed: folder.characterIds.isEmpty
                    ? null
                    : () => setState(() => _selecting = true),
                icon: const Icon(Icons.checklist_outlined),
              ),
            ],
          ],
        ),
        body: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _controls(state, tags)),
            if (folder.characterIds.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyFolderCharacters(),
              )
            else if (characters.isEmpty)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text('No characters match those filters.'),
                ),
              )
            else
              _characterList(state, folder, characters),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 32 + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _controls(AppState state, List<String> tags) {
    final grid = _grid(state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
      child: Column(
        children: [
          SearchBar(
            controller: _search,
            hintText: 'Search characters',
            leading: const Icon(Icons.search),
            trailing: [
              if (_query.isNotEmpty)
                IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
            onChanged: (value) => setState(() => _query = value),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              ActionChip(
                avatar: const Icon(Icons.label_outline, size: 18),
                label: Text(
                  _tagFilter.isEmpty
                      ? 'Tags'
                      : '${_tagFilter.length} tag'
                            '${_tagFilter.length == 1 ? '' : 's'}',
                ),
                backgroundColor: _tagFilter.isEmpty
                    ? null
                    : Theme.of(context).colorScheme.secondaryContainer,
                onPressed: () => _showTags(tags),
              ),
              const Spacer(),
              IconButton(
                tooltip: grid ? 'Show as list' : 'Show as grid',
                onPressed: () => state.setBrowseLayout(
                  BrowseSection.folders,
                  grid ? BrowseLayout.list : BrowseLayout.grid,
                ),
                icon: Icon(
                  grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _characterList(
    AppState state,
    Folder folder,
    List<Character> characters,
  ) {
    if (_grid(state)) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.72,
          ),
          itemCount: characters.length,
          itemBuilder: (context, index) {
            final character = characters[index];
            return _CharacterCard(
              character: character,
              selected: _selection.contains(character.id),
              selecting: _selecting,
              onTap: () => _selecting
                  ? _toggle(character.id)
                  : _openChat(state, folder, character),
              onLongPress: () => setState(() {
                _selecting = true;
                _selection.add(character.id);
              }),
            );
          },
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      sliver: SliverList.builder(
        itemCount: characters.length,
        itemBuilder: (context, index) {
          final character = characters[index];
          final selected = _selection.contains(character.id);
          return ListTile(
            leading: CharacterAvatar(character: character, radius: 24),
            title: Text(character.displayName),
            subtitle: character.tags.isEmpty
                ? null
                : Text(character.tags.take(3).join(' · ')),
            trailing: _selecting
                ? Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  )
                : const Icon(Icons.chat_bubble_outline),
            selected: selected,
            onTap: () => _selecting
                ? _toggle(character.id)
                : _openChat(state, folder, character),
            onLongPress: () => setState(() {
              _selecting = true;
              _selection.add(character.id);
            }),
          );
        },
      ),
    );
  }
}

class _FolderDrawer extends StatelessWidget {
  const _FolderDrawer({required this.current});
  final Folder current;

  @override
  Widget build(BuildContext context) {
    final folders = context.watch<AppState>().folders;
    return Drawer(
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                'Folders',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            ListTile(
              leading: const Icon(Icons.home_outlined),
              title: const Text('Home'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).popUntil((route) => route.isFirst);
              },
            ),
            const Divider(),
            for (final folder in folders)
              ListTile(
                leading: Icon(
                  folder.id == current.id
                      ? Icons.folder
                      : Icons.folder_outlined,
                  color: folder.color == 0 ? null : Color(folder.color),
                ),
                title: Text(folder.displayName),
                selected: folder.id == current.id,
                onTap: folder.id == current.id
                    ? () => Navigator.of(context).pop()
                    : () {
                        Navigator.of(context).pop();
                        Navigator.of(context).pushReplacement(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                FolderHomeScreen(folderId: folder.id),
                          ),
                        );
                      },
              ),
          ],
        ),
      ),
    );
  }
}

class _CharacterCard extends StatelessWidget {
  const _CharacterCard({
    required this.character,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });
  final Character character;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
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
              child: CharacterAvatar(
                character: character,
                size: 260,
                shape: AvatarShape.rounded,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      character.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (selecting)
                    Icon(selected ? Icons.check_circle : Icons.circle_outlined),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyFolderCharacters extends StatelessWidget {
  const _EmptyFolderCharacters();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.group_add_outlined, size: 56),
          const SizedBox(height: 16),
          Text(
            'No characters here yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          const Text(
            'Open the folder editor to add characters.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
