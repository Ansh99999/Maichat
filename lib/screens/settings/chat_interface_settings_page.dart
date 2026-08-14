import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_interface.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import '../../widgets/font_picker_row.dart';
import 'chat_interface_preview.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// The "Chat Interface" section: chat style (bubbles vs document, names, text
/// placement), a separate avatar editor for the character and for you (with an
/// optional sync), and colour overrides. The eye button opens a live mock chat
/// where the same options can be tuned by dragging each avatar.
class ChatInterfaceSettingsPage extends StatelessWidget {
  const ChatInterfaceSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ui = state.chatInterface;
    void update(ChatInterface next) => state.updateChatInterface(next);

    // Subtle, non-blocking confirmation that a change was applied. Replaces any
    // still-showing note so rapid tweaks don't stack up.
    void notify(String message) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(milliseconds: 1400),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat Interface'),
        actions: [
          IconButton(
            tooltip: 'Preview',
            icon: const Icon(Icons.visibility_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const ChatInterfacePreviewPage(),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _header(context, 'Chat style'),
          SettingHighlight(
            active: highlight == SettingAnchor.textPlacement,
            child: SwitchListTile(
              dense: true,
              value: ui.bubbles,
              onChanged: (v) => update(ui.copyWith(bubbles: v)),
              secondary: const Icon(Icons.chat_bubble_outline),
              title: const Text('Bubbles'),
              subtitle: Text(ui.bubbles
                  ? 'Tinted bubbles per turn'
                  : 'Flat "document" style, no bubbles'),
            ),
          ),
          _EnumRow<TextPlacement>(
            icon: Icons.view_agenda_outlined,
            label: 'Text placement',
            value: ui.textPlacement,
            values: TextPlacement.values,
            labelOf: (p) => p.label,
            onChanged: (p) => update(ui.copyWith(textPlacement: p)),
          ),
          _EnumRow<ContentWidth>(
            icon: Icons.width_normal_outlined,
            label: 'Content width',
            value: ui.contentWidth,
            values: ContentWidth.values,
            labelOf: (w) => w.label,
            onChanged: (w) {
              update(ui.copyWith(contentWidth: w));
              notify('Content width: ${w.label.toLowerCase()}');
            },
          ),
          if (ui.bubbles)
            _SliderRow(
              icon: Icons.opacity_outlined,
              label: 'Bubble opacity',
              value: ui.bubbleOpacity,
              min: 0.2,
              max: 1,
              suffix: '${(ui.bubbleOpacity * 100).round()}%',
              onChanged: (v) => update(ui.copyWith(bubbleOpacity: v)),
            ),
          _SliderRow(
            icon: Icons.format_size_outlined,
            label: 'Font size',
            value: ui.fontSize,
            min: kMinFontSize,
            max: kMaxFontSize,
            suffix: '${ui.fontSize.round()} px',
            onChanged: (v) => update(ui.copyWith(fontSize: v)),
          ),
          SettingHighlight(
            active: highlight == SettingAnchor.spacing,
            child: _SliderRow(
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
          SwitchListTile(
            dense: true,
            value: ui.markdown,
            onChanged: (v) => update(ui.copyWith(markdown: v)),
            secondary: const Icon(Icons.text_format_outlined),
            title: const Text('Markdown'),
            subtitle: const Text('Render **bold**, *italic*, `code`, lists and '
                'quotes'),
          ),
// APPEND-CHILDREN
          const Divider(height: 24),
          _header(context, 'Names'),
          SwitchListTile(
            dense: true,
            value: ui.showNames,
            onChanged: (v) => update(ui.copyWith(showNames: v)),
            secondary: const Icon(Icons.badge_outlined),
            title: const Text('Show names'),
            subtitle: const Text('Label each turn with its sender'),
          ),
          if (ui.showNames) ...[
            SwitchListTile(
              dense: true,
              value: ui.syncNames,
              onChanged: (v) {
                // Adopting sync copies the character's look onto both, so the
                // two names don't stay silently out of step.
                final next = ui.copyWith(syncNames: v);
                update(v
                    ? next.copyWith(userNameStyle: ui.botNameStyle)
                    : next);
                notify(v ? 'Names synced' : 'Names independent');
              },
              secondary: const Icon(Icons.link_outlined),
              title: const Text('Sync names'),
              subtitle: const Text(
                  'Keep both name labels in step (size, font, placement, nudge)'),
            ),
            SettingHighlight(
              active: highlight == SettingAnchor.names,
              child: Column(
                children: [
                  _NameControls(
                    title: 'Character name',
                    icon: Icons.smart_toy_outlined,
                    role: 'Character name',
                    style: ui.botNameStyle,
                    belowNote: _belowNote(ui, ui.botAvatar),
                    onChanged: (s) => update(ui.withName(false, s)),
                    notify: notify,
                  ),
                  _NameControls(
                    title: 'Your name',
                    icon: Icons.person_outline,
                    role: 'Your name',
                    style: ui.userNameStyle,
                    belowNote: _belowNote(ui, ui.userAvatar),
                    onChanged: (s) => update(ui.withName(true, s)),
                    notify: notify,
                  ),
                ],
              ),
            ),
          ],
          const Divider(height: 24),
          _header(context, 'Message actions'),
          SettingHighlight(
            active: highlight == SettingAnchor.messageActions,
            child: _MessageActionsSection(
                ui: ui, update: update, notify: notify),
          ),
          const Divider(height: 24),
          _header(context, 'Avatars'),
          SwitchListTile(
            dense: true,
            value: ui.syncAvatars,
            onChanged: (v) {
              update(ui.copyWith(syncAvatars: v));
              notify(v ? 'Avatars synced' : 'Avatars independent');
            },
            secondary: const Icon(Icons.link_outlined),
            title: const Text('Sync avatars'),
            subtitle: const Text('Keep both avatars\' look in step (side stays '
                'independent)'),
          ),
          SettingHighlight(
            active: highlight == SettingAnchor.chatAvatars,
            child: _AvatarSection(
              title: 'Character avatar settings',
              icon: Icons.smart_toy_outlined,
              style: ui.botAvatar,
              onChanged: (s) => update(ui.withAvatar(false, s)),
              notify: notify,
              role: 'Character',
            ),
          ),
          _AvatarSection(
            title: 'User avatar settings',
            icon: Icons.person_outline,
            style: ui.userAvatar,
            onChanged: (s) => update(ui.withAvatar(true, s)),
            notify: notify,
            role: 'User',
          ),
          const Divider(height: 24),
          _header(context, 'Colours'),
          SettingHighlight(
            active: highlight == SettingAnchor.chatColours,
            child: _ColorRow(
              label: 'Your text',
              value: ui.userTextColor,
              fallback: Theme.of(context).colorScheme.onPrimaryContainer,
              onChanged: (c) => update(ui.copyWith(userTextColor: c)),
            ),
          ),
          _ColorRow(
            label: 'Reply text',
            value: ui.botTextColor,
            fallback: Theme.of(context).colorScheme.onSurface,
            onChanged: (c) => update(ui.copyWith(botTextColor: c)),
          ),
          _ColorRow(
            label: 'Your bubble',
            value: ui.userBubbleColor,
            fallback: Theme.of(context).colorScheme.primaryContainer,
            onChanged: (c) => update(ui.copyWith(userBubbleColor: c)),
          ),
          _ColorRow(
            label: 'Reply bubble',
            value: ui.botBubbleColor,
            fallback: Theme.of(context).colorScheme.surfaceContainerHighest,
            onChanged: (c) => update(ui.copyWith(botBubbleColor: c)),
          ),
          _ColorRow(
            label: 'Chat background',
            value: ui.backgroundColor,
            fallback: Theme.of(context).colorScheme.surface,
            onChanged: (c) => update(ui.copyWith(backgroundColor: c)),
          ),
          _ColorRow(
            label: 'Emphasis (*italic* / **bold**)',
            value: ui.emphasisColor,
            fallback: Theme.of(context).colorScheme.onSurface,
            onChanged: (c) => update(ui.copyWith(emphasisColor: c)),
          ),
          _ColorRow(
            label: 'Quoted "text"',
            value: ui.quoteColor,
            fallback: Theme.of(context).colorScheme.onSurface,
            onChanged: (c) => update(ui.copyWith(quoteColor: c)),
          ),
        ],
      ),
    );
  }
}

Widget _header(BuildContext context, String text) => Padding(      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );

/// Why a "below" name will not land under the avatar in the current layout, or
/// null when it will. Said out loud in the settings card, because a silent
/// fallback is indistinguishable from a broken setting.
String? _belowNote(ChatInterface ui, AvatarStyle avatar) {
  if (!avatar.show) {
    return 'This avatar is hidden, so a "below" name sits under the message.';
  }
  if (ui.textPlacement == TextPlacement.around) {
    return 'Text wraps around the avatar in this layout, so there is no avatar '
        'bottom to hang from — a "below" name sits under the message.';
  }
  return null;
}

/// One role's avatar controls, presented as a collapsible dropdown (an
/// [ExpansionTile] in a card) to keep the settings list uncluttered. Expands to
/// reveal show/size/corners/fit/side; writes back a whole [AvatarStyle] via
/// [onChanged] and reports each change through [notify].
class _AvatarSection extends StatelessWidget {
  const _AvatarSection({
    required this.title,
    required this.icon,
    required this.style,
    required this.onChanged,
    required this.notify,
    required this.role,
  });

