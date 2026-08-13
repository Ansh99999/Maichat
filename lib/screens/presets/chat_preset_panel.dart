import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/preset.dart';
import '../../state/app_state.dart';
import 'preset_editor_body.dart';

/// The in-sidebar preset experience for the chat screen: a searchable list of
/// presets (the chat's current one marked), a left button to make one current,
/// and — on tapping a preset — a compact editor with a Save button that asks
/// whether to save for just this chat or the whole preset.
class ChatPresetPanel extends StatefulWidget {
  const ChatPresetPanel({super.key, required this.onBack});

  /// Return to the drawer's main menu.
  final VoidCallback onBack;

  @override
  State<ChatPresetPanel> createState() => _ChatPresetPanelState();
}

class _ChatPresetPanelState extends State<ChatPresetPanel> {
  String _query = '';
  Preset? _editing; // a working copy; non-null means the editor is open

  void _choose(AppState state, Preset preset) {
    state.setConversationPreset(state.active.id, preset.id);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Preset changed to "${preset.displayName}"'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _save(AppState state) async {
    final preset = _editing;
    if (preset == null) return;
    final scope = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save preset'),
        content: const Text(
          'Apply your changes to just this chat, or to the whole preset '
          '(everywhere it is used)?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('chat'),
            child: const Text('This chat only'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('all'),
            child: const Text('Entire preset'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
    if (scope == null || !mounted) return;
    final conversationId = state.active.id;
    if (scope == 'chat') {
      await state.saveChatPresetOverride(conversationId, preset);
    } else {
      await state.savePresetToLibrary(conversationId, preset);
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(scope == 'chat' ? 'Saved for this chat' : 'Preset updated'),
        duration: const Duration(seconds: 2),
      ),
    );
    setState(() => _editing = null);
  }

  @override
  Widget build(BuildContext context) {
    return _editing == null ? _list(context) : _editor(context);
  }

  // PLACEHOLDER_PANEL
  Widget _list(BuildContext context) {
    final state = context.watch<AppState>();
    final current = state.presetFor(state.active);
    final q = _query.trim().toLowerCase();
    final presets = [
      for (final p in state.presets)
        if (q.isEmpty || p.displayName.toLowerCase().contains(q)) p,
    ];

    return Column(
      children: [
        _PanelHeader(title: 'Presets', onBack: widget.onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: SearchBar(
            hintText: 'Search presets',
            leading: const Icon(Icons.search, size: 20),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        Expanded(
          child: presets.isEmpty
              ? const Center(child: Text('No presets'))
              : ListView(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  children: [
                    for (final p in presets)
                      _PresetRow(
                        preset: p,
                        isCurrent: current?.id == p.id,
                        onChoose: () => _choose(state, p),
                        // Seed the editor from the EFFECTIVE preset for the
                        // current chat (which may be a chat-specific override),
                        // not the bare library copy — otherwise a "this chat"
                        // save is invisible on re-open and looks like it reverted.
                        onEdit: () => setState(
                          () => _editing = Preset.fromJson(
                            (current?.id == p.id ? current! : p).toJson(),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _editor(BuildContext context) {
    final preset = _editing!;
    return Column(
      children: [
        _PanelHeader(
          title: preset.displayName,
          onBack: () => setState(() => _editing = null),
          trailing: FilledButton(
            onPressed: () => _save(context.read<AppState>()),
            child: const Text('Save'),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: PresetEditorBody(
            key: ValueKey(preset.id),
            preset: preset,
            compact: true,
            onChanged: () => setState(() {}),
          ),
        ),
      ],
    );
  }
}

/// A back-arrow + title (+ optional trailing) bar for the panel's sub-views.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.onBack, this.trailing});

  final String title;
  final VoidCallback onBack;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Back',
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// One preset row in the panel list: a left "make current" button, the name (+
/// a "current" chip), and a tap target that opens the compact editor.
class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.preset,
    required this.isCurrent,
    required this.onChoose,
    required this.onEdit,
  });

  final Preset preset;
  final bool isCurrent;
  final VoidCallback onChoose;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = preset.colorBand != null
        ? Color.alphaBlend(Color(preset.colorBand!).withValues(alpha: 0.16), scheme.surface)
        : scheme.surfaceContainerLow;
    return Card(
      elevation: 0,
      color: tint,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onEdit,
        leading: IconButton(
          tooltip: isCurrent ? 'Current preset' : 'Use this preset',
          icon: Icon(
            isCurrent ? Icons.radio_button_checked : Icons.radio_button_unchecked,
            color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
          ),
          onPressed: onChoose,
        ),
        title: Row(
          children: [
            Flexible(
              child: Text(
                preset.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isCurrent) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  'current',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: scheme.onSecondaryContainer),
                ),
              ),
            ],
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
      ),
    );
  }
}
