import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/chat_graph.dart';

/// A chat with [n] turns, optional lineage, and an explicit timestamp so
/// ordering assertions are not at the mercy of the clock.
Conversation chat(
  String id, {
  String? title,
  String? parentId,
  int? forkIndex,
  int messages = 1,
  int minutesAgo = 0,
  bool pinned = false,
}) =>
    Conversation(
      id: id,
      title: title ?? id,
      messages: [
        for (var i = 0; i < messages; i++)
          ChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'm$i'),
      ],
      updatedAt: DateTime(2026, 1, 1, 12).subtract(Duration(minutes: minutesAgo)),
      parentId: parentId,
      forkIndex: forkIndex,
      pinned: pinned,
    );

void main() {
  group('buildFamilyTree', () {
    test('a lone chat is a single root node', () {
      final tree = buildFamilyTree([chat('a')], 'a')!;
      expect(tree.conversation.id, 'a');
      expect(tree.depth, 0);
      expect(tree.forkIndex, isNull);
      expect(tree.children, isEmpty);
      expect(tree.subtreeSize, 1);
    });

    test('returns null for an unknown id', () {
      expect(buildFamilyTree([chat('a')], 'nope'), isNull);
    });

    test('a fork becomes a child carrying its split point', () {
      final chats = [chat('a'), chat('b', parentId: 'a', forkIndex: 3)];
      final tree = buildFamilyTree(chats, 'a')!;
      expect(tree.children, hasLength(1));
      expect(tree.children.single.conversation.id, 'b');
      expect(tree.children.single.forkIndex, 3);
      expect(tree.children.single.depth, 1);
    });

    test('opening the graph on a fork still roots at the top ancestor', () {
      final chats = [
        chat('a'),
        chat('b', parentId: 'a', forkIndex: 1),
        chat('c', parentId: 'b', forkIndex: 2),
      ];
      final tree = buildFamilyTree(chats, 'c')!;
      expect(tree.conversation.id, 'a');
      expect(tree.subtreeSize, 3);
      expect(tree.children.single.children.single.conversation.id, 'c');
      expect(tree.children.single.children.single.depth, 2);
    });

    test('siblings order by fork point, then most recent', () {
      final chats = [
        chat('a'),
        chat('late', parentId: 'a', forkIndex: 7),
        chat('early', parentId: 'a', forkIndex: 2),
        chat('alsoEarly', parentId: 'a', forkIndex: 2, minutesAgo: 30),
      ];
      final tree = buildFamilyTree(chats, 'a')!;
      expect(
        tree.children.map((n) => n.conversation.id),
        // forkIndex 2 before 7; within 2, the newer one first.
        ['early', 'alsoEarly', 'late'],
      );
    });

    test('a fork whose parent was deleted reads as a root', () {
      final orphan = chat('b', parentId: 'gone', forkIndex: 4);
      final tree = buildFamilyTree([orphan], 'b')!;
      expect(tree.conversation.id, 'b');
      expect(tree.depth, 0);
      // The dangling split point is not reported: there is no parent to have
      // split from.
      expect(tree.forkIndex, isNull);
    });

    test('other families are excluded', () {
      final chats = [
        chat('a'),
        chat('b', parentId: 'a', forkIndex: 1),
        chat('x'),
        chat('y', parentId: 'x', forkIndex: 1),
      ];
      final tree = buildFamilyTree(chats, 'a')!;
      expect(tree.subtreeSize, 2);
      expect(tree.children.map((n) => n.conversation.id), ['b']);
    });

    test('a parent cycle terminates instead of recursing forever', () {
      final chats = [
        chat('a', parentId: 'b', forkIndex: 1),
        chat('b', parentId: 'a', forkIndex: 1),
      ];
      final tree = buildFamilyTree(chats, 'a');
      expect(tree, isNotNull);
      expect(tree!.subtreeSize, lessThanOrEqualTo(2));
    });

    test('a chat naming itself as parent is a root', () {
      final tree = buildFamilyTree([chat('a', parentId: 'a')], 'a')!;
      expect(tree.conversation.id, 'a');
      expect(tree.children, isEmpty);
    });
  });

  group('rootIdOf', () {
    test('walks up to the top ancestor', () {
      final chats = [
        chat('a'),
        chat('b', parentId: 'a'),
        chat('c', parentId: 'b'),
      ];
      expect(rootIdOf(chats, 'c'), 'a');
      expect(rootIdOf(chats, 'a'), 'a');
    });

    test('an unknown id is its own root', () {
      expect(rootIdOf([chat('a')], 'zzz'), 'zzz');
    });
  });

  group('flattenGraph', () {
    test('depth-first order with the root first', () {
      final chats = [
        chat('a'),
        chat('b', parentId: 'a', forkIndex: 1),
        chat('b1', parentId: 'b', forkIndex: 1),
        chat('c', parentId: 'a', forkIndex: 5),
      ];
      final rows = flattenGraph(buildFamilyTree(chats, 'a')!);
      expect(rows.map((r) => r.node.conversation.id), ['a', 'b', 'b1', 'c']);
      expect(rows.map((r) => r.node.depth), [0, 1, 2, 1]);
    });

    test('isLast marks the final sibling only', () {
      final chats = [
        chat('a'),
        chat('b', parentId: 'a', forkIndex: 1),
        chat('c', parentId: 'a', forkIndex: 5),
      ];
      final rows = flattenGraph(buildFamilyTree(chats, 'a')!);
      expect(rows.map((r) => r.isLast), [true, false, true]);
    });

    test('rail flags say which ancestor lines continue past a row', () {
      final chats = [
        chat('a'),
        // 'b' has a sibling below it, so its rail continues past its child.
        chat('b', parentId: 'a', forkIndex: 1),
        chat('b1', parentId: 'b', forkIndex: 1),
        chat('c', parentId: 'a', forkIndex: 5),
        chat('c1', parentId: 'c', forkIndex: 1),
      ];
      final rows = flattenGraph(buildFamilyTree(chats, 'a')!);
      final byId = {for (final r in rows) r.node.conversation.id: r};
      // Root and its direct children draw no ancestor rail.
      expect(byId['a']!.ancestorHasNext, isEmpty);
      expect(byId['b']!.ancestorHasNext, isEmpty);
      expect(byId['c']!.ancestorHasNext, isEmpty);
      // 'b1' sits under 'b', which has 'c' below it: the rail continues.
      expect(byId['b1']!.ancestorHasNext, [true]);
      // 'c1' sits under the last sibling: nothing continues.
      expect(byId['c1']!.ancestorHasNext, [false]);
    });
  });

  group('collapseForks', () {
    test('a chat with no forks is one entry with no branches', () {
      final entries = collapseForks([chat('a')]);
      expect(entries, hasLength(1));
      expect(entries.single.root.id, 'a');
      expect(entries.single.branchCount, 0);
      expect(entries.single.hasBranches, isFalse);
      expect(entries.single.latest.id, 'a');
    });

    test('a family collapses to a single entry named after the root', () {
      final chats = [
        chat('fork', parentId: 'root', forkIndex: 2, minutesAgo: 0),
        chat('root', title: 'Tavern', minutesAgo: 60),
      ];
      final entries = collapseForks(chats);
      expect(entries, hasLength(1));
      expect(entries.single.root.title, 'Tavern');
      expect(entries.single.branchCount, 1);
      // The freshest branch drives the preview and timestamp.
      expect(entries.single.latest.id, 'fork');
      expect(entries.single.members.map((c) => c.id), ['root', 'fork']);
    });

    test('the entry sits where its first-listed member was', () {
      // Input order is the caller's sort (newest first).
      final chats = [
        chat('other', minutesAgo: 10),
        chat('fork', parentId: 'root', forkIndex: 1, minutesAgo: 20),
        chat('root', minutesAgo: 90),
      ];
      final entries = collapseForks(chats);
      expect(entries.map((e) => e.root.id), ['other', 'root']);
    });

    test('a branch whose parent is filtered out stands on its own', () {
      // What a scoped list (a search, one character) does: only the fork is in
      // the input, so it must still show rather than vanish under an absent
      // parent.
      final entries = collapseForks([chat('fork', parentId: 'root', forkIndex: 1)]);
      expect(entries, hasLength(1));
      expect(entries.single.root.id, 'fork');
      expect(entries.single.branchCount, 0);
    });

    test('branches of branches all join the one entry', () {
      final chats = [
        chat('root'),
        chat('b', parentId: 'root', forkIndex: 1),
        chat('c', parentId: 'b', forkIndex: 2),
      ];
      final entries = collapseForks(chats);
      expect(entries, hasLength(1));
      expect(entries.single.branchCount, 2);
      expect(entries.single.members, hasLength(3));
    });

    test('a cycle does not hang the grouping', () {
      final chats = [
        chat('a', parentId: 'b'),
        chat('b', parentId: 'a'),
      ];
      final entries = collapseForks(chats);
      expect(entries, isNotEmpty);
    });

    test('a tree reads as pinned when any member is', () {
      final root = chat('root');
      final branch = chat('b', parentId: 'root', forkIndex: 1, pinned: true);
      final entry = collapseForks([root, branch]).single;
      // The pin was put on a branch, but the row stands for the family.
      expect(entry.pinned, isTrue);
      expect(entry.root.pinned, isFalse);

      final unpinned = collapseForks([chat('x'), chat('y', parentId: 'x')]).single;
      expect(unpinned.pinned, isFalse);
    });
  });
}
