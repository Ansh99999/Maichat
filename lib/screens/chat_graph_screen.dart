import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/chat_graph.dart';
import '../state/app_state.dart';
import 'chats_screen.dart' show relativeTime;

/// The **Chat Graph**: one chat and every branch taken off it, as a tree.
///
/// Lineage comes from `Conversation.parentId`/`forkIndex`, recorded when a
/// branch is made, so the graph is a view over the normal chat store rather than
/// a structure of its own. The chat currently being read is marked; tapping any
/// node switches to that branch, and each row's menu can rename it, branch off
/// it, or delete it.
///
/// This is also where branches *live*: the chat lists collapse a whole tree into
/// a single row (see `collapseForks`), so the graph is the only place the
/// individual branches are listed.
class ChatGraphScreen extends StatelessWidget {
  const ChatGraphScreen({super.key, required this.conversationId});

  /// The chat whose family tree is shown. The tree is rooted at this chat's top
  /// ancestor, so opening the graph from a fork shows the whole family.
  final String conversationId;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    // Deleting a row can remove the chat the screen was opened with; fall back
    // to whatever is active so the graph keeps showing a tree instead of an
    // error.
    final anchor = state.conversationById(conversationId) == null
        ? state.active.id
        : conversationId;
    final root = buildFamilyTree(state.conversations, anchor);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat Graph'),
      ),
      body: root == null
          ? const _GraphEmpty(
              message: 'This chat is no longer available.',
            )
          // The marked row follows the *active* chat, not the id the screen was
          // opened with, so branching from the graph moves the marker onto the
          // new branch straight away.
          : _GraphBody(root: root, currentId: state.active.id),
    );
  }
}

/// The tree itself: a header strip summarising the family, then one row per
/// conversation with connector rails on the left.
class _GraphBody extends StatelessWidget {
  const _GraphBody({required this.root, required this.currentId});

  final ChatGraphNode root;
  final String currentId;

  @override
  Widget build(BuildContext context) {
    final rows = flattenGraph(root);
    final scheme = Theme.of(context).colorScheme;
    final total = rows.length;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
      itemCount: rows.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
            child: Text(
              total == 1
                  ? 'No branches yet — use Branch on a message to take the '
                      'chat a different way.'
                  : '$total chats in this tree',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          );
        }
        final row = rows[index - 1];
        return _GraphRow(
          row: row,
          isCurrent: row.node.conversation.id == currentId,
          parentTitle: _parentTitleOf(rows, row),
        );
      },
    );
  }

  /// The title of [row]'s parent, for the fork-point line. Found by walking back
  /// to the nearest preceding row one level up — the flattening is depth-first,
  /// so that row is always the parent.
  static String? _parentTitleOf(List<ChatGraphRow> rows, ChatGraphRow row) {
    if (row.node.depth == 0) return null;
    final at = rows.indexOf(row);
    for (var i = at - 1; i >= 0; i--) {
      if (rows[i].node.depth == row.node.depth - 1) {
        return rows[i].node.conversation.title;
      }
    }
    return null;
  }
}

/// Width of one indent level — the horizontal space a rail column occupies.
const double _kRail = 22;

/// One conversation in the tree: connector rails, then a card.
class _GraphRow extends StatelessWidget {
  const _GraphRow({
    required this.row,
    required this.isCurrent,
    required this.parentTitle,
  });

  final ChatGraphRow row;
  final bool isCurrent;
  final String? parentTitle;

  @override
  Widget build(BuildContext context) {
    final node = row.node;
    // The rails must run the full height of the card beside them, which is only
    // known once the card has been laid out — hence IntrinsicHeight, which lets
    // the stretched connector take its height from the card rather than from an
    // unbounded list constraint.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (node.depth > 0)
            _Connector(
              railsContinue: row.ancestorHasNext,
              isLast: row.isLast,
            ),
          Expanded(
            child: _GraphCard(
              node: node,
              isCurrent: isCurrent,
              parentTitle: parentTitle,
            ),
          ),
        ],
      ),
    );
  }
}

/// The ├─ / └─ elbow for a row plus the vertical rails of its ancestors,
/// painted rather than assembled from glyphs so the lines meet exactly.
class _Connector extends StatelessWidget {
  const _Connector({required this.railsContinue, required this.isLast});

  /// One flag per ancestor rail column: whether that ancestor continues below.
  final List<bool> railsContinue;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: _kRail * (railsContinue.length + 1),
      child: CustomPaint(
        painter: _ConnectorPainter(
          railsContinue: railsContinue,
          isLast: isLast,
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
      ),
    );
  }
}

class _ConnectorPainter extends CustomPainter {
  _ConnectorPainter({
    required this.railsContinue,
    required this.isLast,
    required this.color,
  });

