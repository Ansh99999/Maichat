import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/home_layout.dart';
import '../../../services/chat_graph.dart';
import '../../../state/app_state.dart';
import '../../chat_screen.dart';
import '../../chats_screen.dart' show relativeTime;
import '../home_spec.dart';
import 'chat_card_tile.dart';

/// One chat the user chose to pin here, or — with none chosen — a compact
/// list of every pinned chat.
class PinnedChatSpec extends HomeWidgetSpec {
  const PinnedChatSpec();

  @override
  HomeWidgetKind get kind => HomeWidgetKind.pinnedChat;

  @override
  String get title => 'Pinned chat';

  @override
  String get description => 'One chat you chose, or your pinned chats as a list';

  @override
  IconData get icon => Icons.push_pin_outlined;

  @override
  ({int w, int h}) get minSpan => (w: 2, h: 1);

  @override
  List<HomeOption> options(HomeTile tile) => const [
        HomePickOption(
          key: 'chatId',
          label: 'Chat',
          pick: HomePickKind.chat,
          allowNone: true,
          noneLabel: 'All pinned chats',
        ),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final chatId = tile.str('chatId');
    return chatId == null ? 'Pinned chat · All pinned' : 'Pinned chat';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = context.watch<AppState>();
    final chats = state.conversations.where((c) => !c.isEmpty).toList();
    final trees = collapseForks(chats);
    final chatId = tile.tile.str('chatId');

    if (chatId != null) {
      ChatTreeEntry? found;
      for (final t in trees) {
        if (t.members.any((c) => c.id == chatId)) {
          found = t;
          break;
        }
      }
      if (found == null) {
        return const HomeEmptyCard(
          icon: Icons.push_pin_outlined,
          message: 'Pin a chat to keep it here',
        );
      }
      return ChatPreviewCard(
        tree: found,
        editing: tile.editing,
        compact: tile.compact,
      );
    }

    final pinned = trees.where((t) => t.pinned).toList();
    if (pinned.isEmpty) {
      return const HomeEmptyCard(
        icon: Icons.push_pin_outlined,
        message: 'Pin a chat to keep it here',
      );
    }
    return _PinnedList(pinned: pinned, editing: tile.editing);
  }
}

class _PinnedList extends StatelessWidget {
  const _PinnedList({required this.pinned, required this.editing});

  final List<ChatTreeEntry> pinned;
  final bool editing;

  void _open(BuildContext context, ChatTreeEntry tree) {
    if (editing) return;
    context.read<AppState>().selectConversation(tree.latest.id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rowStyle = theme.textTheme.bodyMedium;
    return HomeCard(
      semanticLabel: 'Pinned chats',
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      alignment: AlignmentDirectional.topStart,
      builder: (context, inner) {
        final headerH = homeLineHeight(context, theme.textTheme.labelLarge) + 4;
        final rowH = homeLineHeight(context, rowStyle) + 8;
        final showHeader = inner.height >= headerH + rowH;
        final rows = ((inner.height - (showHeader ? headerH : 0)) / rowH)
            .floor()
            .clamp(1, pinned.length);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showHeader)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(
                  children: [
                    Icon(Icons.push_pin_rounded,
                        size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        'Pinned',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge,
                      ),
                    ),
                  ],
                ),
              ),
            for (final tree in pinned.take(rows))
              InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: editing ? null : () => _open(context, tree),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          tree.root.title.trim().isEmpty
                              ? 'New chat'
                              : tree.root.title.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: rowStyle,
                        ),
                      ),
                      if (inner.width > 140) ...[
                        const SizedBox(width: 8),
                        Text(
                          relativeTime(tree.latest.updatedAt),
                          maxLines: 1,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
