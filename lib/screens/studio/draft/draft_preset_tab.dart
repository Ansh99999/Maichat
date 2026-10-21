import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../models/preset.dart';
import '../../../services/studio/studio_controller.dart';
import '../../presets/preset_editor_body.dart';
import '../../presets/preset_pickers.dart';
import 'draft_widgets.dart';

/// The generation preset held by the Studio. Selection and editing only change
/// the draft; Apply is the point at which the shared library is updated.
class DraftPresetTab extends StatelessWidget {
  const DraftPresetTab({super.key, required this.controller});

  final StudioController controller;

  bool _canAccept(BuildContext context, int version) {
    if (!context.mounted) return false;
    final String message;
    if (controller.running) {
      message = 'Hand edits wait until the Studio finishes.';
    } else if (controller.session.draftVersion != version) {
      message =
          'The draft changed while this window was open. Open it again '
          'to use the latest draft.';
    } else {
      return true;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
    return false;
  }

  Future<void> _choose(BuildContext context) async {
    if (controller.running) return;
    final version = controller.session.draftVersion;
    final chosen = await showSearchPicker(
      context: context,
      title: 'Choose Studio preset',
      entries: [
        for (final preset in controller.state.presets)
          PickerEntry(
            id: preset.id,
            title: preset.displayName,
            subtitle: preset.model.trim().isEmpty
                ? 'Uses the provider’s default model'
                : preset.model.trim(),
          ),
      ],
      selectedId: controller.session.workspace.preset?.id,
    );
    if (!context.mounted) return;
    if (chosen == null || !_canAccept(context, version)) return;
    final stored = controller.state.presetById(chosen);
    if (stored == null) return;
    controller.editByHand(
      'Selected preset "${stored.displayName}" by hand',
      (ws) => ws.preset = stored.clone(),
    );
  }

  Future<void> _edit(BuildContext context) async {
    if (controller.running) return;
    final preset = controller.session.workspace.preset;
    if (preset == null) return;
    final version = controller.session.draftVersion;
    final before = jsonEncode(preset.toJson());
    final working = preset.clone();
    final edited = await Navigator.of(context).push<Preset>(
      MaterialPageRoute(
        builder: (_) => _StudioPresetEditor(
          controller: controller,
          preset: working,
          version: version,
        ),
      ),
    );
    if (!context.mounted) return;
    if (edited == null || !_canAccept(context, version)) return;
    if (jsonEncode(edited.toJson()) == before) return;
    controller.editByHand(
      'Edited preset "${edited.displayName}" by hand',
      (ws) => ws.preset = edited.clone(),
    );
  }

  void _clear() {
    if (controller.running) return;
    final preset = controller.session.workspace.preset;
    if (preset == null) return;
    controller.editByHand(
      'Cleared preset "${preset.displayName}" from the draft',
      (ws) => ws.preset = null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final preset = controller.session.workspace.preset;
    final locked = controller.running;
    final theme = Theme.of(context);
    return ListView(
      key: const PageStorageKey('draft-preset'),
      padding: draftListPadding(context),
      children: [
        if (locked) const DraftLockedNote(),
        const DraftSectionLabel('Generation preset', first: true),
        if (preset == null)
          const DraftEmpty(
            icon: Icons.tune,
            text:
                'No Studio preset selected. Playtests use the app’s active '
                'preset until you choose one.',
          )
        else
          DraftCard(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 8, 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preset.displayName,
                            style: theme.textTheme.titleLarge,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            preset.useMaxContext
                                ? 'Model maximum context · '
                                      '${preset.maxResponseTokens} response tokens'
                                : '${preset.maxContext} context tokens · '
                                      '${preset.maxResponseTokens} response tokens',
                            style: theme.textTheme.bodyMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Temperature ${preset.temperature} · '
                            'Top P ${preset.topP}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit Studio preset',
                      onPressed: locked ? null : () => _edit(context),
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                  ],
                ),
              ),
              ListTile(
                leading: const Icon(Icons.clear),
                title: const Text('Clear selection'),
                enabled: !locked,
                onTap: locked ? null : _clear,
              ),
            ],
          ),
        DraftAddButton(
          label: preset == null ? 'Choose preset' : 'Choose another preset',
          icon: Icons.tune,
          onPressed: locked ? null : () => _choose(context),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            kDraftGutter + 4,
            20,
            kDraftGutter,
            0,
          ),
          child: Text(
            preset == null
                ? 'Choosing a preset makes a private Studio copy. Your shared '
                      'preset library only changes when you Apply to library.'
                : 'Playtests use the Studio copy. Your shared preset library '
                      'only changes when you Apply to library.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _StudioPresetEditor extends StatelessWidget {
  const _StudioPresetEditor({
    required this.controller,
    required this.preset,
    required this.version,
  });

  final StudioController controller;
  final Preset preset;
  final int version;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final stale = controller.session.draftVersion != version;
      final locked = controller.running;
      final disabled = locked || stale;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Edit Studio preset'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: disabled
                  ? null
                  : () => Navigator.of(context).pop(preset),
              child: const Text('Save'),
            ),
          ],
        ),
        body: Column(
          children: [
            if (stale)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'The draft changed while this editor was open. '
                  'Cancel and reopen it to edit the latest draft.',
                ),
              )
            else if (locked)
              const DraftLockedNote(),
            Expanded(
              child: ExcludeFocus(
                excluding: disabled,
                child: AbsorbPointer(
                  absorbing: disabled,
                  child: PresetEditorBody(
                    key: ValueKey(preset.id),
                    preset: preset,
                    onChanged: () {},
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
