import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../services/avatar_store.dart';
import '../../services/storage_report.dart';
import '../../state/app_state.dart';
import '../chats_screen.dart' show relativeTime;

/// How the manage list is ordered. Largest-first is the default — the reason
/// someone opens this screen is usually "what is taking all the room".
enum StorageSort {
  largest('Largest first'),
  smallest('Smallest first'),
  newest('Newest first'),
  oldest('Oldest first'),
  az('Name A–Z'),
  za('Name Z–A');

  const StorageSort(this.label);
  final String label;
}

/// One deletable thing in a category's manage screen: enough to show a row and,
/// on confirm, delete it by id. [bytes] is this item's own footprint; [time] is
/// null for a category that has no timestamp (presets), which just sinks it to
/// the bottom of a newest/oldest sort.
class StorageItem {
  const StorageItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.bytes,
    this.time,
    this.thumbRef,
  });

  final String id;
  final String title;
  final String subtitle;
  final int bytes;
  final DateTime? time;
  final String? thumbRef;
}

int _jsonBytes(Object? json) => utf8.encode(jsonEncode(json)).length;

/// Builds the deletable items for a category from the live app state.
List<StorageItem> storageItemsFor(AppState state, StorageCategory category) {
  switch (category) {
    case StorageCategory.chats:
      return [
        for (final c in state.conversations)
          StorageItem(
            id: c.id,
            title: c.title.trim().isEmpty ? 'Untitled chat' : c.title,
            subtitle: '${c.messages.length} messages · '
                '${relativeTime(c.updatedAt)}',
            bytes: _jsonBytes(c.toJson()),
            time: c.updatedAt,
          ),
      ];
    case StorageCategory.characters:
      return [
        for (final c in state.characters)
          StorageItem(
            id: c.id,
            title: c.name.trim().isEmpty ? 'Unnamed' : c.name,
            subtitle: relativeTime(c.updatedAt),
            bytes: _jsonBytes(c.toJson()),
            time: c.updatedAt,
            thumbRef: c.avatar,
          ),
      ];
    case StorageCategory.lorebooks:
      return [
        for (final b in state.lorebooks)
          StorageItem(
            id: b.id,
            title: b.name.trim().isEmpty ? 'Untitled lorebook' : b.name,
            subtitle: '${b.entries.length} entries · '
                '${relativeTime(b.updatedAt)}',
            bytes: _jsonBytes(b.toJson()),
            time: b.updatedAt,
            thumbRef: b.thumbnail,
          ),
      ];
    case StorageCategory.presets:
      return [
        for (final p in state.presets)
          StorageItem(
            id: p.id,
            title: p.name.trim().isEmpty ? 'Untitled preset' : p.name,
            subtitle: p.model.trim().isEmpty ? 'No model' : p.model,
            bytes: _jsonBytes(p.toJson()),
          ),
      ];
    case StorageCategory.gallery:
      return [
        for (final g in state.gallery)
          StorageItem(
            id: g.id,
            title: g.title.trim().isEmpty ? 'Untitled' : g.title,
            subtitle: relativeTime(g.updatedAt),
            bytes: _jsonBytes(g.toJson()),
            time: g.updatedAt,
            thumbRef: g.image,
          ),
      ];
    default:
      return const [];
  }
}

/// Deletes the chosen items through the category's own cascade-aware path.
Future<void> deleteStorageItems(
  AppState state,
  StorageCategory category,
  Iterable<String> ids,
) async {
  switch (category) {
    case StorageCategory.gallery:
      await state.deleteGalleryImages(ids); // batch, cascade-aware
    case StorageCategory.chats:
      for (final id in ids) {
        await state.deleteConversation(id);
      }
    case StorageCategory.characters:
      for (final id in ids) {
        await state.deleteCharacter(id);
      }
    case StorageCategory.lorebooks:
      for (final id in ids) {
        await state.deleteLorebook(id);
      }
    case StorageCategory.presets:
      for (final id in ids) {
        await state.deletePreset(id);
      }
    default:
      break;
  }
}

