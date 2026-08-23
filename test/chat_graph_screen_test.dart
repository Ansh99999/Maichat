import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chat_graph_screen.dart';
import 'package:maichat/screens/chats_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Boots a real [AppState] over an empty prefs store, seeded with [chats].
Future<AppState> _state(List<Conversation> chats) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState();
  await state.init();
  // init() materialises one empty thread; replace the store with the fixture so
  // the list is exactly what each case describes.
  await state.importConversations(chats);
  return state;
}

Conversation _chat(
  String id, {
  required String title,
  String? parentId,
  int? forkIndex,
  int turns = 2,
  int minutesAgo = 0,
}) =>
    Conversation(
      id: id,
      title: title,
      messages: [
        for (var i = 0; i < turns; i++)
          ChatMessage(
            role: i.isEven ? 'user' : 'assistant',
            content: 'turn $i of $title',
          ),
      ],
      updatedAt: DateTime.now().subtract(Duration(minutes: minutesAgo)),
      parentId: parentId,
      forkIndex: forkIndex,
    );

Widget _host(AppState state, Widget child) => ChangeNotifierProvider<AppState>.value(
      value: state,
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('a lone chat shows the no-branches hint', (tester) async {
    final state = await _state([_chat('a', title: 'Solo chat')]);
    await tester.pumpWidget(
      _host(state, const ChatGraphScreen(conversationId: 'a')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Chat Graph'), findsOneWidget);
    expect(find.text('Solo chat'), findsOneWidget);
    expect(find.textContaining('No branches yet'), findsOneWidget);
  });

  testWidgets('a family draws every branch with its split point',
      (tester) async {
    final state = await _state([
      _chat('root', title: 'Tavern', turns: 6, minutesAgo: 90),
      _chat('b1', title: 'She refuses', parentId: 'root', forkIndex: 3),
      _chat('b2', title: 'He leaves', parentId: 'root', forkIndex: 1),
      _chat('b1a', title: 'They fight', parentId: 'b1', forkIndex: 2),
    ]);
    await tester.pumpWidget(
      _host(state, const ChatGraphScreen(conversationId: 'b1a')),
    );
    await tester.pumpAndSettle();

    // Opened on a leaf, but the whole family is drawn.
    expect(find.text('Tavern'), findsOneWidget);
    expect(find.text('She refuses'), findsOneWidget);
    expect(find.text('He leaves'), findsOneWidget);
    expect(find.text('They fight'), findsOneWidget);
    expect(find.text('4 chats in this tree'), findsOneWidget);

    // Each branch says where it split, naming its own parent.
    expect(
      find.textContaining('Split at message 4 of Tavern'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Split at message 2 of Tavern'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Split at message 3 of She refuses'),
      findsOneWidget,
    );
    // Three branches, three split lines — the root has none.
    expect(find.textContaining('Split at message'), findsNWidgets(3));
  });

  testWidgets('the current chat is marked, and tapping a branch selects it',
      (tester) async {
    final state = await _state([
      _chat('root', title: 'Root chat', minutesAgo: 60),
      _chat('b1', title: 'Branch one', parentId: 'root', forkIndex: 0),
    ]);
    state.selectConversation('root');
    await tester.pumpWidget(
      _host(state, const ChatGraphScreen(conversationId: 'root')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Current'), findsOneWidget);
    expect(state.active.id, 'root');

    await tester.tap(find.text('Branch one'));
    await tester.pumpAndSettle();
    // Selecting a branch switches the active chat (and pops back to it).
    expect(state.active.id, 'b1');
  });

  testWidgets('branch from end grows the tree under the row', (tester) async {
    final state = await _state([_chat('root', title: 'Root chat', turns: 4)]);
    await tester.pumpWidget(
      _host(state, const ChatGraphScreen(conversationId: 'root')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Branch from end'));
    await tester.pumpAndSettle();

    final fork = state.conversations.firstWhere((c) => c.parentId == 'root');
    expect(fork.forkIndex, 3);
    // The graph now shows both, and the new branch is the current one.
    expect(find.text('2 chats in this tree'), findsOneWidget);
    expect(state.active.id, fork.id);
  });

  testWidgets('deleting a branch keeps its children as roots', (tester) async {
    final state = await _state([
      _chat('root', title: 'Root chat'),
      _chat('mid', title: 'Middle', parentId: 'root', forkIndex: 1),
      _chat('leaf', title: 'Leaf', parentId: 'mid', forkIndex: 1),
    ]);
    state.selectConversation('root');
    await tester.pumpWidget(
      _host(state, const ChatGraphScreen(conversationId: 'root')),
    );
    await tester.pumpAndSettle();

    // The middle row's menu is the second one down.
    await tester.tap(find.byIcon(Icons.more_vert).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    // The dialog warns that the branch's own branches survive.
    expect(
      find.textContaining('Its 1 branch is kept and becomes a root of its own'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(state.conversationById('mid'), isNull);
    expect(state.conversationById('leaf'), isNotNull);
    // The orphan is no longer in this tree, so the graph is back to one row.
    expect(find.text('Middle'), findsNothing);
    expect(find.text('Leaf'), findsNothing);
    expect(find.textContaining('No branches yet'), findsOneWidget);
  });

  testWidgets('the chats list collapses a family into one row', (tester) async {
    final state = await _state([
      _chat('root', title: 'Tavern', minutesAgo: 120),
      _chat('b1', title: 'She refuses', parentId: 'root', forkIndex: 1,
          minutesAgo: 5),
      _chat('other', title: 'Shopping trip', minutesAgo: 60),
    ]);
    await tester.pumpWidget(_host(state, const ChatsScreen()));
    await tester.pumpAndSettle();

    // One row per tree: the root's title, not the branch's.
    expect(find.text('Tavern'), findsOneWidget);
    expect(find.text('She refuses'), findsNothing);
    expect(find.text('Shopping trip'), findsOneWidget);
    // The row previews the branch it was last left in.
    expect(find.textContaining('turn 1 of She refuses'), findsOneWidget);
    expect(find.textContaining('in "She refuses"'), findsOneWidget);
  });

  testWidgets('pinning a row pins the whole tree', (tester) async {
    final state = await _state([
      _chat('root', title: 'Tavern', minutesAgo: 120),
      _chat('b1', title: 'Branch one', parentId: 'root', forkIndex: 1,
          minutesAgo: 5),
    ]);
    await tester.pumpWidget(_host(state, const ChatsScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin'));
    await tester.pumpAndSettle();

    // Every member is pinned, so the tree cannot half-leave the section.
    expect(state.conversationById('root')!.pinned, isTrue);
    expect(state.conversationById('b1')!.pinned, isTrue);
    expect(find.text('Pinned'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin'));
    await tester.pumpAndSettle();
    expect(state.conversationById('root')!.pinned, isFalse);
    expect(state.conversationById('b1')!.pinned, isFalse);
  });
}
