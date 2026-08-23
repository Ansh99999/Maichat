import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../services/chat_graph.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import 'chat_export.dart';
import 'chat_graph_screen.dart';
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
  ///
  /// Each row is a **fork tree**, not a single chat: a chat and everything
  /// forked from it collapse into one entry, reached through the Chat Graph.
  /// Trees are formed after filtering, so a search still shows the branch that
  /// matched rather than hiding it under a parent that didn't.
  List<Widget> _chatSlivers(BuildContext context, AppState state,
      List<Conversation> chats, double bottom) {
    final trees = collapseForks(chats);
    final pinned = trees.where((t) => t.pinned).toList();
    final others = trees.where((t) => !t.pinned).toList();

    Widget card(ChatTreeEntry tree) => ChatCard(
          conversation: tree.root,
          tree: tree,
          // Opening a tree resumes the branch it was left in, which is the chat
          // the preview and timestamp already describe.
          onTap: () => _openChat(context, state, tree.latest.id),
          onDelete: () => _confirmDelete(context, state, tree),
          onTogglePin: () => state.togglePinnedTree(tree.root.id),
          onGraph: () => _openGraph(context, tree.root.id),
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

  void _openGraph(BuildContext context, String id) => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatGraphScreen(conversationId: id),
        ),
      );

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

  /// Deletes a whole fork tree — the row stands for the family, so removing it
  /// removes every branch. The dialog says how many, because a row's title only
  /// names the root.
  Future<void> _confirmDelete(
    BuildContext context,
    AppState state,
    ChatTreeEntry tree,
  ) async {
    final n = tree.members.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(n == 1 ? 'Delete chat?' : 'Delete $n chats?'),
        content: Text(
          n == 1
              ? '"${tree.root.title}" will be removed permanently.'
              : '"${tree.root.title}" and its ${tree.branchCount} '
                  '${tree.branchCount == 1 ? 'branch' : 'branches'} will be '
                  'removed permanently.',
        ),
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
    if (confirmed ?? false) {
      for (final c in tree.members) {
        await state.deleteConversation(c.id);
      }
    }
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

/// One row in the recent list: title, a preview of the last turn, how long ago
/// it was touched, and an overflow menu to export or delete it. Shared by the
/// Chats list and the Home dashboard preview.
///
/// When [tree] is given the row stands for a whole **fork tree** rather than one
/// chat: it is named after the tree's root but previews and dates its most
/// recently touched branch, counts the branches, and offers the Chat Graph. This
/// is what keeps a chat and everything forked from it as a single entry in the
/// lists — the branches are reached through the graph, not by scrolling past
/// near-identical rows.
class ChatCard extends StatelessWidget {
  const ChatCard({
    super.key,
    required this.conversation,
    required this.onTap,
    required this.onDelete,
    this.onTogglePin,
    this.tree,
    this.onGraph,
  });

  /// The chat this row is named after — the tree's root when [tree] is set.
  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  /// Pins/unpins the chat; when null the pin action is hidden.
  final VoidCallback? onTogglePin;

  /// The fork tree this row collapses, when it collapses one.
  final ChatTreeEntry? tree;

  /// Opens the Chat Graph for this tree; when null the action is hidden.
  final VoidCallback? onGraph;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final branches = tree?.branchCount ?? 0;
    // A row stands for the whole tree, so the pin state is the tree's.
    final pinned = tree?.pinned ?? conversation.pinned;
    // A tree row reads off its freshest branch: that is the chat the reader was
    // last in, so its last turn is the useful preview and its timestamp is the
    // one that should place the row in a newest-first list.
    final shown = tree?.latest ?? conversation;
    final preview = shown.messages.isEmpty
        ? 'Empty'
        : shown.messages.last.content
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
            branches > 0 ? Icons.account_tree_outlined : Icons.chat_bubble_outline,
            color: scheme.onSecondaryContainer,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            if (pinned)
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
            if (branches > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _BranchBadge(count: branches),
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
              branches > 0
                  ? '${relativeTime(shown.updatedAt)} · in "${shown.title}"'
                  : relativeTime(shown.updatedAt),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
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
            if (value == 'graph') onGraph?.call();
          },
          itemBuilder: (context) => [
            if (onGraph != null && branches > 0)
              const PopupMenuItem<String>(
                value: 'graph',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.account_tree_outlined),
                  title: Text('Chat Graph'),
                ),
              ),
            if (onTogglePin != null)
              PopupMenuItem<String>(
                value: 'pin',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                      pinned ? Icons.push_pin : Icons.push_pin_outlined),
                  title: Text(pinned ? 'Unpin' : 'Pin'),
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

/// The "N branches" pill on a collapsed fork-tree row.
class _BranchBadge extends StatelessWidget {
  const _BranchBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.call_split, size: 12, color: scheme.onSecondaryContainer),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: scheme.onSecondaryContainer,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
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
