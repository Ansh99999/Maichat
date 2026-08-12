import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_interface.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
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
          SwitchListTile(
            dense: true,
            value: ui.showNames,
            onChanged: (v) => update(ui.copyWith(showNames: v)),
            secondary: const Icon(Icons.badge_outlined),
            title: const Text('Show names'),
            subtitle: const Text('Label each turn with its sender'),
          ),
          _NameField(
            value: ui.userName,
            onChanged: (v) => update(ui.copyWith(userName: v)),
          ),
// APPEND-CHILDREN
          const Divider(height: 24),
          _header(context, 'Avatars'),
          SwitchListTile(
            dense: true,
            value: ui.syncAvatars,
            onChanged: (v) => update(ui.copyWith(syncAvatars: v)),
            secondary: const Icon(Icons.link_outlined),
            title: const Text('Sync avatars'),
            subtitle: const Text('Keep both avatars\' look in step (side stays '
                'independent)'),
          ),
          SettingHighlight(
            active: highlight == SettingAnchor.chatAvatars,
            child: _AvatarSection(
              title: 'Character avatar',
              icon: Icons.smart_toy_outlined,
              style: ui.botAvatar,
              onChanged: (s) => update(ui.withAvatar(false, s)),
            ),
          ),
          _AvatarSection(
            title: 'Your avatar',
            icon: Icons.person_outline,
            style: ui.userAvatar,
            onChanged: (s) => update(ui.withAvatar(true, s)),
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
        ],
      ),
    );
  }
}

Widget _header(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );

/// One role's avatar controls: show, size, corners, image fit and which side it
/// sits on. Writes back a whole [AvatarStyle] via [onChanged].
class _AvatarSection extends StatelessWidget {
  const _AvatarSection({
    required this.title,
    required this.icon,
    required this.style,
    required this.onChanged,
  });

  final String title;
  final IconData icon;
  final AvatarStyle style;
  final ValueChanged<AvatarStyle> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            SwitchListTile(
              dense: true,
              value: style.show,
              onChanged: (v) => onChanged(style.copyWith(show: v)),
              secondary: Icon(icon),
              title: Text(title),
              subtitle: Text(style.show ? 'Shown' : 'Hidden'),
            ),
            if (style.show) ...[
              _SliderRow(
                icon: Icons.photo_size_select_large_outlined,
                label: 'Size',
                value: style.size,
                min: kMinAvatarSize,
                max: kMaxAvatarSize,
                suffix: '${style.size.round()} px',
                onChanged: (v) => onChanged(style.copyWith(size: v)),
              ),
              _EnumRow<AvatarShape>(
                icon: Icons.crop_square_outlined,
                label: 'Corners',
                value: style.shape,
                values: AvatarShape.values,
                labelOf: (s) => s.label,
                onChanged: (s) => onChanged(style.copyWith(shape: s)),
              ),
              _EnumRow<AvatarFit>(
                icon: Icons.aspect_ratio_outlined,
                label: 'Image fit',
                value: style.fit,
                values: AvatarFit.values,
                labelOf: (f) => f.label,
                onChanged: (f) => onChanged(style.copyWith(fit: f)),
              ),
              _EnumRow<ChatSide>(
                icon: Icons.swap_horiz_outlined,
                label: 'Side',
                value: style.side,
                values: ChatSide.values,
                labelOf: (s) => s.label,
                onChanged: (s) => onChanged(style.copyWith(side: s)),
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
      ),
    );
  }
}
// APPEND-WIDGETS

/// The user's display-name field. Keeps its own controller so live updates
/// don't clobber the cursor.
class _NameField extends StatefulWidget {
  const _NameField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: _controller,
        textInputAction: TextInputAction.done,
        decoration: const InputDecoration(
          labelText: 'Your name',
          prefixIcon: Icon(Icons.person_outline),
          isDense: true,
        ),
        onChanged: widget.onChanged,
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



