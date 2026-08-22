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
class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key, this.characterId, this.characterName});

  /// When non-null, only conversations bound to this character are shown.
  final String? characterId;
  final String? characterName;

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

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

  /// Whether [c] answers the current query. A chat is looked for by what was
  /// said in it as much as by what it is called, so the turns are searched too —
  /// stopping at the first hit.
  bool _matches(Conversation c, String query) {
    if (query.isEmpty) return true;
    if (c.title.toLowerCase().contains(query)) return true;
    if ((c.characterName ?? '').toLowerCase().contains(query)) return true;
    return c.messages.any((m) => m.content.toLowerCase().contains(query));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final filtered = widget.characterId == null;
    final query = _query.trim().toLowerCase();
    // Brand-new, never-sent threads have nothing to show, so they stay out of
    // the list until they hold a message.
    final all = state.conversations
        .where((c) => !c.isEmpty)
        .where((c) => filtered ? true : c.characterId == widget.characterId)
        .toList();
    final chats = all.where((c) => _matches(c, query)).toList();
    final bottom = MediaQuery.paddingOf(context).bottom;
    final title =
        filtered ? 'Chats' : '${widget.characterName ?? 'Character'} chats';

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
                    preselectCharacterId: widget.characterId,
                  ),
                ),
              ],
            ),
          ),
          // The search bar rides at the top of the scroll view rather than being
          // pinned, matching the Characters section.
          if (all.isNotEmpty) SliverToBoxAdapter(child: _searchBar()),
          if (all.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyChats(),
            )
          else if (chats.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _NoChatMatches(),
            )
          else ...[
            for (final sliver in _chatSlivers(context, state, chats, bottom))
              sliver,
          ],
        ],
      ),
    );
  }

  /// Builds the chat list slivers, grouping pinned chats into their own section
  /// at the top when there are any.
  List<Widget> _chatSlivers(BuildContext context, AppState state,
      List<Conversation> chats, double bottom) {
    final pinned = chats.where((c) => c.pinned).toList();
    final others = chats.where((c) => !c.pinned).toList();

    Widget card(Conversation c) => ChatCard(
          conversation: c,
          onTap: () => _openChat(context, state, c.id),
          onDelete: () => _confirmDelete(context, state, c),
          onTogglePin: () => state.togglePinned(c.id),
        );

    if (pinned.isEmpty) {
      return [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 96 + bottom),
          sliver: SliverList.builder(
            itemCount: others.length,
            itemBuilder: (context, i) => card(others[i]),
          ),
        ),
      ];
    }
    return [
      _sectionHeader(context, 'Pinned'),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        sliver: SliverList.builder(
          itemCount: pinned.length,
          itemBuilder: (context, i) => card(pinned[i]),
        ),
      ),
      _sectionHeader(context, 'All chats'),
      SliverPadding(
        padding: EdgeInsets.fromLTRB(12, 0, 12, 96 + bottom),
        sliver: SliverList.builder(
          itemCount: others.length,
          itemBuilder: (context, i) => card(others[i]),
        ),
      ),
    ];
  }

  Widget _sectionHeader(BuildContext context, String label) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      );

  Widget _searchBar() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
        child: SearchBar(
          controller: _search,
          hintText: 'Search chats',
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14),
          ),
          leading: const Icon(Icons.search),
          trailing: [
            if (_query.isNotEmpty)
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
          ],
          onChanged: (v) => setState(() => _query = v),
        ),
      );

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

/// Shown when a search matches no chat.
class _NoChatMatches extends StatelessWidget {
  const _NoChatMatches();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text(
              'No chats match your search.',
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
    this.onTogglePin,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// Pins/unpins the chat; when null the pin action is hidden.
  final VoidCallback? onTogglePin;

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
        title: Row(
          children: [
            if (conversation.pinned)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Icon(Icons.push_pin, size: 14, color: scheme.primary),
              ),
            Expanded(
              child: Text(
                conversation.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
            if (value == 'pin') onTogglePin?.call();
          },
          itemBuilder: (context) => [
            if (onTogglePin != null)
              PopupMenuItem<String>(
                value: 'pin',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(conversation.pinned
                      ? Icons.push_pin
                      : Icons.push_pin_outlined),
                  title: Text(conversation.pinned ? 'Unpin' : 'Pin'),
                ),
              ),
            const PopupMenuItem<String>(
              value: 'export',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.save_alt_outlined),
                title: Text('Export'),
              ),
            ),
            const PopupMenuItem<String>(
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
