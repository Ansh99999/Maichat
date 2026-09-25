import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/folder.dart';
import '../../models/view_prefs.dart';
import '../../services/folder_io.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/tag_filter_sheet.dart';
import 'folder_edit_screen.dart';
import 'folder_home_screen.dart';

/// The folder roster, with the same search/tag/layout vocabulary as Characters.
class FoldersScreen extends StatefulWidget {
  const FoldersScreen({super.key});

  @override
  State<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends State<FoldersScreen> {
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

  List<String> _allTags(List<Folder> folders) =>
      ({for (final folder in folders) ...folder.tags}.toList()..sort());

  List<Folder> _visible(List<Folder> folders) => folders.where((folder) {
    return folder.matches(_query) &&
        _tagFilter.every((tag) => folder.tags.contains(tag));
  }).toList()..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  void _toggle(String id) => setState(() {
    if (!_selection.remove(id)) _selection.add(id);
  });

  Future<void> _create() async {
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<Folder>(builder: (_) => const FolderEditScreen()));
  }

  Future<void> _import(AppState state) async {
    final folder = await FolderIO.importFolder(context, state);
    if (folder != null) await state.addFolder(folder);
  }

  Future<void> _exportSelected(AppState state) async {
    final folders = state.folders
        .where((folder) => _selection.contains(folder.id))
        .toList();
    for (final folder in folders) {
      if (!mounted) return;
      await FolderIO.exportFolder(context, folder, state);
    }
    if (mounted) {
      setState(() {
        _selecting = false;
        _selection.clear();
      });
    }
  }

  void _open(Folder folder) {
    if (_selecting) {
      _toggle(folder.id);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FolderHomeScreen(folderId: folder.id),
      ),
    );
  }

  void _showTags(List<String> tags) {
    if (tags.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No tags on any folder yet.')),
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
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final folders = state.folders;
    final visible = _visible(folders);
    final tags = _allTags(folders);
    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                tooltip: 'Cancel selection',
                onPressed: () => setState(() {
                  _selecting = false;
                  _selection.clear();
                }),
                icon: const Icon(Icons.close),
              ),
              title: Text('${_selection.length} selected'),
              actions: [
                IconButton(
                  tooltip: 'Export selected',
                  onPressed: _selection.isEmpty
                      ? null
                      : () => _exportSelected(state),
                  icon: const Icon(Icons.download_outlined),
                ),
              ],
            )
          : AppBar(
              title: const Text('Folders'),
              actions: [
                IconButton(
                  tooltip: 'Create folder',
                  onPressed: _create,
                  icon: const Icon(Icons.create_new_folder_outlined),
                ),
                IconButton(
                  tooltip: 'Import folder',
                  onPressed: () => _import(state),
                  icon: const Icon(Icons.upload_file_outlined),
                ),
                IconButton(
                  tooltip: 'Export folders',
                  onPressed: folders.isEmpty
                      ? null
                      : () => setState(() => _selecting = true),
                  icon: const Icon(Icons.download_outlined),
                ),
              ],
            ),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _create,
              icon: const Icon(Icons.add),
              label: const Text('New folder'),
            ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _controls(state, tags)),
          if (folders.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyFolders(onCreate: _create),
            )
          else if (visible.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text('No folders match those filters.')),
            )
          else
            _folderList(state, visible),
          SliverToBoxAdapter(
            child: SizedBox(height: 96 + MediaQuery.paddingOf(context).bottom),
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
            hintText: 'Search folders',
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 14),
            ),
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

  Widget _folderList(AppState state, List<Folder> folders) {
    if (_grid(state)) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 220,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.88,
          ),
          itemCount: folders.length,
          itemBuilder: (context, index) {
            final folder = folders[index];
            return _FolderCard(
              folder: folder,
              selected: _selection.contains(folder.id),
              selecting: _selecting,
              onTap: () => _open(folder),
              onLongPress: () => setState(() {
                _selecting = true;
                _selection.add(folder.id);
              }),
            );
          },
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      sliver: SliverList.builder(
        itemCount: folders.length,
        itemBuilder: (context, index) {
          final folder = folders[index];
          return ListTile(
            leading: _FolderPicture(folder: folder, size: 48),
            title: Text(folder.displayName),
            subtitle: Text(
              '${folder.characterIds.length} character'
              '${folder.characterIds.length == 1 ? '' : 's'}',
            ),
            trailing: _selecting
                ? Icon(
                    _selection.contains(folder.id)
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  )
                : const Icon(Icons.chevron_right),
            selected: _selection.contains(folder.id),
            onTap: () => _open(folder),
            onLongPress: () => setState(() {
              _selecting = true;
              _selection.add(folder.id);
            }),
          );
        },
      ),
    );
  }
}

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.folder,
    required this.selected,
    required this.selecting,
    required this.onTap,
    required this.onLongPress,
  });

  final Folder folder;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
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
              child: _FolderPicture(folder: folder, size: double.infinity),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          folder.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${folder.characterIds.length} character'
                          '${folder.characterIds.length == 1 ? '' : 's'}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
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

class _FolderPicture extends StatelessWidget {
  const _FolderPicture({required this.folder, required this.size});
  final Folder folder;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = avatarImage(
      folder.avatar,
      displaySize: size.isFinite ? size : 220,
    );
    final tint = folder.color == 0
        ? Theme.of(context).colorScheme.secondaryContainer
        : Color(folder.color).withValues(alpha: 0.22);
    if (image != null) {
      return Image(image: image, width: size, height: size, fit: BoxFit.cover);
    }
    return ColoredBox(
      color: tint,
      child: Center(
        child: Icon(
          Icons.folder_rounded,
          size: size.isFinite ? size * 0.56 : 72,
          color: folder.color == 0
              ? Theme.of(context).colorScheme.onSecondaryContainer
              : Color(folder.color),
        ),
      ),
    );
  }
}

class _EmptyFolders extends StatelessWidget {
  const _EmptyFolders({required this.onCreate});
  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.folder_open_outlined, size: 56),
          const SizedBox(height: 16),
          Text('No folders yet', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          const Text(
            'Group characters with the lorebooks, presets, and pictures they use.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add),
            label: const Text('Create folder'),
          ),
        ],
      ),
    ),
  );
}
