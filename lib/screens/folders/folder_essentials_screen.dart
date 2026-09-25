import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/folder.dart';
import '../../services/folder_io.dart';
import '../../state/app_state.dart';

/// All global-library items referenced by a folder draft.
class FolderEssentialsScreen extends StatefulWidget {
  const FolderEssentialsScreen({super.key, required this.folder});

  final Folder folder;

  @override
  State<FolderEssentialsScreen> createState() => _FolderEssentialsScreenState();
}

class _FolderEssentialsScreenState extends State<FolderEssentialsScreen> {
  bool _selecting = false;
  final Set<String> _selection = <String>{};

  /// null shows every kind dumped together; a kind narrows the flat list.
  FolderItemKind? _filter;

  String _key(FolderItemKind kind, String id) => '${kind.name}:$id';

  void _toggle(FolderItemKind kind, String id) {
    final key = _key(kind, id);
    setState(() {
      if (!_selection.remove(key)) _selection.add(key);
    });
  }

  void _remove(FolderItemKind kind, String id) {
    setState(() {
      switch (kind) {
        case FolderItemKind.character:
          widget.folder.characterIds.remove(id);
        case FolderItemKind.lorebook:
          widget.folder.lorebookIds.remove(id);
          widget.folder.lorebookOverrides.remove(id);
        case FolderItemKind.scenario:
          widget.folder.scenarioIds.remove(id);
          widget.folder.scenarioOverrides.remove(id);
        case FolderItemKind.preset:
          widget.folder.presetIds.remove(id);
          widget.folder.presetOverrides.remove(id);
          if (widget.folder.defaultPresetId == id) {
            widget.folder.defaultPresetId = null;
          }
        case FolderItemKind.provider:
          widget.folder.providerIds.remove(id);
          if (widget.folder.defaultProviderId == id) {
            widget.folder.defaultProviderId = null;
          }
        case FolderItemKind.document:
          widget.folder.documentIds.remove(id);
        case FolderItemKind.gallery:
          widget.folder.galleryImageIds.remove(id);
      }
      _selection.remove(_key(kind, id));
    });
  }

