import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/screens/chats_screen.dart';
import 'package:maichat/state/app_state.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The Chats list's search bar. A chat is as often remembered by something said
/// in it as by what it is called, so the turns are searched too.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Conversation thread(String id, String title, List<String> turns) =>
      Conversation(
        id: id,
        title: title,
        updatedAt: DateTime.now(),
        messages: [
          for (final t in turns) ChatMessage(role: 'assistant', content: t),
        ],
      );

  Future<AppState> ready() async {
    final state = AppState();
    await state.init();
    await state.importConversations([
      thread('1', 'Library evening', ['We read until the lamps went out.']),
      thread('2', 'Harbour walk', ['The gulls were loud today.']),
    ]);
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatsScreen()),
      );

  testWidgets('filters by title', (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    expect(find.text('Library evening'), findsOneWidget);
    expect(find.text('Harbour walk'), findsOneWidget);

    await tester.enterText(find.byType(SearchBar), 'harbour');
    await tester.pumpAndSettle();

    expect(find.text('Library evening'), findsNothing);
    expect(find.text('Harbour walk'), findsOneWidget);
  });

  testWidgets('finds a chat by what was said in it', (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'gulls');
    await tester.pumpAndSettle();

    expect(find.text('Harbour walk'), findsOneWidget);
    expect(find.text('Library evening'), findsNothing);
  });

  testWidgets('says so when nothing matches, and clears back', (tester) async {
    final state = await ready();
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(SearchBar), 'submarine');
    await tester.pumpAndSettle();
    expect(find.text('No chats match your search.'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('Library evening'), findsOneWidget);
    expect(find.text('Harbour walk'), findsOneWidget);
  });
}