  final String title;
  final IconData icon;
  final AvatarStyle style;
  final ValueChanged<AvatarStyle> onChanged;
  final ValueChanged<String> notify;

  /// "Character" / "User" — used in the change notifications.
  final String role;

  String get _summary {
    if (!style.show) return 'Hidden';
    return 'Shown · ${style.size.round()} px · ${style.cornerLabel}';
  }

  @override
  Widget build(BuildContext context) {
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(_summary),
        shape: shape,
        collapsedShape: shape,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          SwitchListTile(
            dense: true,
            value: style.show,
            onChanged: (v) {
              onChanged(style.copyWith(show: v));
              notify('$role avatar ${v ? 'shown' : 'hidden'}');
            },
            secondary: const Icon(Icons.visibility_outlined),
            title: const Text('Show avatar'),
          ),
          if (style.show) ...[
            _SizeSliderField(
              icon: Icons.photo_size_select_large_outlined,
              label: 'Size',
              value: style.size,
              min: kMinAvatarSize,
              sliderMax: kMaxAvatarSize,
              hardMax: kAvatarHardMax,
              unit: 'px',
              onChanged: (v) => onChanged(style.copyWith(size: v)),
              onChangeEnd: (v) => notify('$role avatar size ${v.round()} px'),
            ),
            _EnumRow<AvatarShape>(
              icon: Icons.crop_square_outlined,
              label: 'Corners',
              value: style.shape,
              values: AvatarShape.values,
              labelOf: (s) => s.label,
              onChanged: (s) {
                onChanged(style.copyWith(shape: s));
                notify('$role avatar corners: ${s.label}');
              },
            ),
            // Only a rounded frame has a roundness to choose; a circle and a
            // square are already fully specified.
            if (style.shape == AvatarShape.rounded)
              _DropdownRow<CornerRounding>(
                icon: Icons.rounded_corner_outlined,
                label: 'Roundness',
                value: style.corner,
                values: CornerRounding.values,
                labelOf: (r) => r.label,
                onChanged: (r) {
                  onChanged(style.copyWith(corner: r));
                  notify('$role avatar roundness: ${r.label}');
                },
              ),
            _EnumRow<AvatarFit>(
              icon: Icons.aspect_ratio_outlined,
              label: 'Image fit',
              value: style.fit,
              values: AvatarFit.values,
              labelOf: (f) => f.label,
              onChanged: (f) {
                onChanged(style.copyWith(fit: f));
                notify('$role avatar fit: ${f.label}');
              },
            ),
            _EnumRow<ChatSide>(
              icon: Icons.swap_horiz_outlined,
              label: 'Side',
              value: style.side,
              values: ChatSide.values,
              labelOf: (s) => s.label,
              onChanged: (s) {
                onChanged(style.copyWith(side: s));
                notify('$role avatar on the ${s.label.toLowerCase()}');
              },
            ),
            if (style.offsetX != 0 || style.offsetY != 0)
              ListTile(
                dense: true,
                leading: const Icon(Icons.open_with_outlined),
                title: const Text('Position'),
                subtitle: Text(
                  'Nudged ${style.offsetX.round()}, ${style.offsetY.round()} '
                  '— drag in the preview',
                ),
                trailing: TextButton(
                  onPressed: () =>
                      onChanged(style.copyWith(offsetX: 0, offsetY: 0)),
                  child: const Text('Reset'),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// One role's sender-name controls — size, font, alignment, position and the
/// nudge the preview's drag writes — as a collapsible dropdown matching the
/// avatar sections. Writes back a whole [NameStyle], so the caller can route it
/// through [ChatInterface.withName] and honour the sync toggle.
class _NameControls extends StatelessWidget {
  const _NameControls({
    required this.title,
    required this.icon,
    required this.role,
    required this.style,
    required this.onChanged,
    required this.notify,
    this.belowNote,
  });

  final String title;
  final IconData icon;

  /// "Character name" / "Your name" — used in the change notifications.
  final String role;

  final NameStyle style;
  final ValueChanged<NameStyle> onChanged;
  final ValueChanged<String> notify;

  /// Set when "Below" cannot mean "below the avatar" in the current layout.
  final String? belowNote;

  @override
  Widget build(BuildContext context) {
    final shape =
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(style.summary),
        shape: shape,
        collapsedShape: shape,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        children: [
          _SizeSliderField(
            icon: Icons.format_size_outlined,
            label: 'Name size',
            value: style.size,
            min: kMinNameSize,
            sliderMax: kMaxNameSize,
            hardMax: kMaxNameSize,
            unit: 'px',
            onChanged: (v) => onChanged(style.copyWith(size: v)),
            onChangeEnd: (v) => notify('$role size ${v.round()} px'),
          ),
          FontPickerRow(
            title: 'Font',
            pickerTitle: '$title font',
            fontFamily: style.fontFamily,
            systemLabel: 'Same as app font',
            systemSubtitle: 'Inherit the app-wide font',
            onChanged: (family) {
              onChanged(style.copyWith(fontFamily: family));
              notify('$role font: ${family ?? 'app font'}');
            },
          ),
          _EnumRow<NameAlign>(
            icon: Icons.format_align_center_outlined,
            label: 'Alignment (across the screen)',
            value: style.align,
            values: NameAlign.values,
            labelOf: (a) => a.label,
            onChanged: (a) {
              onChanged(style.copyWith(align: a));
              notify('$role aligned ${a.label.toLowerCase()}');
            },
          ),
          _EnumRow<NamePosition>(
            icon: Icons.vertical_align_top_outlined,
            label: 'Position (above the message / below the avatar)',
            value: style.position,
            values: NamePosition.values,
            labelOf: (p) => p.label,
            onChanged: (p) {
              onChanged(style.copyWith(position: p));
              notify(p == NamePosition.above
                  ? '$role above the message'
                  : '$role below the avatar');
            },
          ),
          if (style.position == NamePosition.below && belowNote != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(52, 0, 16, 8),
              child: Text(
                belowNote!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ),
          _ColorRow(
            label: 'Colour',
            value: style.color,
            fallback: Theme.of(context).colorScheme.onSurfaceVariant,
            onChanged: (c) {
              onChanged(style.copyWith(color: c));
              notify(c == null ? '$role follows the theme' : '$role recoloured');
            },
          ),
          // The same nudge the preview's drag writes, for when a value is easier
          // to set than to drag.
          _SliderRow(
            icon: Icons.swap_horiz_outlined,
            label: 'Nudge across',
            value: style.offsetX.clamp(-kMaxNameOffset, kMaxNameOffset),
            min: -kMaxNameOffset,
            max: kMaxNameOffset,
            suffix: '${style.offsetX.round()} px',
            onChanged: (v) => onChanged(style.copyWith(offsetX: v.roundToDouble())),
          ),
          _SliderRow(
            icon: Icons.swap_vert_outlined,
            label: 'Nudge down',
            value: style.offsetY.clamp(-kMaxNameOffset, kMaxNameOffset),
            min: -kMaxNameOffset,
            max: kMaxNameOffset,
            suffix: '${style.offsetY.round()} px',
            onChanged: (v) => onChanged(style.copyWith(offsetY: v.roundToDouble())),
          ),
          ListTile(
            dense: true,
            leading: const Icon(Icons.open_with_outlined),
            title: const Text('Nudge'),
            subtitle: Text(
              style.isNudged
                  ? 'Moved ${style.offsetX.round()}, ${style.offsetY.round()} '
                      '— or drag the name in the preview'
                  : 'Drag the name in the preview, or use the sliders above',
            ),
            trailing: style.isNudged
                ? TextButton(
                    onPressed: () {
                      onChanged(style.copyWith(offsetX: 0, offsetY: 0));
                      notify('$role position reset');
                    },
                    child: const Text('Reset'),
                  )
                : null,
          ),
        ],
      ),
    );
  }
}
// APPEND-WIDGETS

/// A numeric value editable two ways at once: a slider for quick adjustment and
/// a text field for precise entry, kept in sync. The slider spans [min]..
/// [sliderMax]; the field accepts anything in [min]..[hardMax] so a value past
/// the slider's comfortable ceiling can still be typed (the slider just pins to
/// its max). [onChanged] fires live; [onChangeEnd] fires once a change is
/// committed (slider release or field submit) — the hook the caller uses to
/// surface a confirmation.
class _SizeSliderField extends StatefulWidget {
  const _SizeSliderField({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.sliderMax,
    required this.hardMax,
    required this.unit,
    required this.onChanged,
    this.onChangeEnd,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double sliderMax;
  final double hardMax;
  final String unit;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangeEnd;

  @override
  State<_SizeSliderField> createState() => _SizeSliderFieldState();
}

class _SizeSliderFieldState extends State<_SizeSliderField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value.round().toString());
  final FocusNode _focus = FocusNode();

  @override
  void didUpdateWidget(_SizeSliderField old) {
    super.didUpdateWidget(old);
    // Reflect external changes (e.g. dragging the slider) into the field, but
    // never fight the user while they are typing in it.
    if (!_focus.hasFocus && widget.value != old.value) {
      final text = widget.value.round().toString();
      if (_controller.text != text) _controller.text = text;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  double _clamp(double v) => v.clamp(widget.min, widget.hardMax).toDouble();

  void _commitField(String raw) {
    final parsed = double.tryParse(raw.trim());
    if (parsed == null) {
      _controller.text = widget.value.round().toString();
      return;
    }
    final v = _clamp(parsed);
    _controller.text = v.round().toString();
    widget.onChanged(v);
    widget.onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final sliderValue = widget.value.clamp(widget.min, widget.sliderMax);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(widget.icon, size: 20),
              const SizedBox(width: 16),
              Expanded(child: Text(widget.label)),
              SizedBox(
                width: 84,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  textAlign: TextAlign.end,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: false),
                  textInputAction: TextInputAction.done,
                  decoration: InputDecoration(
                    isDense: true,
                    suffixText: widget.unit,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 8),
                    border: const OutlineInputBorder(),
                  ),
                  onSubmitted: _commitField,
                  onTapOutside: (_) {
                    if (_focus.hasFocus) {
                      _focus.unfocus();
                      _commitField(_controller.text);
                    }
                  },
                ),
              ),
            ],
          ),
          Slider(
            value: sliderValue.toDouble(),
            min: widget.min,
            max: widget.sliderMax,
            activeColor: scheme.primary,
            onChanged: (v) {
              final r = v.roundToDouble();
              _controller.text = r.round().toString();
              widget.onChanged(r);
            },
            onChangeEnd: (v) => widget.onChangeEnd?.call(v.roundToDouble()),
          ),
        ],
      ),
    );
  }
}