  Future<void> _removeSelected() async {
    if (_selection.isEmpty) return;
    final count = _selection.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $count item${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They stay in their libraries and are only removed from this folder.',
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
    for (final key in _selection.toList()) {
      final split = key.indexOf(':');
      final kind = FolderItemKind.values.byName(key.substring(0, split));
      _remove(kind, key.substring(split + 1));
    }
    if (mounted) {
      setState(() {
        _selecting = false;
        _selection.clear();
      });
    }
  }

  Future<void> _import(AppState state) async {
    final imported = await FolderIO.importFolder(context, state);
    if (imported == null || !mounted) return;
    setState(() {
      _merge(widget.folder.characterIds, imported.characterIds);
      _merge(widget.folder.lorebookIds, imported.lorebookIds);
      _merge(widget.folder.scenarioIds, imported.scenarioIds);
      _merge(widget.folder.presetIds, imported.presetIds);
      _merge(widget.folder.providerIds, imported.providerIds);
      _merge(widget.folder.documentIds, imported.documentIds);
      _merge(widget.folder.galleryImageIds, imported.galleryImageIds);
      widget.folder.defaultPresetId ??= imported.defaultPresetId;
      widget.folder.defaultProviderId ??= imported.defaultProviderId;
      widget.folder.presetOverrides.addAll(imported.presetOverrides);
      widget.folder.lorebookOverrides.addAll(imported.lorebookOverrides);
      widget.folder.scenarioOverrides.addAll(imported.scenarioOverrides);
    });
  }

  void _merge(List<String> target, Iterable<String> source) {
    for (final id in source) {
      if (!target.contains(id)) target.add(id);
    }
  }

  Future<void> _chooseKind(AppState state) async {
    final kind = await showModalBottomSheet<FolderItemKind>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final kind in FolderItemKind.values)
              ListTile(
                leading: Icon(_icon(kind)),
                title: Text(_title(kind)),
                onTap: () => Navigator.of(context).pop(kind),
              ),
          ],
        ),
      ),
    );
    if (kind != null && mounted) await _pickItems(state, kind);
  }

  Future<void> _pickItems(AppState state, FolderItemKind kind) async {
    final choices = _choices(state, kind);
    final current = _ids(kind).toSet();
    final picked = Set<String>.of(current);
    final search = TextEditingController();
    String query = '';
    final result = await showModalBottomSheet<Set<String>>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setSheetState) {
          final visible = choices
              .where((item) => item.label.toLowerCase().contains(query))
              .toList();
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
                      hintText: 'Search ${_title(kind).toLowerCase()}',
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
                    child: visible.isEmpty
                        ? const Center(child: Text('No matching items.'))
                        : ListView.builder(
                            itemCount: visible.length,
                            itemBuilder: (context, index) {
                              final item = visible[index];
                              return CheckboxListTile(
                                value: picked.contains(item.id),
                                title: Text(item.label),
                                onChanged: (value) => setSheetState(() {
                                  if (value ?? false) {
                                    picked.add(item.id);
                                  } else {
                                    picked.remove(item.id);
                                  }
                                }),
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => Navigator.of(context).pop(picked),
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
    setState(() {
      final ids = _ids(kind);
      for (final id in result) {
        if (!ids.contains(id)) ids.add(id);
      }
    });
  }

  List<String> _ids(FolderItemKind kind) => switch (kind) {
    FolderItemKind.character => widget.folder.characterIds,
    FolderItemKind.lorebook => widget.folder.lorebookIds,
    FolderItemKind.scenario => widget.folder.scenarioIds,
    FolderItemKind.preset => widget.folder.presetIds,
    FolderItemKind.provider => widget.folder.providerIds,
    FolderItemKind.document => widget.folder.documentIds,
    FolderItemKind.gallery => widget.folder.galleryImageIds,
  };

  List<_Choice> _choices(AppState state, FolderItemKind kind) => switch (kind) {
    FolderItemKind.character => [
      for (final item in state.characters) _Choice(item.id, item.displayName),
    ],
    FolderItemKind.lorebook => [
      for (final item in state.lorebooks) _Choice(item.id, item.displayName),
    ],
    FolderItemKind.scenario => [
      for (final item in state.scenarios) _Choice(item.id, item.displayName),
    ],
    FolderItemKind.preset => [
      for (final item in state.presets) _Choice(item.id, item.displayName),
    ],
    FolderItemKind.provider => [
      for (final item in state.providers) _Choice(item.id, item.displayName),
    ],
    FolderItemKind.document => [
      for (final item in state.documents) _Choice(item.id, item.displayName),
    ],
    FolderItemKind.gallery => [
      for (final item in state.gallery) _Choice(item.id, item.displayTitle),
    ],
  };

  /// Every referenced item across all kinds, in a stable order, as one flat
  /// list — narrowed to a single kind when a filter is set.
  List<({FolderItemKind kind, String id})> _entries() {
    const order = [
      FolderItemKind.lorebook,
      FolderItemKind.scenario,
      FolderItemKind.preset,
      FolderItemKind.provider,
      FolderItemKind.document,
      FolderItemKind.gallery,
      FolderItemKind.character,
    ];
    final out = <({FolderItemKind kind, String id})>[];
    for (final kind in order) {
      if (_filter != null && kind != _filter) continue;
      for (final id in _ids(kind).toList()) {
        out.add((kind: kind, id: id));
      }
    }
    return out;
  }

  Future<void> _pickFilter() async {
    final choice = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.clear_all),
              title: const Text('All items'),
              trailing: _filter == null ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop('all'),
            ),
            const Divider(height: 1),
            for (final kind in FolderItemKind.values)
              ListTile(
                leading: Icon(_icon(kind)),
                title: Text(_title(kind)),
                trailing: _filter == kind ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(kind),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    setState(() => _filter = choice is FolderItemKind ? choice : null);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final entries = _entries();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selecting ? '${_selection.length} selected' : 'Essentials',
        ),
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
        actions: [
          IconButton(
            tooltip: 'Import',
            onPressed: () => _import(state),
            icon: const Icon(Icons.upload_file_outlined),
          ),
          IconButton(
            tooltip: 'Export',
            onPressed: () =>
                FolderIO.exportFolder(context, widget.folder, state),
            icon: const Icon(Icons.download_outlined),
          ),
          IconButton(
            tooltip: 'Remove selected',
            onPressed: _selection.isEmpty ? null : _removeSelected,
            icon: const Icon(Icons.delete_outline),
          ),
          IconButton(
            tooltip: 'Select multiple',
            onPressed: () => setState(() => _selecting = true),
            icon: const Icon(Icons.checklist_outlined),
          ),
          IconButton(
            tooltip: _filter == null
                ? 'Filter by kind'
                : 'Filtered: ${_title(_filter!)}',
            onPressed: _pickFilter,
            icon: Icon(
              _filter == null ? Icons.filter_list : Icons.filter_list_alt,
              color: _filter == null
                  ? null
                  : Theme.of(context).colorScheme.primary,
            ),
          ),
          IconButton(
            tooltip: 'Add essentials',
            onPressed: () => _chooseKind(state),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
      body: entries.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _filter == null
                      ? 'Nothing added yet. Use + to add lorebooks, presets, '
                            'providers, pictures and more.'
                      : 'No ${_title(_filter!).toLowerCase()} in this folder.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: entries.length,
              itemBuilder: (context, index) {
                final entry = entries[index];
                return _itemTile(state, entry.kind, entry.id);
              },
            ),
    );
  }

  Widget _itemTile(AppState state, FolderItemKind kind, String id) {
    final label = _choices(
      state,
      kind,
    ).where((item) => item.id == id).map((item) => item.label).firstOrNull;
    final selected = _selection.contains(_key(kind, id));
    final isDefault = kind == FolderItemKind.preset
        ? widget.folder.defaultPresetId == id
        : kind == FolderItemKind.provider
        ? widget.folder.defaultProviderId == id
        : false;
    return ListTile(
      leading: _selecting
          ? Icon(
              selected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: selected ? Theme.of(context).colorScheme.primary : null,
            )
          : Icon(_icon(kind)),
      title: Text(label ?? 'Missing item'),
      subtitle: label == null ? Text(id) : null,
      onTap: _selecting ? () => _toggle(kind, id) : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (kind == FolderItemKind.preset || kind == FolderItemKind.provider)
            IconButton(
              tooltip: isDefault ? 'Clear default' : 'Make default',
              onPressed: () => setState(() {
                if (kind == FolderItemKind.preset) {
                  widget.folder.defaultPresetId = isDefault ? null : id;
                } else {
                  widget.folder.defaultProviderId = isDefault ? null : id;
                }
              }),
              icon: Icon(isDefault ? Icons.star : Icons.star_border),
            ),
          if (!_selecting)
            IconButton(
              tooltip: 'Remove from folder',
              onPressed: () => _remove(kind, id),
              icon: const Icon(Icons.remove_circle_outline),
            ),
        ],
      ),
    );
  }
}

class _Choice {
  const _Choice(this.id, this.label);
  final String id;
  final String label;
}

String _title(FolderItemKind kind) => switch (kind) {
  FolderItemKind.character => 'Characters',
  FolderItemKind.lorebook => 'Lorebooks',
  FolderItemKind.scenario => 'Scenarios',
  FolderItemKind.preset => 'Presets',
  FolderItemKind.provider => 'Providers',
  FolderItemKind.document => 'Embeddings / Documents',
  FolderItemKind.gallery => 'Pictures',
};

IconData _icon(FolderItemKind kind) => switch (kind) {
  FolderItemKind.character => Icons.person_outline,
  FolderItemKind.lorebook => Icons.menu_book_outlined,
  FolderItemKind.scenario => Icons.theater_comedy_outlined,
  FolderItemKind.preset => Icons.tune_outlined,
  FolderItemKind.provider => Icons.cloud_outlined,
  FolderItemKind.document => Icons.description_outlined,
  FolderItemKind.gallery => Icons.photo_outlined,
};
