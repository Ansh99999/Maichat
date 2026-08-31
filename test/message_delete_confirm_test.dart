import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/screens/chat_screen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/widgets/message_bubble.dart';
import 'package:provider/provider.dart' hide Provider;
import 'package:shared_preferences/shared_preferences.dart';

/// Deleting a turn: never on one tap, and never sweeping away the replies that
/// followed it without being asked for.
///
/// Both ways in are covered — the inline symbol on the action bar and the
/// long-press sheet — because they are the two places a mistap actually happens.
class _FakeClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield const ChatDelta(text: 'Very well.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  late Directory dir;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    dir = Directory.systemTemp.createTempSync('delete-ui');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
    avatarDirectory = null;
  });

  Future<AppState> boot() async {
    final state = AppState(client: _FakeClient(), avatars: AvatarStore(dir));
    await state.init();
    await state.addProvider(Provider(
      id: 'p',
      name: 'local',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      model: 'm',
      apiKey: 'k',
    ));
    return state;
  }

  Widget host(AppState state) => ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const MaterialApp(home: ChatScreen()),
      );

  /// A chat of six turns: "one" / "reply one" / "two" / … — seeded straight onto
  /// the thread rather than sent, because a widget test's fake-async zone never
  /// pumps a stream's paint timers and an awaited `send` would simply hang.
  Future<AppState> seeded(WidgetTester tester) async {
    final state = await boot();
    for (final text in ['one', 'two', 'three']) {
      state.active.messages
        ..add(ChatMessage(role: 'user', content: text))
        ..add(ChatMessage(role: 'assistant', content: 'reply $text'));
    }
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();
    expect(state.active.messages, hasLength(6));
    return state;
  }

  /// Taps the delete symbol on the bubble carrying [text].
  Future<void> tapDeleteOn(WidgetTester tester, String text) async {
    final bubble = find.ancestor(
      of: find.text(text),
      matching: find.byType(MessageBubble),
    );
    final button = find.descendant(
      of: bubble,
      matching: find.byIcon(Icons.delete_outline),
    );
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('the newest turn asks once, and Cancel leaves it alone',
      (tester) async {
    final state = await seeded(tester);

    await tapDeleteOn(tester, 'two');
    // Nothing has gone yet: there is a question first.
    expect(find.text('Delete message?'), findsOneWidget);
    expect(state.active.messages, hasLength(6));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(state.active.messages, hasLength(6));
    expect(state.active.messages.map((m) => m.content), contains('two'));
  });

  testWidgets('a turn with nothing after it is a plain confirmation',
      (tester) async {
    final state = await seeded(tester);

    // The last message in the thread — the newest reply.
    await tapDeleteOn(tester, 'reply three');
    expect(find.text('Delete message?'), findsOneWidget);
    // No choice to offer: there is nothing after it to sweep away.
    expect(find.byKey(const Key('delete-this-only')), findsNothing);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();
    expect(state.active.messages, hasLength(5));
    expect(state.active.messages.last.content, 'three');
  });

  testWidgets('a turn from the middle offers both deletes, and "this one only" '
      'keeps what followed', (tester) async {
    final state = await seeded(tester);

    await tapDeleteOn(tester, 'two');
    // "two" is the third of six turns, so three follow it and four go if the
    // sweeping choice is taken.
    expect(find.textContaining('3 messages after this one'), findsOneWidget);
    expect(find.text('Delete 4'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-this-only')));
    await tester.pumpAndSettle();

    expect(state.active.messages, hasLength(5));
    expect(state.active.messages.map((m) => m.content),
        isNot(contains('two')));
    // Everything that followed it is still in the transcript.
    expect(state.active.messages.map((m) => m.content), contains('three'));
    expect(state.active.messages.map((m) => m.content), contains('reply two'));
  });

  testWidgets('"delete N" takes the turn and everything after it',
      (tester) async {
    final state = await seeded(tester);

    await tapDeleteOn(tester, 'two');
    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();

    // "two" was the third message, so it and the three after it are gone.
    expect(state.active.messages, hasLength(2));
    expect(state.active.messages.first.content, 'one');
    expect(state.active.messages.map((m) => m.content),
        isNot(contains('three')));
  });

  testWidgets('the same question comes from the overflow menu', (tester) async {
    // The other place a delete is reachable: with the symbol configured into the
    // three-dot menu rather than inline on the bar. Same handler, same question —
    // asserted here because it is the route somebody who tidied their action bar
    // actually uses.
    final state = await boot();
    await state.updateChatInterface(state.chatInterface.copyWith(
      messageActions: [
        for (final pref in state.chatInterface.messageActions)
          pref.action == MessageAction.delete
              ? const MessageActionPref(MessageAction.delete)
              : pref,
      ],
    ));
    state.active.messages
      ..add(ChatMessage(role: 'user', content: 'one'))
      ..add(ChatMessage(role: 'assistant', content: 'reply one'))
      ..add(ChatMessage(role: 'user', content: 'two'))
      ..add(ChatMessage(role: 'assistant', content: 'reply two'));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    // No inline delete symbol left to tap.
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    final bubble = find.ancestor(
      of: find.text('two'),
      matching: find.byType(MessageBubble),
    );
    final menu = find.descendant(
      of: bubble,
      matching: find.byIcon(Icons.more_vert),
    );
    await tester.ensureVisible(menu);
    await tester.pumpAndSettle();
    await tester.tap(menu);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete').last);
    await tester.pumpAndSettle();

    expect(find.text('Delete message?'), findsOneWidget);
    expect(state.active.messages, hasLength(4));
    // "two" is the third of four turns, so one follows it.
    expect(find.textContaining('1 message after this one'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();
    expect(state.active.messages, hasLength(2));
  });

  testWidgets('one turn on its own still asks', (tester) async {
    final state = await boot();
    state.active.messages.add(ChatMessage(role: 'user', content: 'only'));
    await tester.pumpWidget(host(state));
    await tester.pumpAndSettle();

    await tapDeleteOn(tester, 'only');
    expect(find.text('Delete message?'), findsOneWidget);
    expect(find.textContaining('after this one'), findsNothing);

    await tester.tap(find.byKey(const Key('delete-confirm')));
    await tester.pumpAndSettle();
    expect(state.active.messages, isEmpty);
  });
}