/// A labelled slider row: icon + label on top, the slider and its value below.
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.suffix,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final double value;
  final double min;
  final double max;
  final String suffix;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 16),
              Expanded(child: Text(label)),
              Text(
                suffix,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
// APPEND-WIDGETS-2

/// A labelled row of segmented choices for a small enum.
class _EnumRow<T> extends StatelessWidget {
  const _EnumRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20),
              const SizedBox(width: 16),
              Text(label),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              showSelectedIcon: false,
              segments: [
                for (final v in values)
                  ButtonSegment<T>(value: v, label: Text(labelOf(v))),
              ],
              selected: {value},
              onSelectionChanged: (s) => onChanged(s.first),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled row whose choices live in a dropdown — for enums with more values
/// than a segmented button can show without shrinking the labels to nothing.
class _DropdownRow<T> extends StatelessWidget {
  const _DropdownRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.values,
    required this.labelOf,
    required this.onChanged,
  });

  final IconData icon;
  final String label;
  final T value;
  final List<T> values;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 16),
          Expanded(child: Text(label)),
          DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              borderRadius: BorderRadius.circular(12),
              onChanged: (next) {
                if (next != null) onChanged(next);
              },
              items: [
                for (final v in values)
                  DropdownMenuItem<T>(value: v, child: Text(labelOf(v))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A colour override row: a swatch that opens the HSV picker, an "Auto (theme)"
/// state when unset, and a clear button to fall back to the theme again.
class _ColorRow extends StatelessWidget {
  const _ColorRow({
    required this.label,
    required this.value,
    required this.fallback,
    required this.onChanged,
  });

  final String label;
  final int? value;
  final Color fallback;
  final ValueChanged<int?> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final set = value != null;
    final color = set ? Color(value!) : fallback;

    Future<void> pick() async {
      final picked = await showCustomColorDialog(context, color);
      if (picked != null) onChanged(picked.toARGB32());
    }

    return ListTile(
      leading: const Icon(Icons.format_color_fill_outlined),
      title: Text(label),
      subtitle: Text(set ? hexOf(color) : 'Auto (theme)'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (set)
            IconButton(
              tooltip: 'Follow theme',
              icon: const Icon(Icons.close),
              onPressed: () => onChanged(null),
            ),
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: scheme.outlineVariant),
            ),
          ),
        ],
      ),
      onTap: pick,
    );
  }
}

