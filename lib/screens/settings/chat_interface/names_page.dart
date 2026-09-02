import 'package:flutter/material.dart';

import '../../../models/chat_interface.dart';
import '../../../widgets/font_picker_row.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import '../setting_highlight.dart';
import 'controls.dart';
import 'spoke.dart';

/// One sender-name editor serving both roles.
///
/// Unlike avatars there is nothing role-specific for a synced write to preserve
/// — `ChatInterface.withName` mirrors the whole style — so while the two are
/// synced the selector would be a control with no effect, and it is hidden.
class NamesSpokePage extends StatefulWidget {
  const NamesSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  State<NamesSpokePage> createState() => _NamesSpokePageState();
}

class _NamesSpokePageState extends State<NamesSpokePage> {
  bool _isUser = false;

  String get _role => _isUser ? 'Your name' : 'Character name';

  /// Why a "below" name will not land under the avatar in the current layout, or
  /// null when it will. Said out loud, because a silent fallback is
  /// indistinguishable from a broken setting.
  String? _belowNote(ChatInterface ui) {
    final avatar = ui.avatarFor(_isUser);
    if (!avatar.show) {
      return 'This avatar is hidden, so a "below" name sits under the message.';
    }
    if (ui.textPlacement == TextPlacement.around) {
      return 'Text wraps around the avatar in this layout, so there is no '
          'avatar bottom to hang from — a "below" name sits under the message.';
    }
    return null;
  }
  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: widget.scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Names',
          scope: widget.scope,
          resetLabel: 'Reset names to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              showNames: d.showNames,
              syncNames: d.syncNames,
              botNameStyle: d.botNameStyle,
              userNameStyle: d.userNameStyle,
            ));
            notifySetting(context, 'Names back to defaults');
          },
          children: _children(context, ui, update),
        ),
      );

  List<Widget> _children(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) {
    final style = ui.nameFor(_isUser);
    void write(NameStyle next) => update(ui.withName(_isUser, next));

    return [
      SettingSwitch(
        icon: Icons.badge_outlined,
        title: 'Show names',
        subtitle: 'Label each turn with its sender',
        value: ui.showNames,
        onChanged: (v) => update(ui.copyWith(showNames: v)),
      ),
      if (!ui.showNames)
        settingNote(context,
            'Names are off, so nothing below is on screen right now.'),
      if (ui.showNames) ...[
        SettingSwitch(
          icon: Icons.link_outlined,
          title: 'Sync the two',
          subtitle: 'One style for both names',
          value: ui.syncNames,
          onChanged: (v) {
            // Adopting sync copies the character's look onto both, so the two
            // names don't stay silently out of step.
            final next = ui.copyWith(syncNames: v);
            update(v ? next.copyWith(userNameStyle: ui.botNameStyle) : next);
            notifySetting(context, v ? 'Names synced' : 'Names independent');
          },
        ),
        if (!ui.syncNames)
          SettingEnumRow<bool>(
            icon: Icons.people_outline,
            label: 'Whose name',
            value: _isUser,
            values: const [false, true],
            labelOf: (v) => v ? 'You' : 'Character',
            onChanged: (v) => setState(() => _isUser = v),
          ),
        const Divider(height: 24),
        SettingHighlight(
          active: widget.highlight == SettingAnchor.names,
          child: SettingSizeField(
            icon: Icons.format_size_outlined,
            label: 'Name size',
            value: style.size,
            min: kMinNameSize,
            sliderMax: kMaxNameSize,
            hardMax: kMaxNameSize,
            unit: 'px',
            onChanged: (v) => write(style.copyWith(size: v)),
            onChangeEnd: (v) =>
                notifySetting(context, '$_role size ${v.round()} px'),
          ),
        ),
        FontPickerRow(
          title: 'Font',
          pickerTitle: '$_role font',
          fontFamily: style.fontFamily,
          systemLabel: 'Same as app font',
          systemSubtitle: 'Inherit the app-wide font',
          onChanged: (family) {
            write(style.copyWith(fontFamily: family));
            notifySetting(context, '$_role font: ${family ?? 'app font'}');
          },
        ),
        SettingEnumRow<NameAlign>(
          icon: Icons.format_align_center_outlined,
          label: 'Alignment (across the screen)',
          value: style.align,
          values: NameAlign.values,
          labelOf: (a) => a.label,
          onChanged: (a) {
            write(style.copyWith(align: a));
            notifySetting(context, '$_role aligned ${a.label.toLowerCase()}');
          },
        ),
        SettingEnumRow<NamePosition>(
          icon: Icons.vertical_align_top_outlined,
          label: 'Position (above the message / below the avatar)',
          value: style.position,
          values: NamePosition.values,
          labelOf: (p) => p.label,
          onChanged: (p) {
            write(style.copyWith(position: p));
            notifySetting(
              context,
              p == NamePosition.above
                  ? '$_role above the message'
                  : '$_role below the avatar',
            );
          },
        ),
        if (style.position == NamePosition.below && _belowNote(ui) != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(52, 0, 16, 8),
            child: Text(
              _belowNote(ui)!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
        SettingColorRow(
          label: 'Colour',
          value: style.color,
          fallback: Theme.of(context).colorScheme.onSurfaceVariant,
          onChanged: (c) {
            write(style.copyWith(color: c));
            notifySetting(context,
                c == null ? '$_role follows the theme' : '$_role recoloured');
          },
        ),
        NudgePad(
          label: 'Nudge',
          offsetX: style.offsetX,
          offsetY: style.offsetY,
          range: kMaxNameOffset,
          onDelta: (d) => write(style.copyWith(
            offsetX: (style.offsetX + d.dx).clamp(-kMaxNameOffset, kMaxNameOffset),
            offsetY: (style.offsetY + d.dy).clamp(-kMaxNameOffset, kMaxNameOffset),
          )),
          onReset: () {
            write(style.copyWith(offsetX: 0, offsetY: 0));
            notifySetting(context, '$_role position reset');
          },
        ),
      ],
    ];
  }
}



