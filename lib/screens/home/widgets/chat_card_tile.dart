import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../services/chat_graph.dart';
import '../../../state/app_state.dart';
import '../../../widgets/character_avatar.dart';
import '../../chat_screen.dart';
import '../../chats_screen.dart' show relativeTime;
import '../home_spec.dart';

/// The shared look for one chat tree shown as a card: avatar top-left, title
/// top-right, a line of the latest message, and "X ago" at the bottom.
///
/// Used by both the recent-chat and pinned-chat widgets so the two read as the
/// same kind of thing on the grid.
class ChatPreviewCard extends StatelessWidget {
  const ChatPreviewCard({
    super.key,
    required this.tree,
    required this.editing,
    this.showPreview = true,
    this.compact = false,
  });

  final ChatTreeEntry tree;
  final bool editing;
  final bool showPreview;

  /// A short tile (1 row tall, or otherwise cramped): one preview line only.
  final bool compact;

  void _open(BuildContext context) {
    if (editing) return;
    final state = context.read<AppState>();
    state.selectConversation(tree.latest.id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final latest = tree.latest;
    final preview = _previewOf(latest);
    final memberId = latest.memberIds.isEmpty ? null : latest.memberIds.first;
    final character = memberId == null ? null : state.characterById(memberId);
    final avatarRef =
        character == null ? null : state.avatarRefFor(latest, character);
    final title = tree.root.title.trim().isEmpty
        ? (character?.displayName ?? 'New chat')
        : tree.root.title.trim();
    final ago = relativeTime(latest.updatedAt);

    final scheme = theme.colorScheme;
    final titleStyle =
        theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
    final previewStyle =
        theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant);
    final agoStyle = theme.textTheme.labelSmall?.copyWith(color: scheme.outline);

    return HomeCard(
      semanticLabel: '$title${preview.isEmpty ? '' : ', $preview'}, $ago',
      onTap: editing ? null : () => _open(context),
      builder: (context, inner) {
        // Measured, not guessed from the span: the avatar row, then the
        // preview gets every line the height has left, then the time.
        final titleH = homeLineHeight(context, titleStyle);
        final previewH = homeLineHeight(context, previewStyle);
        final agoH = homeLineHeight(context, agoStyle);
        final avatar = inner.height >= 72 ? 16.0 : 12.0;
        final header = titleH > avatar * 2 ? titleH : avatar * 2;
        final showAgo = inner.height >= header + agoH + 4;
        var room = inner.height - header - (showAgo ? agoH + 4 : 0) - 6;
        var lines = 0;
        if (showPreview && preview.isNotEmpty) {
          lines = (room / previewH).floor().clamp(0, compact ? 1 : 4);
        }
        // A wide-but-short card puts the time beside the title instead.
        final agoInline = !showAgo && inner.width > 220;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                character == null
                    ? CircleAvatar(
                        radius: avatar,
                        backgroundColor: scheme.secondaryContainer,
                        child: Icon(
                          Icons.chat_bubble_outline_rounded,
                          size: avatar,
                          color: scheme.onSecondaryContainer,
                        ),
                      )
                    : CharacterAvatar(
                        character: character,
                        avatarOverride: avatarRef,
                        radius: avatar,
                      ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: titleStyle,
                  ),
                ),
                if (agoInline) ...[
                  const SizedBox(width: 8),
                  Text(ago, maxLines: 1, style: agoStyle),
                ],
              ],
            ),
            if (lines > 0) ...[
              const SizedBox(height: 6),
              Text(
                preview,
                maxLines: lines,
                overflow: TextOverflow.ellipsis,
                style: previewStyle,
              ),
            ],
            if (showAgo) ...[
              const SizedBox(height: 4),
              Text(
                ago,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: agoStyle,
              ),
            ],
          ],
        );
      },
    );
  }
}

String _previewOf(dynamic conversation) {
  final messages = conversation.messages as List;
  if (messages.isEmpty) return '';
  final last = messages.last;
  final text = (last.content as String).trim();
  return text;
}

/// A gentle empty-state card, for a widget with nothing to show yet.
class HomeEmptyCard extends StatelessWidget {
  const HomeEmptyCard({
    super.key,
    required this.icon,
    required this.message,
    this.compact = false,
  });

  final IconData icon;
  final String message;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return HomeCard(
      semanticLabel: message,
      alignment: Alignment.center,
      builder: (context, inner) {
        final iconSize = inner.height >= 80 ? 28.0 : 20.0;
        final lineH = homeLineHeight(context, style);
        final wide = inner.width > inner.height * 1.6;
        final showMessage = !compact || wide;
        // A short, wide card reads best as one line: icon then words.
        // (Two lines under the icon need more height than this card has.)
        if (wide && inner.height < iconSize + 8 + lineH * 2 + 8) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: iconSize, color: theme.colorScheme.outline),
              const SizedBox(width: 10),
              Flexible(
                child: Text(
                  message,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: style,
                ),
              ),
            ],
          );
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: theme.colorScheme.outline),
            if (showMessage && inner.height >= iconSize + 8 + lineH) ...[
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: style,
              ),
            ],
          ],
        );
      },
    );
  }
}
