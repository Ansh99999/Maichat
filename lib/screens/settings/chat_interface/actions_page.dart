import 'package:flutter/material.dart';

import '../../../models/chat_interface.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import '../setting_highlight.dart';
import 'controls.dart';
import 'spoke.dart';

/// Which of a turn's actions sit as icons beside it and which hide behind the
/// three-dot menu, and in what order — mirroring Agnai's `msgOptsInline`.
class ActionsSpokePage extends StatelessWidget {
  const ActionsSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Message actions',
          scope: scope,
          resetLabel: 'Reset actions to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              messageActionsEnabled: d.messageActionsEnabled,
              messageActions: d.messageActions,
              actionBarPlacement: d.actionBarPlacement,
            ));
            notifySetting(context, 'Actions back to defaults');
          },
          children: [
            SettingHighlight(
              active: highlight == SettingAnchor.messageActions,
              child: _Section(ui: ui, update: update),
            ),
          ],
        ),
      );
}
/// The master toggle plus a reorderable list where each action is placed either
/// inline (an icon beside the message) or behind the three-dot overflow. Drag to
/// reorder.
class _Section extends StatelessWidget {
  const _Section({required this.ui, required this.update});

  final ChatInterface ui;
  final void Function(ChatInterface) update;

  void _setInline(BuildContext context, MessageAction action, bool inline) {
    final next = [
      for (final p in ui.messageActions)
        p.action == action ? p.copyWith(inline: inline) : p,
    ];
    update(ui.copyWith(messageActions: next));
    notifySetting(
        context, '${action.label} → ${inline ? 'inline' : 'menu'}');
  }

  void _reorder(int oldIndex, int newIndex) {
    final list = [...ui.messageActions];
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    update(ui.copyWith(messageActions: list));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        SettingSwitch(
          icon: Icons.more_horiz,
          title: 'Show action buttons',
          subtitle:
              'Inline actions beside each message; the rest under a ⋮ menu',
          value: ui.messageActionsEnabled,
          onChanged: (v) {
            update(ui.copyWith(messageActionsEnabled: v));
            notifySetting(
                context, v ? 'Action buttons shown' : 'Action buttons hidden');
          },
        ),
        if (ui.messageActionsEnabled) ...[
          SettingEnumRow<ActionBarPlacement>(
            icon: Icons.place_outlined,
            label: 'Placement',
            value: ui.actionBarPlacement,
            values: ActionBarPlacement.values,
            labelOf: (p) => p.label,
            onChanged: (p) {
              update(ui.copyWith(actionBarPlacement: p));
              notifySetting(context, 'Actions ${p.label.toLowerCase()}');
            },
          ),
          ReorderableListView(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            onReorderItem: _reorder,
            children: [
              for (var i = 0; i < ui.messageActions.length; i++)
                _actionRow(context, scheme, ui.messageActions[i], i),
            ],
          ),
        ],
      ],
    );
  }

  Widget _actionRow(BuildContext context, ColorScheme scheme,
      MessageActionPref pref, int index) {
    final action = pref.action;
    return Padding(
      key: ValueKey(action),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Row(
        children: [
          Icon(action.icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 14),
          Expanded(child: Text(action.label)),
          SegmentedButton<bool>(
            style: const ButtonStyle(
              visualDensity: VisualDensity.compact,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: true, label: Text('Inline')),
              ButtonSegment(value: false, label: Text('Menu')),
            ],
            selected: {pref.inline},
            onSelectionChanged: (s) => _setInline(context, action, s.first),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Icon(Icons.drag_handle, color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}


