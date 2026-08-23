import '../models/conversation.dart';

/// One conversation in the fork tree drawn by the Chat Graph.
///
/// A node's [children] are the threads forked *from* it, in split order.
/// [forkIndex] is the message index in the parent where this branch split off
/// (null for a root — a chat that was started fresh or imported, or one whose
/// recorded parent no longer exists). [depth] is 0 for the root of the tree the
/// caller asked about and grows by one per generation.
class ChatGraphNode {
  ChatGraphNode({
    required this.conversation,
    required this.forkIndex,
    required this.depth,
    required this.children,
  });

  final Conversation conversation;
  final int? forkIndex;
  final int depth;
  final List<ChatGraphNode> children;

  bool get hasChildren => children.isNotEmpty;

  /// This node plus every descendant, depth-first (self first).
  int get subtreeSize {
    var total = 1;
    for (final child in children) {
      total += child.subtreeSize;
    }
    return total;
  }
}

/// Whether [conversation]'s recorded parent still exists in [byId] and is not
/// itself — the guard that turns an orphaned fork (parent deleted) into a root.
bool _hasLiveParent(Conversation conversation, Map<String, Conversation> byId) {
  final parent = conversation.parentId;
  return parent != null && parent != conversation.id && byId.containsKey(parent);
}

/// Walks up the parent links from [id] to the top ancestor that still exists,
/// returning its id. Missing parents stop the walk (the child is a root); a
/// cycle is broken by the visited set. Returns [id] unchanged when it names no
/// known conversation.
String rootIdOf(Iterable<Conversation> conversations, String id) {
  final byId = {for (final c in conversations) c.id: c};
  var current = byId[id];
  if (current == null) return id;
  final seen = <String>{};
  while (_hasLiveParent(current!, byId) && seen.add(current.id)) {
    current = byId[current.parentId]!;
  }
  return current.id;
}

/// Builds the fork tree that [id] belongs to, rooted at its top ancestor.
///
/// Every conversation whose (live) parent is that root, directly or
/// transitively, becomes a node; orphans of other trees are excluded. Children
/// are ordered by fork point ([forkIndex] ascending, unknowns last) then by
/// most-recently-updated. Returns null when [id] names no conversation.
ChatGraphNode? buildFamilyTree(Iterable<Conversation> conversations, String id) {
  final list = conversations.toList();
  final byId = {for (final c in list) c.id: c};
  if (!byId.containsKey(id)) return null;

  // Group each conversation under its effective parent id (null = a root).
  final childrenOf = <String?, List<Conversation>>{};
  for (final c in list) {
    final parent = _hasLiveParent(c, byId) ? c.parentId : null;
    (childrenOf[parent] ??= <Conversation>[]).add(c);
  }

  final rootId = rootIdOf(list, id);

  int rank(Conversation c) => c.forkIndex ?? (1 << 30);
  // A conversation has exactly one parent, so the links form a tree — except
  // for a cycle, which a shared visited set breaks by refusing to place any
  // chat twice.
  final seen = <String>{};
  ChatGraphNode build(Conversation c, int depth) {
    seen.add(c.id);
    final kids = (childrenOf[c.id] ?? const <Conversation>[])
        .where((k) => !seen.contains(k.id))
        .toList();
    kids.sort((a, b) {
      final byFork = rank(a).compareTo(rank(b));
      if (byFork != 0) return byFork;
      return b.updatedAt.compareTo(a.updatedAt);
    });
    // Claim every child before descending, so two siblings can't both pull in
    // the same descendant through a cycle.
    for (final k in kids) {
      seen.add(k.id);
    }
    return ChatGraphNode(
      conversation: c,
      forkIndex: _hasLiveParent(c, byId) ? c.forkIndex : null,
      depth: depth,
      children: [for (final k in kids) build(k, depth + 1)],
    );
  }

  return build(byId[rootId]!, 0);
}

/// One fork tree, collapsed to a single entry for the chat lists.
///
/// A tree is presented as one row: it is named after its [root] (the chat the
/// family grew out of), but its recency and preview come from [latest] — the
/// most recently touched chat in the tree — so a tree stays where the reader
/// expects in a newest-first list no matter which branch they were last in.
class ChatTreeEntry {
  ChatTreeEntry({
    required this.root,
    required this.latest,
    required this.members,
  });

