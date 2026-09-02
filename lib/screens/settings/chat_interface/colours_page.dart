import 'package:flutter/material.dart';

import '../../../models/chat_interface.dart';
import '../chat_ui_scope.dart';
import '../setting_anchors.dart';
import '../setting_highlight.dart';
import 'controls.dart';
import 'spoke.dart';

/// The surfaces a chat is painted on: the two text colours, the two bubble
/// colours and the background behind them.
///
/// The emphasis and quote colours are *not* here — they live with Markdown and
/// the wrapping rules under Text, because that is what they are part of: a
/// wrapping rule is a symbol pair with a colour, and asterisks and quotes are
/// the two built-in cases of exactly that.
class ColoursSpokePage extends StatelessWidget {
  const ColoursSpokePage({super.key, this.highlight, this.scope});

  final SettingAnchor? highlight;
  final ChatUiScope? scope;

  @override
  Widget build(BuildContext context) => ChatUiBuilder(
        scope: scope,
        builder: (context, ui, update) => SpokeScaffold(
          title: 'Colours',
          scope: scope,
          resetLabel: 'Follow the theme again',
          onReset: () {
            update(ui.copyWith(
              userTextColor: null,
              botTextColor: null,
              userBubbleColor: null,
              botBubbleColor: null,
              backgroundColor: null,
            ));
            notifySetting(context, 'Colours follow the theme');
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
      settingNote(
        context,
        'Each of these follows the app theme until you set it. Clear one to '
        'hand it back.',
      ),
      SettingHighlight(
        active: highlight == SettingAnchor.chatColours,
        child: SettingColorRow(
          label: 'Your text',
          value: ui.userTextColor,
          fallback: scheme.onPrimaryContainer,
          onChanged: (c) => update(ui.copyWith(userTextColor: c)),
        ),
      ),
      SettingColorRow(
        label: 'Reply text',
        value: ui.botTextColor,
        fallback: scheme.onSurface,
        onChanged: (c) => update(ui.copyWith(botTextColor: c)),
      ),
      SettingColorRow(
        label: 'Your bubble',
        value: ui.userBubbleColor,
        fallback: scheme.primaryContainer,
        onChanged: (c) => update(ui.copyWith(userBubbleColor: c)),
      ),
      SettingColorRow(
        label: 'Reply bubble',
        value: ui.botBubbleColor,
        fallback: scheme.surfaceContainerHighest,
        onChanged: (c) => update(ui.copyWith(botBubbleColor: c)),
      ),
      SettingColorRow(
        label: 'Chat background',
        value: ui.backgroundColor,
        fallback: scheme.surface,
        onChanged: (c) => update(ui.copyWith(backgroundColor: c)),
      ),
      if (!ui.bubbles)
        settingNote(
          context,
          'Bubbles are off, so the two bubble colours are not drawn — the text '
          'sits straight on the background.',
        ),
    ];
  }
}

