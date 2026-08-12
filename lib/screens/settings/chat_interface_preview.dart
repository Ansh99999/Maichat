import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/character.dart';
import '../../models/chat_interface.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../widgets/message_bubble.dart';

/// A live mock chat that reflects the current Chat Interface settings and lets
/// them be tuned by hand. Both avatars are independent: drag either framed
/// avatar to move it, pull its corner handle to resize it. Every change writes
/// straight back to the saved settings (respecting the sync toggle).
class ChatInterfacePreviewPage extends StatelessWidget {
  const ChatInterfacePreviewPage({super.key});

  // A stand-in character so the reply avatar shows a real monogram.
  static final Character _character = Character.empty()..name = 'Aria';

  static final List<ChatMessage> _mock = [
    ChatMessage(
      role: 'assistant',
      content: 'Hey! Drag my avatar to move it, or pull the corner handle to '
          'resize it. I keep my own settings.',
    ),
    ChatMessage(
      role: 'user',
      content: 'And this is your avatar — independent from mine. Tune each side '
          'however you like.',
    ),
    ChatMessage(
      role: 'assistant',
      content: 'Turn on Sync in settings if you want us to match.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ui = state.chatInterface;
    final bg = ui.backgroundColor != null
        ? Color(ui.backgroundColor!)
        : Theme.of(context).colorScheme.surface;

    void update(ChatInterface next) =>
        context.read<AppState>().updateChatInterface(next);

    // Nudge/resize the given role's own avatar (sync is honoured by withAvatar).
    void drag(bool isUser, Offset d) {
      final s = ui.avatarFor(isUser);
      update(ui.withAvatar(
        isUser,
        s.copyWith(
          offsetX: (s.offsetX + d.dx).clamp(-200.0, 200.0),
          offsetY: (s.offsetY + d.dy).clamp(-200.0, 200.0),
        ),
      ));
    }

    void resize(bool isUser, double d) {
      final s = ui.avatarFor(isUser);
      update(ui.withAvatar(
        isUser,
        s.copyWith(size: (s.size + d).clamp(kMinAvatarSize, kMaxAvatarSize)),
      ));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        actions: [
          if (_nudged(ui))
            TextButton(
              onPressed: () => update(ui.copyWith(
                botAvatar: ui.botAvatar.copyWith(offsetX: 0, offsetY: 0),
                userAvatar: ui.userAvatar.copyWith(offsetX: 0, offsetY: 0),
              )),
              child: const Text('Reset positions'),
            ),
        ],
      ),
      body: Column(
        children: [
          _Hint(),
          Expanded(
            child: Container(
              color: bg,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 12),
                itemCount: _mock.length,
                itemBuilder: (context, i) {
                  final message = _mock[i];
                  final isUser = message.isUser;
                  return MessageBubble(
                    message: message,
                    ui: ui,
                    character: isUser ? null : _character,
                    interactive: true,
                    onAvatarDrag: (d) => drag(isUser, d),
                    onAvatarResize: (d) => resize(isUser, d),
                  );
                },
              ),
            ),
          ),
          _QuickControls(ui: ui, onChanged: update),
        ],
      ),
    );
  }

  static bool _nudged(ChatInterface ui) =>
      ui.botAvatar.offsetX != 0 ||
      ui.botAvatar.offsetY != 0 ||
      ui.userAvatar.offsetX != 0 ||
      ui.userAvatar.offsetY != 0;
}
// APPEND-PREVIEW

/// The instruction strip above the mock chat.
class _Hint extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          Icon(Icons.touch_app_outlined,
              size: 18, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Each avatar is independent — drag either one to reposition it, '
              'pull its corner handle to resize.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSecondaryContainer,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A compact tuning bar pinned under the mock chat: the layout-level options
/// most worth seeing change live.
class _QuickControls extends StatelessWidget {
  const _QuickControls({required this.ui, required this.onChanged});

  final ChatInterface ui;
  final ValueChanged<ChatInterface> onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<TextPlacement>(
                  showSelectedIcon: false,
                  segments: [
                    for (final p in TextPlacement.values)
                      ButtonSegment<TextPlacement>(
                        value: p,
                        label: Text(p.label),
                      ),
                  ],
                  selected: {ui.textPlacement},
                  onSelectionChanged: (s) =>
                      onChanged(ui.copyWith(textPlacement: s.first)),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: ui.bubbles,
                      onChanged: (v) => onChanged(ui.copyWith(bubbles: v)),
                      title: const Text('Bubbles'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: ui.syncAvatars,
                      onChanged: (v) => onChanged(ui.copyWith(syncAvatars: v)),
                      title: const Text('Sync'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