/// The "Message actions" controls: a master toggle plus a reorderable list where
/// each action is placed either inline (an icon beside the message) or behind the
/// three-dot overflow — mirroring Agnai's `msgOptsInline`. Drag to reorder.
class _MessageActionsSection extends StatelessWidget {
  const _MessageActionsSection({
    required this.ui,
    required this.update,
    required this.notify,
  });

  final ChatInterface ui;
  final void Function(ChatInterface) update;
  final void Function(String) notify;

  void _setInline(MessageAction action, bool inline) {
    final next = [
      for (final p in ui.messageActions)
        p.action == action ? p.copyWith(inline: inline) : p,
    ];
    update(ui.copyWith(messageActions: next));
    notify('${action.label} → ${inline ? 'inline' : 'menu'}');
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
        SwitchListTile(
          dense: true,
          value: ui.messageActionsEnabled,
          onChanged: (v) {
            update(ui.copyWith(messageActionsEnabled: v));
            notify(v ? 'Action buttons shown' : 'Action buttons hidden');
          },
          secondary: const Icon(Icons.more_horiz),
          title: const Text('Show action buttons'),
          subtitle: const Text(
              'Inline actions beside each message; the rest under a ⋮ menu'),
        ),
        if (ui.messageActionsEnabled) ...[
          _EnumRow<ActionBarPlacement>(
            icon: Icons.place_outlined,
            label: 'Placement',
            value: ui.actionBarPlacement,
            values: ActionBarPlacement.values,
            labelOf: (p) => p.label,
            onChanged: (p) {
              update(ui.copyWith(actionBarPlacement: p));
              notify('Actions ${p.label.toLowerCase()}');
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
            onSelectionChanged: (s) => _setInline(action, s.first),
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
