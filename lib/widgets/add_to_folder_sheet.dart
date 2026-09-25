import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/folder.dart';
import '../state/app_state.dart';

/// Lets an item be added to, or removed from, any number of folders.
Future<void> showAddToFolderSheet(
  BuildContext context, {
  required FolderItemKind kind,
  required String itemId,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (_) => _AddToFolderSheet(kind: kind, itemId: itemId),
);

class _AddToFolderSheet extends StatefulWidget {
  const _AddToFolderSheet({required this.kind, required this.itemId});

  final FolderItemKind kind;
  final String itemId;

  @override
  State<_AddToFolderSheet> createState() => _AddToFolderSheetState();
}

class _AddToFolderSheetState extends State<_AddToFolderSheet> {
  final Set<String> _busy = <String>{};

  bool _contains(Folder folder) => switch (widget.kind) {
    FolderItemKind.character => folder.characterIds.contains(widget.itemId),
    FolderItemKind.lorebook => folder.lorebookIds.contains(widget.itemId),
    FolderItemKind.scenario => folder.scenarioIds.contains(widget.itemId),
    FolderItemKind.preset => folder.presetIds.contains(widget.itemId),
    FolderItemKind.provider => folder.providerIds.contains(widget.itemId),
    FolderItemKind.document => folder.documentIds.contains(widget.itemId),
    FolderItemKind.gallery => folder.galleryImageIds.contains(widget.itemId),
  };

  Future<void> _toggle(
    AppState state,
    Folder folder,
    bool add,
  ) async {
    if (_busy.contains(folder.id)) return;
    setState(() => _busy.add(folder.id));
    try {
      if (add) {
        await state.addToFolder(folder.id, widget.kind, widget.itemId);
      } else {
        await state.removeFromFolder(folder.id, widget.kind, widget.itemId);
      }
    } finally {
      if (mounted) setState(() => _busy.remove(folder.id));
    }
  }

  Future<void> _newFolder(AppState state) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            labelText: 'Name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.of(context).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final folder = Folder.empty()..name = name.trim();
    await state.addFolder(folder);
    await state.addToFolder(folder.id, widget.kind, widget.itemId);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final folders = state.folders;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Add to folder',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              subtitle: const Text('Create a folder and add this item'),
              onTap: () => _newFolder(context.read<AppState>()),
            ),
            const Divider(height: 1),
            if (folders.isEmpty)
              const Flexible(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('No folders yet. Create one to get started.'),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.only(bottom: bottom + 8),
                  itemCount: folders.length,
                  itemBuilder: (context, index) {
                    final folder = folders[index];
                    final checked = _contains(folder);
                    final busy = _busy.contains(folder.id);
                    return CheckboxListTile(
                      value: checked,
                      secondary: Icon(
                        Icons.folder_outlined,
                        color: folder.color == 0 ? null : Color(folder.color),
                      ),
                      title: Text(folder.displayName),
                      subtitle: Text(
                        '${folder.characterIds.length} character'
                        '${folder.characterIds.length == 1 ? '' : 's'}',
                      ),
                      onChanged: busy
                          ? null
                          : (value) => _toggle(state, folder, value ?? false),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
