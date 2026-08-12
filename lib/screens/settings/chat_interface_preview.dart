import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_interface.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../widgets/message_bubble.dart';

/// A live mock chat that reflects the current Chat Interface settings and lets
/// them be tuned by hand: drag the framed avatar to move it anywhere, pull its
/// corner handle to resize it, and use the quick controls at the bottom for
/// size and placement. Every change writes straight back to the saved settings.
class ChatInterfacePreviewPage extends StatelessWidget {
  const ChatInterfacePreviewPage({super.key});

  static final List<ChatMessage> _mock = [
    ChatMessage(
      role: 'assistant',
      content: 'Hey! This is a preview of how your chats will look. '
          'Drag my avatar to move it, or pull the corner handle to resize it.',
    ),
    ChatMessage(role: 'user', content: 'Nice — let me tweak the colours and size.'),
    ChatMessage(
      role: 'assistant',
      content: 'Go ahead. Everything you change updates here live.',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ui = state.chatInterface;
    final bg = ui.backgroundColor != null
        ? Color(ui.backgroundColor!)
        : Theme.of(context).colorScheme.surface;

    void update(ChatInterface next) => context.read<AppState>().updateChatInterface(next);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Preview'),
        actions: [
          if (ui.avatarOffsetX != 0 || ui.avatarOffsetY != 0)
            TextButton(
              onPressed: () =>
                  update(ui.copyWith(avatarOffsetX: 0, avatarOffsetY: 0)),
              child: const Text('Reset position'),
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
                  // The first assistant turn is the interactive one.
                  final interactive = i == 0;
                  return MessageBubble(
                    message: message,
                    ui: ui,
                    interactive: interactive,
                    onAvatarDrag: interactive
                        ? (d) => update(ui.copyWith(
                              avatarOffsetX:
                                  (ui.avatarOffsetX + d.dx).clamp(-160.0, 160.0),
                              avatarOffsetY:
                                  (ui.avatarOffsetY + d.dy).clamp(-160.0, 160.0),
                            ))
                        : null,
                    onAvatarResize: interactive
                        ? (d) => update(ui.copyWith(
                              avatarSize: (ui.avatarSize + d)
                                  .clamp(kMinAvatarSize, kMaxAvatarSize),
                            ))
                        : null,
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
}

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
              'Drag the framed avatar to reposition it; pull the corner handle '
              'to resize.',
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

/// A compact tuning bar pinned under the mock chat: avatar size and text
/// placement, the two things most worth seeing change live.
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
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.photo_size_select_large_outlined, size: 20),
                  const SizedBox(width: 12),
                  const Text('Size'),
                  Expanded(
                    child: Slider(
                      value: ui.avatarSize
                          .clamp(kMinAvatarSize, kMaxAvatarSize),
                      min: kMinAvatarSize,
                      max: kMaxAvatarSize,
                      onChanged: (v) => onChanged(ui.copyWith(avatarSize: v)),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text(
                      '${ui.avatarSize.round()}',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
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
            ],
          ),
        ),
      ),
    );
  }
}

