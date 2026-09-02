import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_interface.dart';
import '../../state/app_state.dart';
import 'chat_interface/controls.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// What a chat *does*, as opposed to how it looks: whether a response hint can
/// steer the next reply and from how far back, and whether a chat may hold more
/// than one character.
///
/// Both of these lived under Chat Interface, which was the wrong home twice over.
/// A response hint is an injection depth — a fact about the prompt, not about the
/// screen — and group chats are a feature switch. Both are also app-wide only, so
/// on the Chat Interface page they turned into sections that went inert whenever
/// that page was opened for a single chat: a Group chat heading with its switch
/// missing, and a Response hint heading that was nothing but a paragraph
/// explaining it did not apply there.
///
/// The three settings still live on [ChatInterface] and are still read from the
/// app-wide copy, exactly as before. Only the place you edit them has moved.
class ChatBehaviourPage extends StatelessWidget {
  const ChatBehaviourPage({super.key, this.highlight});

  final SettingAnchor? highlight;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ui = state.chatInterface;
    void update(ChatInterface next) => state.updateChatInterface(next);

    return Scaffold(
      appBar: AppBar(title: const Text('Chat behaviour')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: _children(context, ui, update),
      ),
    );
  }
  List<Widget> _children(
    BuildContext context,
    ChatInterface ui,
    void Function(ChatInterface) update,
  ) =>
      [
        settingHeader(context, 'Response hint'),
        settingNote(
          context,
          'A line of steering typed beside a chat and folded into every send '
          'until you erase it, without the note ever becoming a message. The '
          'hint itself is written per chat, in the composer.',
        ),
        SettingHighlight(
          active: highlight == SettingAnchor.responseHint,
          child: SettingSwitch(
            icon: Icons.tips_and_updates_outlined,
            title: 'Enable response hints',
            subtitle: 'Steer the next reply from the composer, without the '
                'note becoming a message',
            value: ui.responseHintEnabled,
            onChanged: (v) {
              update(ui.copyWith(responseHintEnabled: v));
              notifySetting(
                  context, v ? 'Response hints on' : 'Response hints off');
            },
          ),
        ),
        if (ui.responseHintEnabled)
          SettingSlider(
            icon: Icons.vertical_align_bottom_outlined,
            label: 'Injection depth',
            value: ui.responseHintDepth.toDouble(),
            min: kMinResponseHintDepth.toDouble(),
            max: kMaxResponseHintDepth.toDouble(),
            divisions: kMaxResponseHintDepth - kMinResponseHintDepth,
            suffix: ui.responseHintDepth == 0
                ? 'Just before the reply'
                : '${ui.responseHintDepth} '
                    '${ui.responseHintDepth == 1 ? 'message' : 'messages'} '
                    'back',
            onChanged: (v) => update(ui.copyWith(responseHintDepth: v.round())),
          ),
        const Divider(height: 24),
        settingHeader(context, 'Group chats'),
        SettingHighlight(
          active: highlight == SettingAnchor.groupChats,
          child: SettingSwitch(
            icon: Icons.groups_outlined,
            title: 'Enable group chats',
            subtitle:
                'Add several characters to a chat and let each take a turn',
            value: ui.groupChatsEnabled,
            onChanged: (v) {
              update(ui.copyWith(groupChatsEnabled: v));
              notifySetting(context, v ? 'Group chats on' : 'Group chats off');
            },
          ),
        ),
        settingNote(
          context,
          ui.groupChatsEnabled
              ? 'How the participant strip above a group chat looks is in Chat '
                  'Interface ▸ Group chat bar.'
              : 'Switching this on adds a Group chat bar page to Chat '
                  'Interface, for how the participant strip looks.',
        ),
      ];
}


