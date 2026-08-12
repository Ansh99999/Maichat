import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_interface.dart';
import '../../state/app_state.dart';
import '../../widgets/color_picker.dart';
import 'chat_interface_preview.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// The "Chat Interface" section: everything about how the chat and its messages
/// look — avatar size/shape/fit, where the text sits relative to the avatar,
/// bubble vs flat, font size, and colour overrides. The eye button in the app
/// bar opens a live mock chat where the same options can be tuned by dragging.
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
          _header(context, 'Avatars'),
          SettingHighlight(
            active: highlight == SettingAnchor.chatAvatars,
            child: SwitchListTile(
              dense: true,
              value: ui.showAvatars,
              onChanged: (v) => update(ui.copyWith(showAvatars: v)),
              secondary: const Icon(Icons.account_circle_outlined),
              title: const Text('Show avatars'),
              subtitle: const Text('Draw each turn with a picture'),
            ),
          ),
          _SliderRow(
            icon: Icons.photo_size_select_large_outlined,
            label: 'Avatar size',
            value: ui.avatarSize,
            min: kMinAvatarSize,
            max: kMaxAvatarSize,
            suffix: '${ui.avatarSize.round()} px',
            onChanged: (v) => update(ui.copyWith(avatarSize: v)),
          ),
          _EnumRow<AvatarShape>(
            icon: Icons.crop_square_outlined,
            label: 'Corners',
            value: ui.avatarShape,
            values: AvatarShape.values,
            labelOf: (s) => s.label,
            onChanged: (s) => update(ui.copyWith(avatarShape: s)),
          ),
          _EnumRow<AvatarFit>(
            icon: Icons.aspect_ratio_outlined,
            label: 'Image fit',
            value: ui.avatarFit,
            values: AvatarFit.values,
            labelOf: (f) => f.label,
            onChanged: (f) => update(ui.copyWith(avatarFit: f)),
          ),
          if (ui.avatarOffsetX != 0 || ui.avatarOffsetY != 0)
            ListTile(
              leading: const Icon(Icons.open_with_outlined),
              title: const Text('Avatar position'),
              subtitle: Text(
                'Nudged ${ui.avatarOffsetX.round()}, ${ui.avatarOffsetY.round()} '
                '— drag in the preview to move',
              ),
              trailing: TextButton(
                onPressed: () =>
                    update(ui.copyWith(avatarOffsetX: 0, avatarOffsetY: 0)),
                child: const Text('Reset'),
              ),
            ),
          const Divider(height: 24),
          _header(context, 'Layout'),
          SettingHighlight(
            active: highlight == SettingAnchor.textPlacement,
            child: _EnumRow<TextPlacement>(
              icon: Icons.view_agenda_outlined,
              label: 'Text placement',
              value: ui.textPlacement,
              values: TextPlacement.values,
              labelOf: (p) => p.label,
              onChanged: (p) => update(ui.copyWith(textPlacement: p)),
            ),
          ),
          SwitchListTile(
            dense: true,
            value: ui.bubbles,
            onChanged: (v) => update(ui.copyWith(bubbles: v)),
            secondary: const Icon(Icons.chat_bubble_outline),
            title: const Text('Bubbles'),
            subtitle: const Text('Draw each turn in a tinted bubble'),
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
          const Divider(height: 24),
          _header(context, 'Text'),
          _SliderRow(
            icon: Icons.format_size_outlined,
            label: 'Font size',
            value: ui.fontSize,
            min: kMinFontSize,
            max: kMaxFontSize,
            suffix: '${ui.fontSize.round()} px',
            onChanged: (v) => update(ui.copyWith(fontSize: v)),
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
}

/// A labelled slider row: icon + label on top, the slider and its current
/// value beneath.
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
