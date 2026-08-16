import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/character.dart';
import '../../models/chat_interface.dart';
import '../../models/message.dart';
import '../../state/app_state.dart';
import '../../widgets/message_bubble.dart';
import 'chat_ui_scope.dart';

/// A live mock chat that reflects the current Chat Interface settings and lets
/// them be tuned by hand. Both avatars are independent: drag either framed
/// avatar to move it, pull its corner handle to resize it. With names on, each
/// name label is draggable too — that is how a name is pulled down close to the
/// message body it labels. Every change writes straight back to the saved
/// settings (respecting the sync toggles), or to [scope]'s draft when one is
/// given.
class ChatInterfacePreviewPage extends StatelessWidget {
  const ChatInterfacePreviewPage({super.key, this.scope});

  final ChatUiScope? scope;

  // A stand-in character so the reply avatar shows a real monogram.
  static final Character _character = Character.empty()..name = 'Aria';

  static final List<ChatMessage> _mock = [
    ChatMessage(
      role: 'assistant',
      content: 'Hey! Drag my avatar to move it, or pull the corner handle to '
          'resize it. I keep my own settings.\n\nThis turn runs a few lines on '
          'purpose: a reply is usually taller than its avatar, so you can see '
          'where a name set to "below the avatar" actually lands versus one set '
          'above the message.',
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
    final scope = this.scope;
    if (scope == null) return _body(context);
    return ValueListenableBuilder<ChatInterface>(
      valueListenable: scope.draft,
      builder: (context, _, _) => _body(context),
    );
  }

  Widget _body(BuildContext context) {
    final scope = this.scope;
    final ui = scope?.draft.value ?? context.watch<AppState>().chatInterface;
    final bg = ui.backgroundColor != null
        ? Color(ui.backgroundColor!)
        : Theme.of(context).colorScheme.surface;

    void update(ChatInterface next) {
      if (scope != null) {
        scope.draft.value = next;
      } else {
        context.read<AppState>().updateChatInterface(next);
      }
    }

    // Every nudge reads the *live* settings rather than this build's snapshot: a
    // finger produces several move events per frame, and against a stale
    // snapshot each one would overwrite the last instead of adding to it — which
    // is most of why dragging felt like it did nothing.
    ChatInterface live() =>
        scope?.draft.value ?? context.read<AppState>().chatInterface;

    // Nudge/resize the given role's own avatar (sync is honoured by withAvatar).
    void drag(bool isUser, Offset d) {
      final now = live();
      final s = now.avatarFor(isUser);
      update(now.withAvatar(
        isUser,
        s.copyWith(
          offsetX: (s.offsetX + d.dx).clamp(-200.0, 200.0),
          offsetY: (s.offsetY + d.dy).clamp(-200.0, 200.0),
        ),
      ));
    }

    void resize(bool isUser, double d) {
      final now = live();
      final s = now.avatarFor(isUser);
      update(now.withAvatar(
        isUser,
        s.copyWith(size: (s.size + d).clamp(kMinAvatarSize, kMaxAvatarSize)),
      ));
    }

    // Drag a name label around (sync is honoured by withName).
    void dragName(bool isUser, Offset d) {
      final now = live();
      final n = now.nameFor(isUser);
      update(now.withName(
        isUser,
        n.copyWith(
          offsetX: (n.offsetX + d.dx).clamp(-kMaxNameOffset, kMaxNameOffset),
          offsetY: (n.offsetY + d.dy).clamp(-kMaxNameOffset, kMaxNameOffset),
        ),
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
                botNameStyle:
                    ui.botNameStyle.copyWith(offsetX: 0, offsetY: 0),
                userNameStyle:
                    ui.userNameStyle.copyWith(offsetX: 0, offsetY: 0),
              )),
              child: const Text('Reset positions'),
            ),
        ],
      ),
      body: Column(
        children: [
          _Hint(showNames: ui.showNames),
          Expanded(
            child: Container(
              color: bg,
              width: double.infinity,
              // The mock chat deliberately does not scroll. A scrollable would
              // take any mostly-vertical drag off the handles for itself, which
              // is exactly the direction an avatar or a name needs to move.
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final message in _mock)
                      MessageBubble(
                        message: message,
                        ui: ui,
                        character: message.isUser ? null : _character,
                        interactive: true,
                        onAvatarDrag: (d) => drag(message.isUser, d),
                        onAvatarResize: (d) => resize(message.isUser, d),
                        onNameDrag: (d) => dragName(message.isUser, d),
                      ),
                  ],
                ),
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
      ui.userAvatar.offsetY != 0 ||
      ui.botNameStyle.isNudged ||
      ui.userNameStyle.isNudged;
}
// APPEND-PREVIEW

/// The instruction strip above the mock chat.
class _Hint extends StatelessWidget {
  const _Hint({required this.showNames});

  final bool showNames;

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
              showNames
                  ? 'Drag either avatar to reposition it, pull its corner handle '
                      'to resize — and drag a name label to sit it where you '
                      'want it. This mock chat does not scroll, so a drag always '
                      'lands.'
                  : 'Each avatar is independent — drag either one to reposition '
                      'it, pull its corner handle to resize.',
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
/// most worth seeing change live — where the text sits, the toggles that decide
/// what is even on screen, and the gap between turns.
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
              const SizedBox(height: 8),
              // Chips instead of switches: four toggles fit on one narrow row.
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilterChip(
                    label: const Text('Bubbles'),
                    selected: ui.bubbles,
                    onSelected: (v) => onChanged(ui.copyWith(bubbles: v)),
                  ),
                  FilterChip(
                    label: const Text('Names'),
                    selected: ui.showNames,
                    onSelected: (v) => onChanged(ui.copyWith(showNames: v)),
                  ),
                  FilterChip(
                    label: const Text('Sync avatars'),
                    selected: ui.syncAvatars,
                    onSelected: (v) => onChanged(ui.copyWith(syncAvatars: v)),
                  ),
                  FilterChip(
                    label: const Text('Sync names'),
                    selected: ui.syncNames,
                    onSelected: (v) => onChanged(ui.copyWith(syncNames: v)),
                  ),
                ],
              ),
              Row(
                children: [
                  Icon(Icons.height_outlined,
                      size: 18, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text('Spacing',
                      style: Theme.of(context).textTheme.labelMedium),
                  Expanded(
                    child: Slider(
                      value: ui.messageSpacing
                          .clamp(kMinMessageSpacing, kMaxMessageSpacing),
                      min: kMinMessageSpacing,
                      max: kMaxMessageSpacing,
                      onChanged: (v) => onChanged(
                          ui.copyWith(messageSpacing: v.roundToDouble())),
                    ),
                  ),
                  Text('${ui.messageSpacing.round()} px',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          )),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

