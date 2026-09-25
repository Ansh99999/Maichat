import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/folder.dart';
import '../../services/avatar_store.dart';
import '../../services/folder_io.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/character_avatar.dart';
import 'folder_essentials_screen.dart';
import 'folder_settings_screen.dart';

/// Creates or edits a folder through an isolated working clone.
class FolderEditScreen extends StatefulWidget {
  const FolderEditScreen({super.key, this.folder});

  final Folder? folder;

  @override
  State<FolderEditScreen> createState() => _FolderEditScreenState();
}

class _FolderEditScreenState extends State<FolderEditScreen> {
  late Folder _draft;
  late TextEditingController _name;
  late TextEditingController _description;
  final TextEditingController _characterSearch = TextEditingController();
  String _characterQuery = '';
  bool _saving = false;

  bool get _isNew => widget.folder == null;

  @override
  void initState() {
    super.initState();
    _adopt((widget.folder ?? Folder.empty()).clone());
  }

  void _adopt(Folder folder) {
    _draft = folder;
    _name = TextEditingController(text: folder.name);
    _description = TextEditingController(text: folder.description);
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _characterSearch.dispose();
    super.dispose();
  }

  void _syncText() {
    _draft
      ..name = _name.text.trim()
      ..description = _description.text.trim();
  }

