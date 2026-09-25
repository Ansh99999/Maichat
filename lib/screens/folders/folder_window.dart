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
import 'folder_edit_screen.dart';

/// Opens [folderId] as a floating folder window: a rounded panel, tinted with
/// the folder's colour, that scales up like an Android home-screen folder. The
/// `host` navigator is used for anything that outlives the window (opening a
/// chat, the editor), so those routes sit under the app, not under the dialog.
Future<void> showFolderWindow(
  BuildContext context, {
  required String folderId,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (_, _, _) => _FolderWindow(folderId: folderId, host: context),
    transitionBuilder: (_, animation, _, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.85, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
}

class _FolderWindow extends StatefulWidget {
  const _FolderWindow({required this.folderId, required this.host});

  final String folderId;
  final BuildContext host;

  @override
  State<_FolderWindow> createState() => _FolderWindowState();
}

class _FolderWindowState extends State<_FolderWindow> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _tagFilter = <String>{};
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _grid(AppState state) =>
      state.browseLayout(BrowseSection.folders) == BrowseLayout.grid;

  List<Character> _characters(AppState state, Folder folder) => <Character>[
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

  void _openChat(AppState state, Folder folder, Character character) {
    state.startChatWithCharacter(character, folderId: folder.id);
    Navigator.of(context).pop(); // close the window
    Navigator.of(
      widget.host,
    ).push(MaterialPageRoute<void>(builder: (_) => const ChatScreen()));
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

  Future<void> _menu(AppState state, Folder folder, Offset at) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    // Captured before the await so the edit route can outlive this dialog.
    final host = Navigator.of(widget.host);
    final choice = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        at & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'edit', child: Text('Edit')),
        PopupMenuItem(value: 'import', child: Text('Import')),
        PopupMenuItem(value: 'export', child: Text('Export')),
      ],
    );
    if (!mounted) return;
    switch (choice) {
      case 'edit':
        Navigator.of(context).pop();
        host.push(
          MaterialPageRoute<void>(
            builder: (_) => FolderEditScreen(folder: folder),
          ),
        );
      case 'import':
        final imported = await FolderIO.importFolder(context, state);
        if (imported != null) await state.addFolder(imported);
      case 'export':
        await FolderIO.exportFolder(context, folder, state);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appTheme = Theme.of(context);
    final state = context.watch<AppState>();
    final folder = state.folderById(widget.folderId);
    final media = MediaQuery.of(context);
    if (folder == null) {
      return const SizedBox.shrink();
    }
    final seed = folder.color == 0
        ? appTheme.colorScheme.primary
        : Color(folder.color);
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: appTheme.brightness,
    );
    final panel = folder.color == 0
        ? scheme.surfaceContainerHigh
        : Color.alphaBlend(seed.withValues(alpha: 0.28), scheme.surface);
    final characters = _characters(state, folder);
    final tags =
        <String>{
          for (final id in folder.characterIds) ...?state.characterById(id)?.tags,
        }.toList()
          ..sort();

    return Theme(
      data: appTheme.copyWith(colorScheme: scheme),
      child: Center(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            media.padding.top + 24,
            16,
            media.viewInsets.bottom + media.padding.bottom + 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: media.size.height * 0.82,
            ),
            child: Material(
              color: panel,
              elevation: 8,
              borderRadius: BorderRadius.circular(28),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _header(state, folder),
                  _controls(state, tags),
                  Flexible(
                    child: folder.characterIds.isEmpty
                        ? const _EmptyFolderCharacters()
                        : characters.isEmpty
                        ? const Center(
                            child: Padding(
                              padding: EdgeInsets.all(32),
                              child: Text('No characters match those filters.'),
                            ),
                          )
                        : _characterList(state, folder, characters),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header(AppState state, Folder folder) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: Text(
              folder.displayName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Builder(
            builder: (buttonContext) => IconButton(
              tooltip: 'Folder options',
              icon: const Icon(Icons.more_vert),
              onPressed: () {
                final box = buttonContext.findRenderObject() as RenderBox?;
                final at = box == null
                    ? Offset.zero
                    : box.localToGlobal(box.size.centerRight(Offset.zero));
                _menu(state, folder, at);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(AppState state, List<String> tags) {
    final grid = _grid(state);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        children: [
          SearchBar(
            controller: _search,
            hintText: 'Search characters',
            elevation: const WidgetStatePropertyAll(0),
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
      return GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 150,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.72,
        ),
        itemCount: characters.length,
        itemBuilder: (context, index) {
          final character = characters[index];
          return _CharacterTile(
            character: character,
            onTap: () => _openChat(state, folder, character),
          );
        },
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 2, 8, 16),
      itemCount: characters.length,
      itemBuilder: (context, index) {
        final character = characters[index];
        return ListTile(
          leading: CharacterAvatar(character: character, radius: 22),
          title: Text(character.displayName),
          subtitle: character.tags.isEmpty
              ? null
              : Text(character.tags.take(3).join(' · ')),
          trailing: const Icon(Icons.chat_bubble_outline),
          onTap: () => _openChat(state, folder, character),
        );
      },
    );
  }
}

class _CharacterTile extends StatelessWidget {
  const _CharacterTile({required this.character, required this.onTap});
  final Character character;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: scheme.surfaceContainerLowest,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: CharacterAvatar(
                character: character,
                size: 200,
                shape: AvatarShape.rounded,
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                character.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
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
          const Icon(Icons.group_add_outlined, size: 48),
          const SizedBox(height: 12),
          Text(
            'No characters here yet',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          const Text(
            'Edit the folder to add characters.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}
