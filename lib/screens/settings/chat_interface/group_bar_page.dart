import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../models/chat_interface.dart';
import '../../../state/app_state.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import 'controls.dart';
import 'spoke.dart';

/// The look of the participant strip a group chat draws above the thread: how
/// tall it is, what colour it takes, and an optional picture behind it.
///
/// Whether group chats exist at all is not here — that is a feature switch, and
/// it lives in Chat behaviour. This page is only reachable while it is on.
class GroupBarSpokePage extends StatelessWidget {
  const GroupBarSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  /// Picks a device image for the group bar's background, stores it in the
  /// avatar directory (so it round-trips like every other picture) and writes the
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
    if (ref != null) update(ui.copyWith(groupBarImage: ref));
  }
  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Group chat bar',
          scope: scope,
          resetLabel: 'Reset the bar to defaults',
          onReset: () {
            const d = ChatInterface();
            update(ui.copyWith(
              groupBarHeight: d.groupBarHeight,
              groupBarColor: null,
              groupBarImage: null,
            ));
            notifySetting(context, 'Participant bar back to defaults');
          },
          children: [
            SettingSlider(
              icon: Icons.height_outlined,
              label: 'Participant bar height',
              value:
                  ui.groupBarHeight.clamp(kMinGroupBarHeight, kMaxGroupBarHeight),
              min: kMinGroupBarHeight,
              max: kMaxGroupBarHeight,
              suffix: '${ui.groupBarHeight.round()} px',
              onChanged: (v) => update(ui.copyWith(groupBarHeight: v)),
            ),
            SettingColorRow(
              label: 'Participant bar',
              value: ui.groupBarColor,
              fallback: Theme.of(context).colorScheme.surfaceContainerHigh,
              onChanged: (c) => update(ui.copyWith(groupBarColor: c)),
            ),
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('Participant bar picture'),
              subtitle:
                  Text(ui.groupBarImage == null ? 'None' : 'A picture is set'),
              trailing: ui.groupBarImage == null
                  ? const Icon(Icons.add_photo_alternate_outlined)
                  : IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.close),
                      onPressed: () => update(ui.copyWith(groupBarImage: null)),
                    ),
              onTap: () => _pickImage(context, ui, update),
            ),
          ],
        ),
      );
}

