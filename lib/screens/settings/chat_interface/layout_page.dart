import 'package:flutter/material.dart';

import '../../../models/chat_interface.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import '../setting_highlight.dart';
import 'controls.dart';
import 'spoke.dart';

/// Everything that decides the shape of a turn: bubbles or a flat document,
/// where the text sits, how wide it runs, and the gap between one turn and the
/// next — plus how visible the two buttons floating over a conversation are.
///
/// The floating buttons were a section of their own on the old single page. They
/// are a subhead here: what they control is the layout of the chat, and there
/// were never enough of them to justify a heading of their own in a list.
class LayoutSpokePage extends StatelessWidget {
  const LayoutSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Layout & spacing',
          scope: scope,
          resetLabel: 'Reset layout to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              bubbles: d.bubbles,
              textPlacement: d.textPlacement,
              contentWidth: d.contentWidth,
              bubbleOpacity: d.bubbleOpacity,
              messageSpacing: d.messageSpacing,
              menuButtonOpacity: d.menuButtonOpacity,
              jumpButtonOpacity: d.jumpButtonOpacity,
              looksButtonEnabled: d.looksButtonEnabled,
              looksButtonOpacity: d.looksButtonOpacity,
            ));
            notifySetting(context, 'Layout back to defaults');
          },
          children: _children(context, ui, update),
        ),
      );
  List<Widget> _children(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) =>
      [
        SettingHighlight(
          active: highlight == SettingAnchor.textPlacement,
          child: SettingSwitch(
            icon: Icons.chat_bubble_outline,
            title: 'Bubbles',
            subtitle: ui.bubbles
                ? 'Tinted bubbles per turn'
                : 'Flat "document" style, no bubbles',
            value: ui.bubbles,
            onChanged: (v) => update(ui.copyWith(bubbles: v)),
          ),
        ),
        SettingEnumRow<TextPlacement>(
          icon: Icons.view_agenda_outlined,
          label: 'Text placement',
          value: ui.textPlacement,
          values: TextPlacement.values,
          labelOf: (p) => p.label,
          onChanged: (p) => update(ui.copyWith(textPlacement: p)),
        ),
        SettingEnumRow<ContentWidth>(
          icon: Icons.width_normal_outlined,
          label: 'Content width',
          value: ui.contentWidth,
          values: ContentWidth.values,
          labelOf: (w) => w.label,
          onChanged: (w) {
            update(ui.copyWith(contentWidth: w));
            notifySetting(context, 'Content width: ${w.label.toLowerCase()}');
          },
        ),
        if (ui.bubbles)
          SettingSlider(
            icon: Icons.opacity_outlined,
            label: 'Bubble opacity',
            value: ui.bubbleOpacity,
            min: 0.2,
            max: 1,
            suffix: '${(ui.bubbleOpacity * 100).round()}%',
            onChanged: (v) => update(ui.copyWith(bubbleOpacity: v)),
          ),
        SettingHighlight(
          active: highlight == SettingAnchor.spacing,
          child: SettingSlider(
            icon: Icons.height_outlined,
            label: 'Message spacing',
            value: ui.messageSpacing,
            min: kMinMessageSpacing,
            max: kMaxMessageSpacing,
            suffix: '${ui.messageSpacing.round()} px',
            onChanged: (v) =>
                update(ui.copyWith(messageSpacing: v.roundToDouble())),
          ),
        ),
        const Divider(height: 24),
        settingHeader(context, 'Floating buttons'),
        settingNote(
          context,
          'The buttons that float over a conversation: the menu square at the '
          'top-left, the looks square at the top-right, and the arrow at the '
          'bottom-right that jumps to the newest turn. Turn any of them down to '
          'let the chat read through it — or put the looks square away entirely.',
        ),
        SettingHighlight(
          active: highlight == SettingAnchor.floatingButtons,
          child: Column(
            children: [
              SettingSlider(
                icon: Icons.menu,
                label: 'Menu button opacity',
                value: ui.menuButtonOpacity,
                min: kMinChromeOpacity,
                max: kMaxChromeOpacity,
                suffix: '${(ui.menuButtonOpacity * 100).round()}%',
                onChanged: (v) => update(ui.copyWith(menuButtonOpacity: v)),
              ),
              SettingSwitch(
                icon: Icons.style_outlined,
                title: 'Looks button',
                subtitle: ui.looksButtonEnabled
                    ? 'A square at the top-right that switches between saved '
                        'looks'
                    : 'Off — saved looks are still in Settings ▸ Chat Interface',
                value: ui.looksButtonEnabled,
                onChanged: (v) {
                  update(ui.copyWith(looksButtonEnabled: v));
                  notifySetting(
                      context, v ? 'Looks button shown' : 'Looks button hidden');
                },
              ),
              if (ui.looksButtonEnabled)
                SettingSlider(
                  icon: Icons.style_outlined,
                  label: 'Looks button opacity',
                  value: ui.looksButtonOpacity,
                  min: kMinChromeOpacity,
                  max: kMaxChromeOpacity,
                  suffix: '${(ui.looksButtonOpacity * 100).round()}%',
                  onChanged: (v) => update(ui.copyWith(looksButtonOpacity: v)),
                ),
              SettingSlider(
                icon: Icons.arrow_downward,
                label: 'Jump-to-latest opacity',
                value: ui.jumpButtonOpacity,
                min: kMinChromeOpacity,
                max: kMaxChromeOpacity,
                suffix: '${(ui.jumpButtonOpacity * 100).round()}%',
                onChanged: (v) => update(ui.copyWith(jumpButtonOpacity: v)),
              ),
            ],
          ),
        ),
      ];
}


