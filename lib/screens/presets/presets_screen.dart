import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/preset.dart';
import '../../services/preset_io.dart';
import '../../state/app_state.dart';
import '../../widgets/app_drawer.dart';
import 'preset_edit_screen.dart';

/// The Presets area: a search bar, New/Import actions, and the preset list.
/// Each row carries a colour band and a copy / download / delete menu. Modelled
/// on Agnaistic's presets page.
class PresetsScreen extends StatefulWidget {
  const PresetsScreen({super.key});

  @override
  State<PresetsScreen> createState() => _PresetsScreenState();
}

class _PresetsScreenState extends State<PresetsScreen> {
  String _query = '';

  void _open(BuildContext context, Preset preset) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => PresetEditScreen(presetId: preset.id)),
    );
  }

  Future<void> _new(BuildContext context) async {
    final state = context.read<AppState>();
    final preset = Preset.create();
    await state.addPreset(preset);
    if (context.mounted) _open(context, preset);
  }

  Future<void> _import(BuildContext context) async {
    final state = context.read<AppState>();
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Import preset',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
    } catch (_) {
      result = null;
    }
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null) return;
    if (!context.mounted) return;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) {
        throw const FormatException('Not a preset object.');
      }
      final preset = importPreset(json);
      await state.addPreset(preset);
      if (context.mounted) {
        _toast(context, 'Imported "${preset.displayName}" (${_formatLabel(detectFormat(json))}).');
        _open(context, preset);
      }
    } on FormatException catch (e) {
      if (context.mounted) _toast(context, 'Could not import: ${e.message}');
    } catch (_) {
      if (context.mounted) _toast(context, 'Could not read that file as a preset.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final q = _query.trim().toLowerCase();
    final presets = [
      for (final p in state.presets)
        if (q.isEmpty || p.displayName.toLowerCase().contains(q)) p,
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Presets')),
      drawer: const AppDrawer(selected: DrawerSection.presets),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              children: [
                SearchBar(
                  hintText: 'Search presets',
                  leading: const Icon(Icons.search),
                  onChanged: (v) => setState(() => _query = v),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => _new(context),
                        icon: const Icon(Icons.add),
                        label: const Text('New preset'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => _import(context),
                        icon: const Icon(Icons.file_upload_outlined),
                        label: const Text('Import'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: presets.isEmpty
                ? _empty(context)
                : ListView(
                    padding: EdgeInsets.only(
                      bottom: 24 + MediaQuery.paddingOf(context).bottom,
                    ),
                    children: [
                      for (final preset in presets)
                        _PresetTile(
                          preset: preset,
                          isDefault: preset.id == state.defaultPresetId,
                          onTap: () => _open(context, preset),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = _query.trim().isEmpty
        ? 'Create one, or import a SillyTavern or Agnai preset.'
        : 'No presets match "$_query".';
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.tune_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No presets', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              message,
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

// PLACEHOLDER_TILE
/// One preset row: a colour band, the name, a provider/model + block-count
/// subtitle, a default marker, and a copy / download / delete overflow menu.
class _PresetTile extends StatelessWidget {
  const _PresetTile({
    required this.preset,
    required this.isDefault,
    required this.onTap,
  });

  final Preset preset;
  final bool isDefault;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final model = preset.model.trim();
    final subtitle = [
      if (model.isNotEmpty) model else 'no model',
      '${preset.prompts.length} blocks',
    ].join(' · ');

    // The preset's colour tints the whole row background (a gentle blend over
    // the surface so text stays legible in light and dark).
    final tint = preset.colorBand != null
        ? Color.alphaBlend(
            Color(preset.colorBand!).withValues(alpha: 0.16),
            scheme.surface,
          )
        : scheme.surfaceContainerLow;

    return Card(
      elevation: 0,
      color: tint,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        title: Row(
          children: [
            Flexible(
              child: Text(
                preset.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isDefault) ...[
              const SizedBox(width: 8),
              _DefaultChip(),
            ],
          ],
        ),
        subtitle: Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          onSelected: (v) => _onAction(context, v),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'copy', child: Text('Duplicate')),
            PopupMenuItem(value: 'download', child: Text('Download')),
            PopupMenuItem(value: 'default', child: Text('Set as default')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }

  Future<void> _onAction(BuildContext context, String action) async {
    final state = context.read<AppState>();
    switch (action) {
      case 'copy':
        final copy = await state.duplicatePreset(preset);
        if (context.mounted) _toast(context, 'Duplicated as "${copy.displayName}".');
      case 'default':
        await state.setDefaultPreset(preset.id);
        if (context.mounted) _toast(context, '"${preset.displayName}" is now the default.');
      case 'delete':
        await _confirmDelete(context, state);
      case 'download':
        await _download(context);
    }
  }

  Future<void> _confirmDelete(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete preset?'),
        content: Text('"${preset.displayName}" will be removed.'),
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
    if (ok ?? false) await state.deletePreset(preset.id);
  }

  Future<void> _download(BuildContext context) async {
    final format = await showModalBottomSheet<PresetFormat>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.forum_outlined),
              title: const Text('SillyTavern preset'),
              subtitle: const Text('prompts + prompt_order, OpenAI-style keys'),
              onTap: () => Navigator.of(context).pop(PresetFormat.sillyTavern),
            ),
            ListTile(
              leading: const Icon(Icons.smart_toy_outlined),
              title: const Text('Agnai preset'),
              subtitle: const Text('GenSettings shape'),
              onTap: () => Navigator.of(context).pop(PresetFormat.agnai),
            ),
            ListTile(
              leading: const Icon(Icons.data_object_outlined),
              title: const Text('MaiChat (native)'),
              subtitle: const Text('lossless superset'),
              onTap: () => Navigator.of(context).pop(PresetFormat.native),
            ),
          ],
        ),
      ),
    );
    if (format == null || !context.mounted) return;
    final map = switch (format) {
      PresetFormat.sillyTavern => exportSillyTavern(preset),
      PresetFormat.agnai => exportAgnai(preset),
      _ => exportNative(preset),
    };
    final json = const JsonEncoder.withIndent('  ').convert(map);
    String? path;
    try {
      path = await FilePicker.saveFile(
        dialogTitle: 'Save preset',
        fileName: '${_safeName(preset.displayName)}.json',
        bytes: Uint8List.fromList(utf8.encode(json)),
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
    } catch (_) {
      path = null;
    }
    if (!context.mounted) return;
    if (path == null) {
      // Desktop/mobile that returns no path: fall back to the clipboard.
      await Clipboard.setData(ClipboardData(text: json));
      if (context.mounted) _toast(context, 'Copied preset JSON to clipboard.');
    } else {
      _toast(context, 'Saved to $path');
    }
  }
}

class _DefaultChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        'default',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
            ),
      ),
    );
  }
}

String _safeName(String s) => s
    .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '_');

String _formatLabel(PresetFormat f) => switch (f) {
      PresetFormat.sillyTavern => 'SillyTavern',
      PresetFormat.agnai => 'Agnai',
      PresetFormat.native => 'MaiChat',
      PresetFormat.unknown => 'unknown',
    };

void _toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
  );
}