  final List<bool> railsContinue;
  final bool isLast;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    // Where the elbow turns: vertically centred on the card, which sits in a
    // row of this exact height.
    final elbowY = size.height / 2;
    for (var i = 0; i < railsContinue.length; i++) {
      if (!railsContinue[i]) continue;
      final x = _kRail * i + _kRail / 2;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    final x = _kRail * railsContinue.length + _kRail / 2;
    // The elbow's own vertical: down to the turn for the last sibling, all the
    // way through for one with siblings below it.
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, isLast ? elbowY : size.height),
      paint,
    );
    canvas.drawLine(Offset(x, elbowY), Offset(size.width, elbowY), paint);
  }

  @override
  bool shouldRepaint(_ConnectorPainter old) =>
      old.isLast != isLast ||
      old.color != color ||
      !_sameFlags(old.railsContinue, railsContinue);

  static bool _sameFlags(List<bool> a, List<bool> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// A single conversation in the tree, as a tappable card. The chat the graph
/// was opened from wears the primary outline and a "Current" chip; a branch
/// shows where it split from its parent.
class _GraphCard extends StatelessWidget {
  const _GraphCard({
    required this.node,
    required this.isCurrent,
    required this.parentTitle,
  });

  final ChatGraphNode node;
  final bool isCurrent;
  final String? parentTitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final c = node.conversation;
    final turns = c.messages.length;
    final branches = node.children.length;

    final meta = <String>[
      '$turns ${turns == 1 ? 'message' : 'messages'}',
      relativeTime(c.updatedAt),
      if (branches > 0) '$branches ${branches == 1 ? 'branch' : 'branches'}',
    ].join(' · ');

    return Card(
      elevation: 0,
      color: isCurrent ? scheme.secondaryContainer : scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 4),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isCurrent
            ? BorderSide(color: scheme.primary, width: 1.5)
            : BorderSide(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: InkWell(
        onTap: () => _open(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(
            children: [
              Icon(
                node.depth == 0
                    ? Icons.forum_outlined
                    : Icons.call_split_outlined,
                size: 18,
                color: isCurrent
                    ? scheme.onSecondaryContainer
                    : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            c.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleSmall?.copyWith(
                              fontWeight:
                                  isCurrent ? FontWeight.w700 : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (isCurrent)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: _Chip(label: 'Current'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      meta,
                      style: text.labelSmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                    if (node.forkIndex != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        _forkLabel(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              _RowMenu(node: node, isCurrent: isCurrent),
            ],
          ),
        ),
      ),
    );
  }

  /// "Split at message 7 of `<parent>`" plus a snippet of the turn it split on,
  /// so a row says *where* the branch left rather than only that it did.
  String _forkLabel() {
    final at = node.forkIndex! + 1;
    final where = parentTitle == null ? '' : ' of $parentTitle';
    final snippet = _splitSnippet();
    final head = 'Split at message $at$where';
    return snippet.isEmpty ? head : '$head — "$snippet"';
  }

  /// The text of the turn the branch was taken at, as held by *this* chat (a
  /// fork copies its parent's turns, so the last one is the split point).
  String _splitSnippet() {
    final index = node.forkIndex!;
    final messages = node.conversation.messages;
    if (index < 0 || index >= messages.length) return '';
    final flat =
        messages[index].content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.length <= 60) return flat;
    return '${flat.substring(0, 60)}…';
  }

  void _open(BuildContext context) {
    final state = context.read<AppState>();
    state.selectConversation(node.conversation.id);
    // The graph is opened from inside a chat, so popping back lands on the chat
    // screen — which now renders the branch that was just selected.
    Navigator.of(context).pop();
  }
}

/// The small "Current" pill.
class _Chip extends StatelessWidget {
  const _Chip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: scheme.onPrimary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// Per-row actions: open, rename, branch from the end, delete.
class _RowMenu extends StatelessWidget {
  const _RowMenu({required this.node, required this.isCurrent});

  final ChatGraphNode node;

  /// Whether this row is the chat the graph was opened from — deleting it
  /// leaves nothing to show, so the screen closes rather than sitting empty.
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final c = node.conversation;
    return PopupMenuButton<String>(
      tooltip: 'More',
      icon: const Icon(Icons.more_vert, size: 20),
      onSelected: (value) async {
        final state = context.read<AppState>();
        switch (value) {
          case 'open':
            state.selectConversation(c.id);
            Navigator.of(context).pop();
          case 'rename':
            await _rename(context, state);
          case 'branch':
            await _branch(context, state);
          case 'delete':
            await _delete(context, state);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem<String>(
          value: 'open',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.open_in_new),
            title: Text('Open'),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'rename',
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.edit_outlined),
            title: Text('Rename'),
          ),
        ),
        PopupMenuItem<String>(
          value: 'branch',
          enabled: c.messages.isNotEmpty,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.call_split),
            title: Text('Branch from end'),
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
    );
  }

  Future<void> _rename(BuildContext context, AppState state) async {
    final controller = TextEditingController(text: node.conversation.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Rename chat'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: 'Title'),
          onSubmitted: (value) => Navigator.of(dialog).pop(value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null) return;
    await state.renameConversation(node.conversation.id, title);
  }

  /// Copies the whole branch into a new child of it — "carry on from here in a
  /// separate thread", the graph's own way to grow the tree.
  Future<void> _branch(BuildContext context, AppState state) async {
    final c = node.conversation;
    if (c.messages.isEmpty) return;
    final id = await state.forkConversation(c.id, c.messages.length - 1);
    if (id.isEmpty || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Branched into a new chat')),
    );
  }

  Future<void> _delete(BuildContext context, AppState state) async {
    final branches = node.children.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text(
          branches == 0
              ? 'This deletes "${node.conversation.title}" and its messages.'
              : branches == 1
                  ? 'This deletes "${node.conversation.title}" and its '
                      'messages. Its 1 branch is kept and becomes a root of '
                      'its own.'
                  : 'This deletes "${node.conversation.title}" and its '
                      'messages. Its $branches branches are kept and become '
                      'roots of their own.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await state.deleteConversation(node.conversation.id);
    // Deleting the chat the graph belongs to leaves nothing to look at: close
    // the screen so the chat behind it re-resolves to whatever is active now.
    if (isCurrent && context.mounted) Navigator.of(context).pop();
  }
}

/// Placeholder for the cases with nothing to draw.
class _GraphEmpty extends StatelessWidget {
  const _GraphEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.account_tree_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
