import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/conversation.dart';
import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_playground.dart';
import '../../state/app_state.dart';
import '../chat_export.dart';
import '../chat_import.dart';
import '../chat_screen.dart';
import '../presets/chat_preset_panel.dart';
import '../settings/chat_behaviour_page.dart';
import '../settings/chat_interface_settings_page.dart';
import '../settings/setting_anchors.dart';
import 'shell/liquid_panel.dart';

/// The Playground: the app's own chat screen, on a chat with the draft.
///
/// Nothing of the chat is rebuilt here. The thread, the bubbles and every
/// action on them, the pictures floating over it, the composer with its
/// persona, strip and pictures are [ChatScreen]'s own, styled by the app's Chat
/// Interface, and a send goes through the same path any chat's does — with the
/// draft as the character (the session hosts the chat: [StudioPlayground]).
/// What the Studio swaps in is [host]: its own sidebar ([PlaygroundDrawer])
/// and the way back to its areas.
///
/// Built only once the Playground has been opened — until then there is no
/// chat of the session's on screen to show.
class StudioPlaygroundView extends StatelessWidget {
  const StudioPlaygroundView({
    super.key,
    required this.controller,
    required this.host,
  });

  final StudioController controller;
  final ChatScreenHost host;

  @override
  Widget build(BuildContext context) {
    final hosted = context.select<AppState, bool>(
      (s) => identical(s.chatHost, controller.playground),
    );
    if (!hosted) {
      return ColoredBox(color: Theme.of(context).colorScheme.surface);
    }
    return ChatScreen(key: const Key('studio-playground-chat'), host: host);
  }
}

/// The Playground's sidebar. Across the top, symbols only: the chat's preset,
/// the provider, group chats and the Chat Interface — each opening exactly what
/// the chat's own sidebar opens. Under a hairline with a + (a new chat with
/// the draft), the chats had with it, newest first: the user's and the agents'
/// playtests alike. A long press pours out what can be done with one.
class PlaygroundDrawer extends StatefulWidget {
  const PlaygroundDrawer({super.key, required this.controller});

  final StudioController controller;

  @override
  State<PlaygroundDrawer> createState() => _PlaygroundDrawerState();
}

class _PlaygroundDrawerState extends State<PlaygroundDrawer> {
  StudioPlayground get _playground => widget.controller.playground;

  /// Whether the preset panel has the drawer, as in the chat's own sidebar.
  bool _presets = false;

  /// The chat whose options are poured out, and where it was pressed.
  StudioPlaytest? _options;
  Offset _anchor = Offset.zero;
  final GlobalKey _stackKey = GlobalKey();

  /// Closes the drawer, then runs [action] with the navigator's context —
  /// one that outlives the drawer, for whatever the action opens.
  void _closeThen(void Function(BuildContext context) action) {
    final navigator = Navigator.of(context);
    navigator.pop();
    action(navigator.context);
  }

