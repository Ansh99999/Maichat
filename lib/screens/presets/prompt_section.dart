import 'package:flutter/material.dart';

import '../../models/preset.dart';
import '../../models/prompt_block.dart';
import 'prompt_block_edit_sheet.dart';

/// The "Prompt" section: SillyTavern's prompt-block system. An ordered,
/// reorderable list of blocks, each toggled on/off, with markers filled from
/// live data at send time. Tap a block to edit it; add custom blocks; drag to
/// reorder.
class PromptSection extends StatefulWidget {
  const PromptSection({super.key, required this.preset, required this.onChanged});

  final Preset preset;
  final VoidCallback onChanged;

  @override
  State<PromptSection> createState() => _PromptSectionState();
}

class _PromptSectionState extends State<PromptSection> {
  Preset get _p => widget.preset;

  void _persist() => widget.onChanged();

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final entry = _p.promptOrder.removeAt(oldIndex);
      _p.promptOrder.insert(newIndex, entry);
    });
    _persist();
  }

  Future<void> _edit(PromptBlock block) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PromptBlockEditPage(block: block, onChanged: _persist),
      ),
    );
    if (mounted) setState(() {});
  }

  void _addBlock() {
    final block = PromptBlock(
      identifier: 'user_${DateTime.now().microsecondsSinceEpoch}',
      name: 'New block',
      role: 'system',
    );
    setState(() {
      _p.prompts.add(block);
      _p.promptOrder.add(PromptOrderEntry(identifier: block.identifier, enabled: true));
    });
    _persist();
    _edit(block);
  }

  void _delete(PromptOrderEntry entry, PromptBlock block) {
    setState(() {
      _p.promptOrder.removeWhere((e) => e.identifier == entry.identifier);
      _p.prompts.removeWhere((b) => b.identifier == block.identifier);
    });
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          buildDefaultDragHandles: false,
          itemCount: _p.promptOrder.length,
          onReorderItem: _reorder,
          itemBuilder: (context, index) {
            final entry = _p.promptOrder[index];
            final block = _p.blockById(entry.identifier);
            if (block == null) {
              return SizedBox.shrink(key: ValueKey('missing_${entry.identifier}'));
            }
            final isMain = block.identifier == PromptId.main;
            return _BlockRow(
              key: ValueKey(entry.identifier),
              index: index,
              block: block,
              enabled: entry.enabled,
              // `main` is always sent (SillyTavern parity), so its toggle is off-limits.
              canToggle: !isMain,
              canDelete: !block.systemPrompt,
              onToggle: (v) {
                setState(() => entry.enabled = v);
                _persist();
              },
              onTap: () => _edit(block),
              onDelete: () => _delete(entry, block),
            );
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _addBlock,
            icon: const Icon(Icons.add),
            label: const Text('Add block'),
          ),
        ),
        Text(
          'Markers (italic) are filled from live data at send time. '
          'Disabled blocks are skipped.',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// One draggable block row: drag handle, on/off switch, name + role, and an
/// optional delete button for user-created blocks.
class _BlockRow extends StatelessWidget {
  const _BlockRow({
    super.key,
    required this.index,
    required this.block,
    required this.enabled,
    required this.canToggle,
    required this.canDelete,
    required this.onToggle,
    required this.onTap,
    required this.onDelete,
  });

  final int index;
  final PromptBlock block;
  final bool enabled;
  final bool canToggle;
  final bool canDelete;
  final ValueChanged<bool> onToggle;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final subtitle = block.marker ? 'marker · ${block.role}' : block.role;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      onTap: onTap,
      leading: ReorderableDragStartListener(
        index: index,
        child: const Icon(Icons.drag_indicator),
      ),
      title: Text(
        block.name.isEmpty ? block.identifier : block.name,
        style: TextStyle(
          fontStyle: block.marker ? FontStyle.italic : FontStyle.normal,
          color: enabled ? null : theme.colorScheme.onSurfaceVariant,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(subtitle),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (canDelete)
            IconButton(
              tooltip: 'Delete block',
              icon: const Icon(Icons.delete_outline),
              onPressed: onDelete,
            ),
          Switch(
            value: enabled,
            onChanged: canToggle ? onToggle : null,
          ),
        ],
      ),
    );
  }
}