  Future<void> _save(AppState state) async {
    if (_saving) return;
    _syncText();
    setState(() => _saving = true);
    try {
      await state.saveFolder(_draft.clone());
      if (mounted) Navigator.of(context).pop(_draft);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete(AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete folder?'),
        content: Text(
          '"${_draft.displayName}" will be removed. Its characters and library '
          'items will be kept.',
        ),
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
    await state.deleteFolder(_draft.id);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _import(AppState state) async {
    final imported = await FolderIO.importFolder(context, state);
    if (imported == null || !mounted) return;
    _name.dispose();
    _description.dispose();
    setState(() => _adopt(imported));
  }

  Future<void> _pickAvatar() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Choose folder picture',
        type: FileType.image,
        allowMultiple: false,
        withData: false,
      );
    } catch (_) {
      result = null;
    }
    final file = result?.files.singleOrNull;
    if (file == null) return;
    Uint8List? bytes;
    if (file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } catch (_) {
        bytes = null;
      }
    } else {
      bytes = file.bytes;
    }
    if (bytes == null || bytes.isEmpty) return;
    final store = await AvatarStore.open();
    if (store == null) return;
    final ref = await store.write(bytes, basename: 'folder-${_draft.id}');
    if (mounted) setState(() => _draft.avatar = ref);
  }

  Future<void> _pickColor() async {
    const colors = <Color>[
      Color(0xFF6750A4),
      Color(0xFF3F51B5),
      Color(0xFF006A6A),
      Color(0xFF2E7D32),
      Color(0xFFF57C00),
      Color(0xFFB3261E),
      Color(0xFF7D5260),
      Color(0xFF455A64),
    ];
    final picked = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Folder colour'),
        content: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _ColorChoice(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              selected: _draft.color == 0,
              label: 'App colour',
              onTap: () => Navigator.of(context).pop(0),
              icon: Icons.format_color_reset_outlined,
            ),
            for (final color in colors)
              _ColorChoice(
                color: color,
                selected: _draft.color == color.toARGB32(),
                label: 'Use colour',
                onTap: () => Navigator.of(context).pop(color.toARGB32()),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (picked != null) setState(() => _draft.color = picked);
  }

  Future<void> _addTag() async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add tag'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Tag',
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
            child: const Text('Add'),
          ),
        ],
      ),
    );
    controller.dispose();
    final tag = value?.trim() ?? '';
    if (tag.isNotEmpty && !_draft.tags.contains(tag)) {
      setState(() => _draft.tags.add(tag));
    }
  }

  Future<void> _addCharacters(AppState state) async {
    final available = state.characters
        .where((character) => !_draft.characterIds.contains(character.id))
        .toList();
    final selected = <String>{};
    final search = TextEditingController();
    String query = '';
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final visible = available.where(
            (character) => character.displayName.toLowerCase().contains(query),
          );
          return SafeArea(
            top: false,
            child: SizedBox(
              height: MediaQuery.sizeOf(context).height * 0.72,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: SearchBar(
                      controller: search,
                      hintText: 'Search characters',
                      leading: const Icon(Icons.search),
                      trailing: [
                        if (query.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              search.clear();
                              setSheetState(() => query = '');
                            },
                            icon: const Icon(Icons.close),
                          ),
                      ],
                      onChanged: (value) => setSheetState(
                        () => query = value.trim().toLowerCase(),
                      ),
                    ),
                  ),
                  Expanded(
                    child: available.isEmpty
                        ? const Center(
                            child: Text('Every character is already here.'),
                          )
                        : ListView(
                            children: [
                              for (final character in visible)
                                CheckboxListTile(
                                  value: selected.contains(character.id),
                                  secondary: CharacterAvatar(
                                    character: character,
                                    radius: 20,
                                  ),
                                  title: Text(character.displayName),
                                  onChanged: (value) => setSheetState(() {
                                    if (value ?? false) {
                                      selected.add(character.id);
                                    } else {
                                      selected.remove(character.id);
                                    }
                                  }),
                                ),
                            ],
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: selected.isEmpty
                            ? null
                            : () => Navigator.of(context).pop(selected),
                        child: const Text('Add selected'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
    search.dispose();
    if (result == null || !mounted) return;
    setState(() => _draft.characterIds.addAll(result));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final characters =
        <Character>[
          for (final id in _draft.characterIds) ?state.characterById(id),
        ].where((character) {
          final q = _characterQuery.trim().toLowerCase();
          return q.isEmpty || character.displayName.toLowerCase().contains(q);
        }).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New folder' : 'Edit folder'),
        actions: [
          IconButton(
            tooltip: 'Export',
            onPressed: () {
              _syncText();
              FolderIO.exportFolder(context, _draft, state);
            },
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Import',
            onPressed: () => _import(state),
            icon: const Icon(Icons.upload_file_outlined),
          ),
          if (!_isNew)
            IconButton(
              tooltip: 'Delete folder',
              onPressed: () => _delete(state),
              icon: const Icon(Icons.delete_outline),
            ),
          IconButton(
            tooltip: 'Folder settings',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FolderSettingsScreen(folder: _draft),
              ),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _saving ? null : () => _save(state),
        icon: _saving
            ? const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save_outlined),
        label: const Text('Save'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 104),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _FolderAvatarBox(folder: _draft, onTap: _pickAvatar),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  children: [
                    SizedBox(
                      height: 56,
                      child: TextField(
                        controller: _name,
                        textCapitalization: TextCapitalization.sentences,
                        decoration: const InputDecoration(
                          labelText: 'Name',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 48,
                      child: OutlinedButton.icon(
                        onPressed: _pickColor,
                        icon: Container(
                          width: 20,
                          height: 20,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: _draft.color == 0
                                ? Theme.of(context).colorScheme.primary
                                : Color(_draft.color),
                          ),
                        ),
                        label: const Text('Colour'),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          for (final tag in _draft.tags)
                            InputChip(
                              label: Text(tag),
                              onDeleted: () =>
                                  setState(() => _draft.tags.remove(tag)),
                            ),
                          ActionChip(
                            avatar: const Icon(Icons.add, size: 18),
                            label: const Text('Tag'),
                            onPressed: _addTag,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 132,
            child: TextField(
              controller: _description,
              expands: true,
              maxLines: null,
              textAlignVertical: TextAlignVertical.top,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Description',
                alignLabelWithHint: true,
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const Divider(height: 32),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.inventory_2_outlined),
            title: const Text('Essentials'),
            subtitle: Text(
              '${_draft.lorebookIds.length} lorebooks · '
              '${_draft.scenarioIds.length} scenarios · '
              '${_draft.presetIds.length} presets',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FolderEssentialsScreen(folder: _draft),
              ),
            ),
          ),
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: Text(
                  'Characters',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Add characters',
                onPressed: () => _addCharacters(state),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SearchBar(
            controller: _characterSearch,
            hintText: 'Search folder characters',
            leading: const Icon(Icons.search),
            trailing: [
              if (_characterQuery.isNotEmpty)
                IconButton(
                  tooltip: 'Clear search',
                  onPressed: () {
                    _characterSearch.clear();
                    setState(() => _characterQuery = '');
                  },
                  icon: const Icon(Icons.close),
                ),
            ],
            onChanged: (value) => setState(() => _characterQuery = value),
          ),
          const SizedBox(height: 8),
          if (_draft.characterIds.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No characters in this folder yet.')),
            )
          else if (characters.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: Text('No matching characters.')),
            )
          else
            for (final character in characters)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CharacterAvatar(character: character, radius: 22),
                title: Text(character.displayName),
                trailing: IconButton(
                  tooltip: 'Remove from folder',
                  onPressed: () =>
                      setState(() => _draft.characterIds.remove(character.id)),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
        ],
      ),
    );
  }
}

class _FolderAvatarBox extends StatelessWidget {
  const _FolderAvatarBox({required this.folder, required this.onTap});
  final Folder folder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final provider = avatarImage(folder.avatar, displaySize: 112);
    return Semantics(
      button: true,
      label: 'Choose folder picture',
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Ink(
          width: 112,
          height: 140,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Theme.of(context).colorScheme.secondaryContainer,
            image: provider == null
                ? null
                : DecorationImage(image: provider, fit: BoxFit.cover),
          ),
          child: provider == null
              ? const Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.add_photo_alternate_outlined, size: 34),
                    SizedBox(height: 8),
                    Text('Picture'),
                  ],
                )
              : Align(
                  alignment: Alignment.bottomRight,
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: IconButton.filledTonal(
                      tooltip: 'Change picture',
                      onPressed: onTap,
                      icon: const Icon(Icons.edit_outlined),
                    ),
                  ),
                ),
        ),
      ),
    );
  }
}

class _ColorChoice extends StatelessWidget {
  const _ColorChoice({
    required this.color,
    required this.selected,
    required this.label,
    required this.onTap,
    this.icon,
  });

  final Color color;
  final bool selected;
  final String label;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: label,
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected
                ? Theme.of(context).colorScheme.onSurface
                : Colors.transparent,
            width: 3,
          ),
        ),
        child: Icon(icon ?? (selected ? Icons.check : null)),
      ),
    ),
  );
}
