import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/settings.dart';
import '../../state/app_state.dart';
import '../../widgets/btw_arrow_opacity_setting.dart';
import 'chat_interface/controls.dart';

/// Global preferences for durable side conversations.
class BtwSettingsPage extends StatelessWidget {
  const BtwSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final settings = state.btwSettings;
    return Scaffold(
      appBar: AppBar(title: const Text('Side conversations')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          settingHeader(context, 'Main chat'),
          BtwArrowOpacitySetting(state: state),
          const Divider(height: 24),
          settingHeader(context, 'New thread titles'),
          SettingEnumRow<BtwTitleMode>(
            key: const Key('btw-title-mode'),
            icon: Icons.title,
            label: 'Thread title',
            value: settings.titleMode,
            values: BtwTitleMode.values,
            labelOf: (mode) => mode.label,
            onChanged: (mode) =>
                state.updateBtwSettings(settings.copyWith(titleMode: mode)),
          ),
          settingNote(
            context,
            settings.titleMode == BtwTitleMode.generated
                ? 'Generate a short title after the first answer using the thread’s provider. '
                      'This makes one additional request. The first line stays as the title if it cannot finish.'
                : 'Use the first line of the opening question as the title.',
          ),
          const Divider(height: 24),
          settingHeader(context, 'Saved beside your chat'),
          settingNote(
            context,
            'Each /btw thread keeps its questions, answers and settings. '
            'Use the arrow at the right of the chat to reopen it. Choose its provider, system prompt and tools in the thread settings.',
          ),
        ],
      ),
    );
  }
}
