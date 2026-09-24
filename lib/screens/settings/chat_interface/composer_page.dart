import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/chat_interface.dart';
import '../../../state/app_state.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import '../setting_highlight.dart';
import 'controls.dart';
import 'spoke.dart';

/// How the Expressive composer's card looks: its outline, and the background it
/// sits on — the Material surface, a solid colour, or a picture (which can be
/// frosted or faded).
///
/// Which composer is used at all — Expressive or Legacy — and whether it
/// formats text as you type are feature switches, not looks, so they live in
/// Chat behaviour. This page only governs appearance, which is why a saved look
/// carries these fields and not those.
class ComposerSpokePage extends StatelessWidget {
  const ComposerSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  /// Picks a device image for the composer's background, stores it in the avatar
  /// directory (so it round-trips like every other picture) and writes the
  /// resulting `local:` reference back onto the interface being edited.
  Future<void> _pickImage(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) async {
    final state = context.read<AppState>();
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    final bytes = (result != null && result.files.isNotEmpty)
        ? result.files.first.bytes
        : null;
    if (bytes == null) return;
    final ref = await state.storePicture(bytes);
    if (ref != null) update(ui.copyWith(composerBackgroundImage: ref));
  }

  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Composer',
          scope: scope,
          resetLabel: 'Reset the composer to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              composerBackground: d.composerBackground,
              composerBackgroundColor: null,
              composerBackgroundImage: null,
              composerBackgroundBlur: d.composerBackgroundBlur,
              composerBackgroundOpacity: d.composerBackgroundOpacity,
              composerOutline: d.composerOutline,
            ));
            notifySetting(context, 'Composer back to defaults');
          },
          children: _children(context, ui, update),
        ),
      );

  List<Widget> _children(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return [
      SettingHighlight(
        active: highlight == SettingAnchor.composer,
        child: SettingSwitch(
          icon: Icons.border_style_outlined,
          title: 'Outline',
          subtitle: 'A hairline border around the box, tinted from the theme',
          value: ui.composerOutline,
          onChanged: (v) => update(ui.copyWith(composerOutline: v)),
        ),
      ),
      const Divider(height: 24),
      settingHeader(context, 'Background'),
      SettingEnumRow<ComposerBackground>(
        icon: Icons.wallpaper_outlined,
        label: 'Background',
        value: ui.composerBackground,
        values: ComposerBackground.values,
        labelOf: (b) => b.label,
        onChanged: (v) => update(ui.copyWith(composerBackground: v)),
      ),
      if (ui.composerBackground == ComposerBackground.color)
        SettingColorRow(
          label: 'Background colour',
          value: ui.composerBackgroundColor,
          fallback: scheme.surfaceContainerHigh,
          onChanged: (c) => update(ui.copyWith(composerBackgroundColor: c)),
        ),
      if (ui.composerBackground == ComposerBackground.image) ...[
        ListTile(
          leading: const Icon(Icons.image_outlined),
          title: const Text('Background picture'),
          subtitle: Text(
              ui.composerBackgroundImage == null ? 'None' : 'A picture is set'),
          trailing: ui.composerBackgroundImage == null
              ? const Icon(Icons.add_photo_alternate_outlined)
              : IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.close),
                  onPressed: () =>
                      update(ui.copyWith(composerBackgroundImage: null)),
                ),
          onTap: () => _pickImage(context, ui, update),
        ),
        SettingSwitch(
          icon: Icons.blur_on_outlined,
          title: 'Frosted blur',
          subtitle: 'Blur the picture itself for a frosted-glass look',
          value: ui.composerBackgroundBlur,
          onChanged: (v) => update(ui.copyWith(composerBackgroundBlur: v)),
        ),
        SettingSlider(
          icon: Icons.opacity_outlined,
          label: 'Picture opacity',
          value: ui.composerBackgroundOpacity.clamp(0.0, 1.0),
          min: 0,
          max: 1,
          suffix: '${(ui.composerBackgroundOpacity * 100).round()}%',
          onChanged: (v) => update(ui.copyWith(composerBackgroundOpacity: v)),
        ),
      ],
    ];
  }
}