  final Conversation root;

  /// The most recently updated chat in the tree (the root itself when it has no
  /// branches, or when the root is the freshest).
  final Conversation latest;

  /// Every chat in the tree, root first, then the rest newest-first.
  final List<Conversation> members;

  /// How many chats besides the root — the "N branches" count.
  int get branchCount => members.length - 1;

  bool get hasBranches => branchCount > 0;

  /// Whether the tree sits in the "Pinned" section. Any member being pinned
  /// counts, so a chat pinned before it grew branches — or a branch pinned on
  /// its own — never disappears from the section it was put in.
  bool get pinned => members.any((c) => c.pinned);
}

/// Collapses [conversations] into one entry per fork tree, keeping the order of
/// the input (the caller has already sorted it) by the position of each tree's
/// **first** member — so a tree sits where its most recent chat would have.
///
/// Grouping only ever looks inside the given list: a chat whose parent was
/// filtered out (or deleted) is a root of its own, which keeps a scoped list
/// (one character's chats, a search result) honest instead of hiding rows under
/// a parent that isn't there.
List<ChatTreeEntry> collapseForks(Iterable<Conversation> conversations) {
  final list = conversations.toList();
  final byId = {for (final c in list) c.id: c};

  /// The top ancestor of [c] within this list.
  Conversation rootWithin(Conversation c) {
    var current = c;
    final seen = <String>{};
    while (_hasLiveParent(current, byId) && seen.add(current.id)) {
      current = byId[current.parentId]!;
    }
    return current;
  }

  final grouped = <String, List<Conversation>>{};
  final order = <String>[];
  for (final c in list) {
    final rootId = rootWithin(c).id;
    if (grouped[rootId] == null) {
      grouped[rootId] = <Conversation>[];
      order.add(rootId);
    }
    grouped[rootId]!.add(c);
  }

  return [
    for (final rootId in order)
      () {
        final members = grouped[rootId]!;
        final root = byId[rootId]!;
        // Root first, then the branches newest-first — the order the graph and
        // any "which branch?" list should read in.
        final rest = members.where((c) => c.id != rootId).toList()
          ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
        var latest = root;
        for (final c in members) {
          if (c.updatedAt.isAfter(latest.updatedAt)) latest = c;
        }
        return ChatTreeEntry(
          root: root,
          latest: latest,
          members: <Conversation>[root, ...rest],
        );
      }(),
  ];
}

/// A flattened tree row plus the guides needed to draw connector rails.
///
/// [ancestorHasNext] holds one flag per vertical rail column drawn to the left
/// of this row's elbow — its length equals `node.depth - 1` (empty for the root
/// and for direct children of the root). Each flag says whether that ancestor
/// has a further sibling below, i.e. whether its vertical line continues past
/// this row. [isLast] says whether this node is the last of its own siblings,
/// which picks └ over ├ for its own elbow.
class ChatGraphRow {
  ChatGraphRow({
    required this.node,
    required this.isLast,
    required this.ancestorHasNext,
  });

  final ChatGraphNode node;
  final bool isLast;
  final List<bool> ancestorHasNext;
}

/// Depth-first flattening of [root] into render rows.
List<ChatGraphRow> flattenGraph(ChatGraphNode root) {
  final rows = <ChatGraphRow>[];
  void walk(ChatGraphNode node, bool isLast, List<bool> rails) {
    rows.add(ChatGraphRow(
      node: node,
      isLast: isLast,
      ancestorHasNext: List<bool>.unmodifiable(rails),
    ));
    // The root contributes no vertical rail, so its children start with none;
    // every deeper node extends its parent's rails with "does this node
    // continue below" (true unless it is the last sibling).
    final childRails = node.depth == 0 ? const <bool>[] : [...rails, !isLast];
    for (var i = 0; i < node.children.length; i++) {
      walk(node.children[i], i == node.children.length - 1, childRails);
    }
  }

  walk(root, true, const <bool>[]);
  return rows;
}