/// The manage screen for a list-backed category (chats, characters, lorebooks,
/// presets, gallery): a caution header, Select all / Delete, a search field, a
/// sort menu, and a multi-select list. Reads the live app state, so a delete
/// simply makes the row fall away on the next build.
class StorageCategoryScreen extends StatefulWidget {
  const StorageCategoryScreen({super.key, required this.category});

  final StorageCategory category;

  @override
  State<StorageCategoryScreen> createState() => _StorageCategoryScreenState();
}

class _StorageCategoryScreenState extends State<StorageCategoryScreen> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _selected = <String>{};
  StorageSort _sort = StorageSort.largest;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<StorageItem> _visible(List<StorageItem> items) {
    final needle = _search.text.trim().toLowerCase();
    final filtered = needle.isEmpty
        ? [...items]
        : items
            .where((i) =>
                i.title.toLowerCase().contains(needle) ||
                i.subtitle.toLowerCase().contains(needle))
            .toList();
    filtered.sort((a, b) => switch (_sort) {
          StorageSort.largest => b.bytes.compareTo(a.bytes),
          StorageSort.smallest => a.bytes.compareTo(b.bytes),
          StorageSort.az =>
            a.title.toLowerCase().compareTo(b.title.toLowerCase()),
          StorageSort.za =>
            b.title.toLowerCase().compareTo(a.title.toLowerCase()),
          StorageSort.newest => _byTime(b, a),
          StorageSort.oldest => _byTime(a, b),
        });
    return filtered;
  }

  // Items without a timestamp sink to the bottom of a time sort, either way.
  static int _byTime(StorageItem x, StorageItem y) {
    if (x.time == null && y.time == null) return 0;
    if (x.time == null) return 1;
    if (y.time == null) return -1;
    return x.time!.compareTo(y.time!);
  }

  Future<void> _confirmDelete(AppState state, List<StorageItem> visible) async {
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $n ${n == 1 ? 'item' : 'items'}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final ids = _selected.toList();
    await deleteStorageItems(state, widget.category, ids);
    if (mounted) setState(_selected.clear);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final items = storageItemsFor(state, widget.category);
    final visible = _visible(items);
    final totalBytes = items.fold<int>(0, (sum, i) => sum + i.bytes);
    final allSelected =
        visible.isNotEmpty && visible.every((i) => _selected.contains(i.id));
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.category.label),
        actions: [
          PopupMenuButton<StorageSort>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (context) => [
              for (final s in StorageSort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.only(bottom: 16 + bottom),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.category.label, style: theme.textTheme.titleLarge),
                const SizedBox(height: 2),
                Text(
                  '${formatBytes(totalBytes)} · ${items.length} '
                  '${items.length == 1 ? 'item' : 'items'}',
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 8),
                Text(
                  'May affect your chat history. Delete with care.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                _ActionButtons(
                  allSelected: allSelected,
                  selectedCount: _selected.length,
                  onSelectAll: visible.isEmpty
                      ? null
                      : () => setState(() {
                            if (allSelected) {
                              _selected.clear();
                            } else {
                              _selected
                                ..clear()
                                ..addAll(visible.map((i) => i.id));
                            }
                          }),
                  onDelete: _selected.isEmpty
                      ? null
                      : () => _confirmDelete(state, visible),
                ),
                const SizedBox(height: 12),
                SearchBar(
                  controller: _search,
                  hintText: 'Search ${widget.category.label.toLowerCase()}',
                  leading: const Icon(Icons.search),
                  onChanged: (_) => setState(() {}),
                  elevation: const WidgetStatePropertyAll(0),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.all(48),
              child: Center(
                child: Text(
                  items.isEmpty ? 'Nothing stored here' : 'No matches',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
            )
          else
            for (final item in visible)
              _StorageRow(
                item: item,
                selected: _selected.contains(item.id),
                onTap: () => setState(() {
                  if (!_selected.remove(item.id)) _selected.add(item.id);
                }),
              ),
        ],
      ),
    );
  }
}

