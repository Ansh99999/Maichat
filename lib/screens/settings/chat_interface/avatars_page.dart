import 'package:flutter/material.dart';

import '../../../models/chat_interface.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import '../setting_highlight.dart';
import 'controls.dart';
import 'spoke.dart';

/// One avatar editor serving both roles, in place of the two near-identical
/// cards this replaced.
///
/// The selector picks *whose* avatar the controls below are writing. It stays
/// visible even while the two are synced, because a synced write mirrors the
/// look and deliberately leaves each role its own side: `AvatarStyle.matchLook`
/// is `other.copyWith(side: side)`. So with sync on, Size/Corners/Fit/Position
/// land on both and Side lands on the role the selector names.
class AvatarsSpokePage extends StatefulWidget {
  const AvatarsSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  State<AvatarsSpokePage> createState() => _AvatarsSpokePageState();
}

class _AvatarsSpokePageState extends State<AvatarsSpokePage> {
  /// Which role is being edited: false = the character, true = you.
  bool _isUser = false;

  String get _role => _isUser ? 'Your' : 'Character';

  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: widget.scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Avatars',
          scope: widget.scope,
          resetLabel: 'Reset avatars to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              botAvatar: d.botAvatar,
              userAvatar: d.userAvatar,
              syncAvatars: d.syncAvatars,
            ));
            notifySetting(context, 'Avatars back to defaults');
          },
          children: _children(context, ui, update),
        ),
      );
  List<Widget> _children(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) {
    final style = ui.avatarFor(_isUser);
    // Every write goes through withAvatar, which is where the sync rule lives.
    void write(AvatarStyle next) => update(ui.withAvatar(_isUser, next));

    return [
      SettingEnumRow<bool>(
        icon: Icons.people_outline,
        label: 'Whose avatar',
        value: _isUser,
        values: const [false, true],
        labelOf: (v) => v ? 'You' : 'Character',
        onChanged: (v) => setState(() => _isUser = v),
      ),
      SettingSwitch(
        icon: Icons.link_outlined,
        title: 'Sync the two',
        subtitle: 'One look for both. Each keeps its own side.',
        value: ui.syncAvatars,
        onChanged: (v) {
          update(ui.copyWith(syncAvatars: v));
          notifySetting(context, v ? 'Avatars synced' : 'Avatars independent');
        },
      ),
      if (ui.syncAvatars)
        settingNote(
          context,
          'Synced, so size, corners, fit and position below are written to both '
          'avatars. Side belongs to one role at a time — it lands on the '
          '${_isUser ? 'your' : 'character'} avatar.',
        ),
      const Divider(height: 24),
      SettingHighlight(
        active: widget.highlight == SettingAnchor.chatAvatars,
        child: SettingSwitch(
          icon: Icons.visibility_outlined,
          title: 'Show avatar',
          value: style.show,
          onChanged: (v) {
            write(style.copyWith(show: v));
            notifySetting(context, '$_role avatar ${v ? 'shown' : 'hidden'}');
          },
        ),
      ),
      if (style.show) ...[
        SettingSizeField(
          icon: Icons.photo_size_select_large_outlined,
          label: 'Size',
          value: style.size,
          min: kMinAvatarSize,
          sliderMax: kMaxAvatarSize,
          hardMax: kAvatarHardMax,
          unit: 'px',
          onChanged: (v) => write(style.copyWith(size: v)),
          onChangeEnd: (v) =>
              notifySetting(context, '$_role avatar size ${v.round()} px'),
        ),
        SettingEnumRow<AvatarShape>(
          icon: Icons.crop_square_outlined,
          label: 'Corners',
          value: style.shape,
          values: AvatarShape.values,
          labelOf: (s) => s.label,
          onChanged: (s) {
            write(style.copyWith(shape: s));
            notifySetting(context, '$_role avatar corners: ${s.label}');
          },
        ),
        // Only a rounded frame has a roundness to choose; a circle and a square
        // are already fully specified.
        if (style.shape == AvatarShape.rounded)
          SettingDropdownRow<CornerRounding>(
            icon: Icons.rounded_corner_outlined,
            label: 'Roundness',
            value: style.corner,
            values: CornerRounding.values,
            labelOf: (r) => r.label,
            onChanged: (r) {
              write(style.copyWith(corner: r));
              notifySetting(context, '$_role avatar roundness: ${r.label}');
            },
          ),
        SettingEnumRow<AvatarFit>(
          icon: Icons.aspect_ratio_outlined,
          label: 'Image fit',
          value: style.fit,
          values: AvatarFit.values,
          labelOf: (f) => f.label,
          onChanged: (f) {
            write(style.copyWith(fit: f));
            notifySetting(context, '$_role avatar fit: ${f.label}');
          },
        ),
        SettingEnumRow<ChatSide>(
          icon: Icons.swap_horiz_outlined,
          label: 'Side',
          value: style.side,
          values: ChatSide.values,
          labelOf: (s) => s.label,
          onChanged: (s) {
            write(style.copyWith(side: s));
            notifySetting(
                context, '$_role avatar on the ${s.label.toLowerCase()}');
          },
        ),
        NudgePad(
          label: 'Position',
          offsetX: style.offsetX,
          offsetY: style.offsetY,
          range: kMaxAvatarNudge,
          onDelta: (d) => write(style.copyWith(
            offsetX: (style.offsetX + d.dx).clamp(-kMaxAvatarNudge, kMaxAvatarNudge),
            offsetY: (style.offsetY + d.dy).clamp(-kMaxAvatarNudge, kMaxAvatarNudge),
          )),
          onReset: () {
            write(style.copyWith(offsetX: 0, offsetY: 0));
            notifySetting(context, '$_role avatar position reset');
          },
        ),
      ],
    ];
  }
}



