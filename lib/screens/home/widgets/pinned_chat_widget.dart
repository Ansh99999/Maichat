import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../models/character.dart';
import '../../../models/conversation.dart';
import '../../../models/home_layout.dart';
import '../../../services/chat_graph.dart';
import '../../../state/app_state.dart';
import '../../../widgets/character_avatar.dart';
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
  List<HomeOption> options(HomeTile tile) => [
        const HomePickOption(
          key: 'chatId',
          label: 'Chat',
          pick: HomePickKind.chat,
          allowNone: true,
          noneLabel: 'All pinned chats',
        ),
        ...chatCardOptions(),
      ];

  @override
  String describe(BuildContext context, HomeTile tile) {
    final chatId = tile.str('chatId');
    return chatId == null ? 'Pinned chat · All pinned' : 'Pinned chat';
  }

  @override
  Widget build(BuildContext context, HomeTileContext tile) {
    final state = homeWatch(
      context,
      // Which chats exist and when each moved — joined into a string, since
      // a list never compares equal and would rebuild on every notify.
      (s) => s.conversations
          .where((c) => !c.isEmpty)
          .map((c) => '${c.id}@${c.updatedAt.microsecondsSinceEpoch}'
              '${c.pinned ? '*' : ''}')
          .join('|'),
    );
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
        tile: tile.tile,
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

Character? _memberOf(Conversation conversation, AppState state, List<Character> characters) {
  final memberId = conversation.memberIds.isEmpty ? null : conversation.memberIds.first;
  if (memberId == null) return null;
  for (final c in characters) {
    if (c.id == memberId) return state.characterFor(conversation, memberId) ?? c;
  }
  return state.characterFor(conversation, memberId);
}

String _lastLinePreview(Conversation conversation) {
  if (conversation.messages.isEmpty) return '';
  final text = conversation.messages.last.content.trim();
  return text.replaceAll('\n', ' ');
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
    // A string, not a list: a fresh list never compares equal, and would
    // rebuild this card on every notify.
    final state = homeWatch(context, (s) {
      return [
        for (final tree in pinned)
          '${tree.latest.id}:${tree.latest.updatedAt}:${tree.root.title}:'
              '${_memberOf(tree.latest, s, s.characters)?.displayName}',
      ].join('|');
    });
    final characters = state.characters;
    final nameStyle = theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
    final previewStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final agoStyle = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline);
    return HomeCard(
      semanticLabel: 'Pinned chats',
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
      alignment: AlignmentDirectional.topStart,
      builder: (context, inner) {
        // Squeezed below its 2-cell minimum (a dense grid change): just the
        // pin, centred.
        if (inner.width < 56) {
          return Center(
            child: Icon(Icons.push_pin_rounded,
                color: theme.colorScheme.primary, size: 20),
          );
        }
        final avatarSize = inner.width < 110 ? 24.0 : 36.0;
        final rowH = avatarSize + 8;
        final rows = (inner.height / rowH).floor().clamp(1, pinned.length);
        final showPreview = inner.width >= 160;
        // The time only when the name keeps at least ~56 px beside it:
        // measured, so a long "3 weeks ago" or a large font cannot overflow.
        double timeWidth(ChatTreeEntry t) {
          final painter = TextPainter(
            text: TextSpan(text: relativeTime(t.latest.updatedAt), style: agoStyle),
            maxLines: 1,
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          return painter.width;
        }
        final rowChrome = 8 + avatarSize + 10 + 8 + 56;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final tree in pinned.take(rows))
              SizedBox(
                width: inner.width,
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: editing ? null : () => _open(context, tree),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        // Too narrow for a face and a name: the name alone.
                        if (inner.width >= avatarSize + 40) ...[
                          _rowAvatar(context, tree.latest, state, characters, avatarSize),
                          const SizedBox(width: 10),
                        ],
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                tree.root.title.trim().isEmpty
                                    ? 'New chat'
                                    : tree.root.title.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: nameStyle,
                              ),
                              if (showPreview)
                                Text(
                                  _lastLinePreview(tree.latest),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: previewStyle,
                                ),
                            ],
                          ),
                        ),
                        if (inner.width - rowChrome >= timeWidth(tree)) ...[
                          const SizedBox(width: 8),
                          Text(
                            relativeTime(tree.latest.updatedAt),
                            maxLines: 1,
                            style: agoStyle,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _rowAvatar(
    BuildContext context,
    Conversation conversation,
    AppState state,
    List<Character> characters,
    double size,
  ) {
    final character = _memberOf(conversation, state, characters);
    if (character == null) {
      final theme = Theme.of(context);
      return CircleAvatar(
        radius: size / 2,
        backgroundColor: theme.colorScheme.secondaryContainer,
        child: Icon(
          Icons.chat_bubble_outline_rounded,
          size: size * 0.6,
          color: theme.colorScheme.onSecondaryContainer,
        ),
      );
    }
    return CharacterAvatar(
      character: character,
      avatarOverride: state.avatarRefFor(conversation, character),
      size: size,
    );
  }
}