  void _push(Widget page) => _closeThen((context) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => page)));

  void _newChat() {
    final test = _playground.startChat();
    context.read<AppState>().selectConversation(test.chat.id);
    Navigator.of(context).pop();
  }

  void _open(StudioPlaytest test) {
    context.read<AppState>().selectConversation(test.chat.id);
    Navigator.of(context).pop();
  }

  void _pour(StudioPlaytest test, Offset global) {
    final box = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    setState(() {
      _options = test;
      _anchor = box == null ? global : box.globalToLocal(global);
    });
  }

  void _drain() => setState(() => _options = null);

  Future<void> _export(StudioPlaytest test) async {
    _drain();
    await exportChat(context, test.chat);
  }

  Future<void> _import() async {
    _drain();
    await importChats(
      context,
      into: (chats) async => _playground.importChats(chats),
    );
  }

  Future<void> _delete(StudioPlaytest test) async {
    _drain();
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text('"${_title(test)}" will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('playground-delete-confirm'),
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppState>().deleteConversation(test.chat.id);
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Easing.emphasizedDecelerate,
          switchOutCurve: Easing.emphasizedAccelerate,
          transitionBuilder: (child, animation) {
            final incoming = child.key == ValueKey<bool>(_presets);
            final dir = _presets ? 1.0 : -1.0;
            return SlideTransition(
              position: Tween<Offset>(
                begin: Offset((incoming ? dir : -dir) * 0.25, 0),
                end: Offset.zero,
              ).animate(animation),
              child: child,
            );
          },
          layoutBuilder: (current, previous) => Stack(
            fit: StackFit.expand,
            children: [...previous, ?current],
          ),
          child: KeyedSubtree(
            key: ValueKey<bool>(_presets),
            child: _presets
                ? ChatPresetPanel(onBack: () => setState(() => _presets = false))
                : _menu(context),
          ),
        ),
      ),
    );
  }

  Widget _menu(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final state = context.watch<AppState>();
    final current = state.hostedChatId;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        // Three rows of options.
        const height = 3 * 56.0 + 16;
        final below = _anchor.dy + 12 + height < constraints.maxHeight;
        final top = below
            ? _anchor.dy + 12
            : (_anchor.dy - 12 - height).clamp(8.0, constraints.maxHeight);
        return Stack(
          key: _stackKey,
          children: [
            Positioned.fill(
              child: ListenableBuilder(
                listenable: widget.controller,
                builder: (context, _) => Column(
                  children: [
                    Padding(
                      key: const Key('playground-symbols'),
                      padding: const EdgeInsets.fromLTRB(12, 16, 12, 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _Symbol(
                            key: const Key('playground-preset'),
                            icon: Icons.tune_outlined,
                            tooltip: 'Preset',
                            onPressed: () => setState(() => _presets = true),
                          ),
                          _Symbol(
                            key: const Key('playground-provider'),
                            icon: Icons.dns_outlined,
                            tooltip: 'Provider & model',
                            onPressed: () => _closeThen(showChatProviderSheet),
                          ),
                          _Symbol(
                            key: const Key('playground-group'),
                            icon: Icons.groups_outlined,
                            tooltip: 'Group chats',
                            onPressed: () => _push(const ChatBehaviourPage(
                              highlight: SettingAnchor.groupChats,
                            )),
                          ),
                          _Symbol(
                            key: const Key('playground-interface'),
                            icon: Icons.chat_bubble_outline,
                            tooltip: 'Chat Interface',
                            onPressed: () =>
                                _push(const ChatInterfaceSettingsPage()),
                          ),
                        ],
                      ),
                    ),
                    // A hairline, and on it the way to a new chat.
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: Divider(
                              height: 1,
                              thickness: 1,
                              color: scheme.outlineVariant,
                            ),
                          ),
                          IconButton(
                            key: const Key('playground-new'),
                            tooltip: 'New chat',
                            visualDensity: VisualDensity.compact,
                            onPressed: _newChat,
                            icon: const Icon(Icons.add),
                          ),
                          Expanded(
                            child: Divider(
                              height: 1,
                              thickness: 1,
                              color: scheme.outlineVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        key: const Key('playground-chats'),
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                        children: [
                          for (final test in _playground.playtests)
                            _ChatRow(
                              key: Key('playground-chat-${test.id}'),
                              test: test,
                              title: _title(test),
                              selected: test.chat.id == current,
                              onTap: () => _open(test),
                              onLongPress: (at) => _pour(test, at),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned.fill(
              child: LiquidPanel(
                open: _options != null,
                anchor: _anchor,
                anchorRadius: 16,
                panel: Rect.fromLTWH(12, top, width - 24, height),
                color: scheme.surfaceContainerHighest,
                onDismiss: _drain,
                child: _Options(
                  onExport: () {
                    final test = _options;
                    if (test != null) _export(test);
                  },
                  onImport: _import,
                  onDelete: () {
                    final test = _options;
                    if (test != null) _delete(test);
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// What a chat is called in the list: its own title, or what was said in it.
String _title(StudioPlaytest test) {
  final own = test.title.trim();
  if (own.isNotEmpty) return own;
  for (final m in test.chat.messages) {
    if (m.isUser && m.content.trim().isNotEmpty) return _line(m.content);
  }
  return test.byUser ? 'New chat' : 'Playtest';
}

String _line(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 60 ? flat : '${flat.substring(0, 60)}…';
}

/// The newest thing said in [chat], for the row's second line.
String _preview(Conversation chat) {
  for (final m in chat.messages.reversed) {
    if (m.content.trim().isNotEmpty) return _line(m.content);
  }
  return 'Nothing said yet';
}

class _Symbol extends StatelessWidget {
  const _Symbol({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton.filledTonal(
        tooltip: tooltip,
        iconSize: 22,
        style: IconButton.styleFrom(
          fixedSize: const Size(52, 52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        onPressed: onPressed,
        icon: Icon(icon),
      );
}

class _ChatRow extends StatelessWidget {
  const _ChatRow({
    super.key,
    required this.test,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final StudioPlaytest test;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: GestureDetector(
          onLongPressStart: (d) => onLongPress(d.globalPosition),
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: selected
                                ? scheme.onSecondaryContainer
                                : scheme.onSurface,
                          ),
                        ),
                      ),
                      if (!test.byUser) ...[
                        const SizedBox(width: 8),
                        _AgentMark(by: test.by),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _preview(test.chat),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Which agent ran a playtest: "the main agent" reads as "Main".
class _AgentMark extends StatelessWidget {
  const _AgentMark({required this.by});

  final String by;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = by == 'the main agent' ? 'Main' : by;
    return Container(
      key: const Key('playground-agent-mark'),
      padding: const EdgeInsets.fromLTRB(6, 2, 8, 2),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.smart_toy_outlined,
              size: 13, color: scheme.onTertiaryContainer),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: scheme.onTertiaryContainer),
          ),
        ],
      ),
    );
  }
}

/// What can be done with a chat, poured out of where it was pressed.
class _Options extends StatelessWidget {
  const _Options({
    required this.onExport,
    required this.onImport,
    required this.onDelete,
  });

  final VoidCallback onExport;
  final VoidCallback onImport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    ListTile row(Key key, IconData icon, String label, VoidCallback onTap,
            {Color? color}) =>
        ListTile(
          key: key,
          leading: Icon(icon, color: color),
          title: Text(label, style: TextStyle(color: color)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          onTap: onTap,
        );
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(const Key('playground-export'), Icons.ios_share_outlined,
              'Export', onExport),
          row(const Key('playground-import'), Icons.download_outlined,
              'Import', onImport),
          row(const Key('playground-delete'), Icons.delete_outline, 'Delete',
              onDelete,
              color: scheme.error),
        ],
      ),
    );
  }
}
