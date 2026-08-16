import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import 'chat_export.dart';
import 'chat_import.dart';
import 'chat_screen.dart';

/// The full list of recent conversations. Reached from the drawer's "Chats"
/// destination; a single conversation opens on top as a detail screen, so the
/// back button returns here — the standard Android hub-and-detail flow.
///
/// When [characterId] is set the list is scoped to that character's chats (the
/// "Chat List" action on a character), and the drawer is dropped for a back
/// arrow so it reads as a detail view.
class ChatsScreen extends StatelessWidget {
  const ChatsScreen({super.key, this.characterId, this.characterName});

  /// When non-null, only conversations bound to this character are shown.
  final String? characterId;
  final String? characterName;

  void _openChat(BuildContext context, AppState state, String id) {
    state.selectConversation(id);
    _pushChat(context);
  }

  void _newChat(BuildContext context, AppState state) {
    state.newConversation();
    _pushChat(context);
  }

  void _pushChat(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final filtered = characterId == null;
    // Brand-new, never-sent threads have nothing to show, so they stay out of
    // the list until they hold a message.
    final chats = state.conversations
        .where((c) => !c.isEmpty)
        .where((c) => filtered ? true : c.characterId == characterId)
        .toList();
    final bottom = MediaQuery.paddingOf(context).bottom;
    final title = filtered ? 'Chats' : '${characterName ?? 'Character'} chats';

    return Scaffold(
      drawer: filtered ? const AppDrawer(selected: DrawerSection.chats) : null,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newChat(context, state),
        icon: const Icon(Icons.add),
        label: const Text('New chat'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Row(
              children: [
                Expanded(
                  child: Text(title, overflow: TextOverflow.ellipsis),
                ),
                _HeadlineAction(
                  tooltip: 'Import chat',
                  icon: Icons.upload_file_outlined,
                  onPressed: () => importChats(
                    context,
                    preselectCharacterId: characterId,
                  ),
                ),
              ],
            ),
          ),
          if (chats.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyChats(),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 4, 12, 96 + bottom),
              sliver: SliverList.builder(
                itemCount: chats.length,
                itemBuilder: (context, index) => ChatCard(
                  conversation: chats[index],
                  onTap: () => _openChat(context, state, chats[index].id),
                  onDelete: () => _confirmDelete(context, state, chats[index]),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppState state,
    Conversation c,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text('"${c.title}" will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await state.deleteConversation(c.id);
  }
}
// APPEND-MARKER

/// A button parked at the far end of a large app bar's headline — beside the
/// title, not in the corner above it.
///
/// [SliverAppBar.large] renders its title widget twice: once as the big headline
/// under the toolbar, and once inside the toolbar itself, faded in as you scroll.
/// A trailing button would therefore also sit in the top-right corner — and stay
/// tappable there while invisible, which is worse than merely looking wrong. Only
/// the headline copy lives outside the toolbar's [NavigationToolbar], so that is
/// how the two are told apart.
class _HeadlineAction extends StatelessWidget {
  const _HeadlineAction({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final inToolbar =
        context.findAncestorWidgetOfExactType<NavigationToolbar>() != null;
    if (inToolbar) return const SizedBox.shrink();
    return IconButton(
      tooltip: tooltip,
      icon: Icon(icon),
      onPressed: onPressed,
    );
  }
}

/// One conversation in the recent list: title, a preview of the last turn, how
/// long ago it was touched, and an overflow menu to export or delete it. Shared
/// by the Chats list and the Home dashboard preview.
class ChatCard extends StatelessWidget {
  const ChatCard({
    super.key,
    required this.conversation,
    required this.onTap,
    required this.onDelete,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = conversation.messages.isEmpty
        ? 'Empty'
        : conversation.messages.last.content
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            Icons.chat_bubble_outline,
            color: scheme.onSecondaryContainer,
            size: 20,
          ),
        ),
        title: Text(
          conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              preview.isEmpty ? 'Empty' : preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              relativeTime(conversation.updatedAt),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'delete') onDelete();
            if (value == 'export') exportChat(context, conversation);
          },
          itemBuilder: (context) => const [
            PopupMenuItem<String>(
              value: 'export',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.save_alt_outlined),
                title: Text('Export'),
              ),
            ),
            PopupMenuItem<String>(
              value: 'delete',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline),
                title: Text('Delete'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fills the body when there are no chats yet.
class _EmptyChats extends StatelessWidget {
  const _EmptyChats();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No chats yet', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Tap New chat to start your first conversation.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact "time since" label: minutes, hours, days, weeks, then years.
String relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (diff.inDays < 365) return '${diff.inDays ~/ 7}w ago';
  return '${diff.inDays ~/ 365}y ago';
}