/// The Select-all / Delete pair shown above the list.
class _ActionButtons extends StatelessWidget {
  const _ActionButtons({
    required this.allSelected,
    required this.selectedCount,
    required this.onSelectAll,
    required this.onDelete,
  });

  final bool allSelected;
  final int selectedCount;
  final VoidCallback? onSelectAll;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: onSelectAll,
          icon: Icon(allSelected ? Icons.remove_done : Icons.checklist_rtl),
          label: Text(allSelected ? 'Clear' : 'Select all'),
        ),
        const SizedBox(width: 12),
        FilledButton.tonalIcon(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline),
          label:
              Text(selectedCount == 0 ? 'Delete' : 'Delete ($selectedCount)'),
        ),
      ],
    );
  }
}

/// One selectable row: a leading checkbox that turns into a tick, an optional
/// picture thumbnail, the title + subtitle, and the item's own size.
class _StorageRow extends StatelessWidget {
  const _StorageRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final StorageItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ListTile(
      onTap: onTap,
      selected: selected,
      selectedTileColor: scheme.secondaryContainer.withValues(alpha: 0.4),
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            selected ? Icons.check_circle : Icons.circle_outlined,
            color: selected ? scheme.primary : scheme.outline,
          ),
          const SizedBox(width: 10),
          _Thumb(ref: item.thumbRef, fallback: item.title),
        ],
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(item.subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Text(
        formatBytes(item.bytes),
        style: theme.textTheme.labelMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

/// A 40px rounded thumbnail for an avatar/picture reference — a file for a
/// `local:` ref, the network for a URL, or a lettered placeholder otherwise.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.ref, required this.fallback});

  final String? ref;
  final String fallback;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const size = 40.0;
    Widget? image;
    final value = ref?.trim() ?? '';
    if (value.isNotEmpty) {
      final file = avatarRefFile(value);
      if (file != null) {
        image = Image.file(file, width: size, height: size, fit: BoxFit.cover);
      } else if (value.startsWith('http')) {
        image =
            Image.network(value, width: size, height: size, fit: BoxFit.cover);
      }
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: image ??
          Container(
            width: size,
            height: size,
            color: scheme.secondaryContainer,
            alignment: Alignment.center,
            child: Text(
              fallback.isEmpty ? '?' : fallback.characters.first.toUpperCase(),
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
          ),
    );
  }
}

/// The Images category, as a thumbnail grid (the pictures are files on disk, not
/// list rows). Select-all / Delete and the same sort menu; deleting a picture
/// removes the file and lets any reference fall back to nothing, which the
/// caution header spells out.
class StorageImagesScreen extends StatefulWidget {
  const StorageImagesScreen({super.key});

  @override
  State<StorageImagesScreen> createState() => _StorageImagesScreenState();
}

class _StorageImagesScreenState extends State<StorageImagesScreen> {
  List<ImageFileStat>? _files;
  Directory? _dir;
  final Set<String> _selected = <String>{};
  StorageSort _sort = StorageSort.largest;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final files = await state.imageFiles();
    if (!mounted) return;
    setState(() {
      _files = files;
      _dir = state.imageDirectory;
    });
  }

  List<ImageFileStat> _sorted(List<ImageFileStat> files) {
    final list = [...files];
    list.sort((a, b) => switch (_sort) {
          StorageSort.largest => b.bytes.compareTo(a.bytes),
          StorageSort.smallest => a.bytes.compareTo(b.bytes),
          StorageSort.newest => b.modified.compareTo(a.modified),
          StorageSort.oldest => a.modified.compareTo(b.modified),
          StorageSort.az => a.name.compareTo(b.name),
          StorageSort.za => b.name.compareTo(a.name),
        });
    return list;
  }

  Future<void> _confirmDelete() async {
    final state = context.read<AppState>();
    final n = _selected.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $n ${n == 1 ? 'picture' : 'pictures'}?'),
        content: const Text(
            'The files are removed. Anything still using them — an avatar or '
            'chat background — falls back to nothing. This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.deleteImageFiles(_selected.toList());
    _selected.clear();
    final files = await state.imageFiles();
    if (mounted) setState(() => _files = files);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final files = _files;
    final bottom = MediaQuery.paddingOf(context).bottom;
    final sorted = files == null ? const <ImageFileStat>[] : _sorted(files);
    final totalBytes = sorted.fold<int>(0, (sum, f) => sum + f.bytes);
    final allSelected =
        sorted.isNotEmpty && sorted.every((f) => _selected.contains(f.name));

    return Scaffold(
      appBar: AppBar(
        title: Text(StorageCategory.images.label),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          PopupMenuButton<StorageSort>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (s) => setState(() => _sort = s),
            itemBuilder: (context) => [
              for (final s in StorageSort.values)
                PopupMenuItem(value: s, child: Text(s.label)),
            ],
          ),
        ],
      ),
      body: files == null
          ? const Center(child: CircularProgressIndicator())
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(StorageCategory.images.label,
                            style: theme.textTheme.titleLarge),
                        const SizedBox(height: 2),
                        Text(
                          '${formatBytes(totalBytes)} · ${sorted.length} '
                          '${sorted.length == 1 ? 'file' : 'files'}',
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'May affect your chat history. Delete with care.',
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 12),
                        _ActionButtons(
                          allSelected: allSelected,
                          selectedCount: _selected.length,
                          onSelectAll: sorted.isEmpty
                              ? null
                              : () => setState(() {
                                    if (allSelected) {
                                      _selected.clear();
                                    } else {
                                      _selected
                                        ..clear()
                                        ..addAll(sorted.map((f) => f.name));
                                    }
                                  }),
                          onDelete:
                              _selected.isEmpty ? null : _confirmDelete,
                        ),
                        const SizedBox(height: 12),
                      ],
                    ),
                  ),
                ),
                if (sorted.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(48),
                      child: Center(
                        child: Text('No pictures stored',
                            style: TextStyle(color: scheme.onSurfaceVariant)),
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottom),
                    sliver: SliverGrid(
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      delegate: SliverChildBuilderDelegate(
                        (context, i) {
                          final f = sorted[i];
                          return _ImageTile(
                            file: _dir == null
                                ? null
                                : File('${_dir!.path}/${f.name}'),
                            selected: _selected.contains(f.name),
                            onTap: () => setState(() {
                              if (!_selected.remove(f.name)) {
                                _selected.add(f.name);
                              }
                            }),
                          );
                        },
                        childCount: sorted.length,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

/// One picture in the images grid, with a selection ring in the corner.
class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.file,
    required this.selected,
    required this.onTap,
  });

  final File? file;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (file != null)
              Image.file(file!, fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => ColoredBox(
                      color: scheme.surfaceContainerHighest,
                      child: Icon(Icons.broken_image_outlined,
                          color: scheme.onSurfaceVariant)))
            else
              ColoredBox(color: scheme.surfaceContainerHighest),
            if (selected)
              ColoredBox(color: scheme.primary.withValues(alpha: 0.28)),
            Positioned(
              top: 6,
              right: 6,
              child: Icon(
                selected
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                color: selected ? scheme.primary : Colors.white70,
                size: 24,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The Cache category: one button that drops the rebuildable caches. There is
/// nothing per-item to manage, so this is deliberately just an action.
class StorageCacheScreen extends StatelessWidget {
  const StorageCacheScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(StorageCategory.cache.label)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Cache', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Cached model lists and Discover browsing state. Clearing this '
            'frees space and loses nothing you created — it is rebuilt the next '
            'time it is needed.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          FilledButton.tonalIcon(
            onPressed: () async {
              final messenger = ScaffoldMessenger.of(context);
              await context.read<AppState>().clearCaches();
              messenger.showSnackBar(
                const SnackBar(content: Text('Cache cleared')),
              );
            },
            icon: const Icon(Icons.delete_sweep_outlined),
            label: const Text('Clear cache'),
          ),
        ],
      ),
    );
  }
}





