import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/character_scenario.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures what a send would have transmitted.
class FakeClient extends ChatClient {
  List<ChatMessage>? lastHistory;
  String reply = 'ok';

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    yield ChatDelta(text: reply);
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Provider _provider() => Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: 'k',
      model: 'm',
    );

Future<AppState> _boot([FakeClient? client]) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: client ?? FakeClient());
  await state.init();
  await state.addProvider(_provider());
  return state;
}

Lorebook _book({String id = 'b', String name = 'Port'}) => Lorebook(
      id: id,
      name: name,
      entries: [
        LorebookEntry(
          uid: 0,
          name: 'Harbour',
          keys: const ['harbour'],
          content: 'It never stops raining.',
        ),
      ],
    );

/// The two things attaching data to a character has to actually *do*: a lorebook
/// that comes with a character has to reach the prompt, and a scenario pinned to
/// a greeting has to win when a chat opened on that greeting. Both resolve in one
/// place each (`lorebooksFor`, `scenarioFor`), so both are asserted there.
void main() {
  group("a character's own lorebooks", () {
    test('are in force in a chat with them', () async {
      final state = await _boot();
      await state.addLorebook(_book());
      final card = Character(
        id: 'c',
        name: 'Aria',
        firstMes: 'Hello.',
        lorebookIds: const ['b'],
      );
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);
      final chat = state.conversationById(chatId)!;

      expect(state.lorebooksFor(chat).map((b) => b.id), ['b']);
    });

    test('join the chat\'s own, counted once', () async {
      final state = await _boot();
      await state.addLorebook(_book(id: 'shared'));
      await state.addLorebook(_book(id: 'chat-only', name: 'Chat'));
      final card = Character(
        id: 'c',
        name: 'Aria',
        lorebookIds: const ['shared'],
      );
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);
      await state.setConversationLorebooks(chatId, ['chat-only', 'shared']);
      final chat = state.conversationById(chatId)!;

      // The chat's own first, then anything the character adds — and 'shared',
      // being both, appears exactly once.
      expect(state.lorebooksFor(chat).map((b) => b.id), ['chat-only', 'shared']);
    });

    test('every member of a group brings theirs', () async {
      final state = await _boot();
      await state.addLorebook(_book(id: 'a-book'));
      await state.addLorebook(_book(id: 'b-book', name: 'Other'));
      final one =
          Character(id: 'one', name: 'One', lorebookIds: const ['a-book']);
      final two =
          Character(id: 'two', name: 'Two', lorebookIds: const ['b-book']);
      await state.addCharacter(one);
      await state.addCharacter(two);
      final chatId = state.startChatWithCharacter(one);
      await state.addParticipant(chatId, two);
      final chat = state.conversationById(chatId)!;

      expect(
        state.lorebooksFor(chat).map((b) => b.id).toSet(),
        {'a-book', 'b-book'},
      );
    });

    test('an id whose book was deleted is skipped, not an error', () async {
      final state = await _boot();
      await state.addLorebook(_book());
      final card = Character(id: 'c', name: 'Aria', lorebookIds: const ['b']);
      await state.addCharacter(card);
      final chatId = state.startChatWithCharacter(card);

      await state.deleteLorebook('b');
      final chat = state.conversationById(chatId)!;
      expect(state.lorebooksFor(chat), isEmpty);
      // …and the character is no longer pointing at something that is gone.
      expect(state.characterById('c')!.lorebookIds, isEmpty);
    });

    test('lorebooksOf resolves what an export ships', () async {
      final state = await _boot();
      await state.addLorebook(_book(id: 'kept'));
      final card = Character(
        id: 'c',
        name: 'Aria',
        lorebookIds: const ['kept', 'gone'],
      );
      await state.addCharacter(card);
      expect(state.lorebooksOf(card).map((b) => b.id), ['kept']);
    });

    test('the lore reaches the wire', () async {
      final client = FakeClient();
      final state = await _boot(client);
      await state.addLorebook(_book());
      final card = Character(
        id: 'c',
        name: 'Aria',
        description: 'A dockworker.',
        lorebookIds: const ['b'],
      );
      await state.addCharacter(card);
      state.startChatWithCharacter(card);

      await state.send('what is the harbour like?');

      final sent = client.lastHistory!.map((m) => m.content).join('\n');
      expect(sent, contains('It never stops raining.'));
    });
  });

  group('the scenario a chat opens on', () {
    Character card() => Character(
          id: 'c',
          name: 'Aria',
          scenario: 'The card says a library.',
          firstMes: 'First greeting.',
          alternateGreetings: const ['Second greeting.', 'Third greeting.'],
          scenarios: [
            CharacterScenario(id: 's1', text: 'In the rain.', greetings: const [1]),
            CharacterScenario(id: 's2', text: 'Anywhere at all.'),
          ],
        );

    test('follows the greeting the chat is showing', () async {
      final state = await _boot();
      final c = card();
      await state.addCharacter(c);
      final chatId = state.startChatWithCharacter(c);
      final chat = state.conversationById(chatId)!;

      // Opened on the first greeting: nothing names it, so the general one.
      expect(state.scenarioFor(chat, c), 'Anywhere at all.');

      // Swipe to the second: the scenario written for it takes over.
      await state.setSwipe(chatId, 0, 1);
      expect(state.scenarioFor(state.conversationById(chatId)!, c),
          'In the rain.');

      // And the third falls back again.
      await state.setSwipe(chatId, 0, 2);
      expect(state.scenarioFor(state.conversationById(chatId)!, c),
          'Anywhere at all.');
    });

    test("a chat's own scenario still outranks all of them", () async {
      final state = await _boot();
      final c = card();
      await state.addCharacter(c);
      final chatId = state.startChatWithCharacter(c);
      await state.setSwipe(chatId, 0, 1);
      await state.setChatScenario(chatId, text: 'Only here.');

      expect(state.scenarioFor(state.conversationById(chatId)!, c),
          'Only here.');
    });

    test('a card with no per-greeting scenarios behaves exactly as before',
        () async {
      final state = await _boot();
      final plain = Character(
        id: 'p',
        name: 'Plain',
        scenario: 'A library.',
        firstMes: 'Hello.',
      );
      await state.addCharacter(plain);
      final chatId = state.startChatWithCharacter(plain);
      expect(
        state.scenarioFor(state.conversationById(chatId)!, plain),
        'A library.',
      );
    });

    test('a thread with no greeting turn uses the general one', () async {
      final state = await _boot();
      final c = card();
      await state.addCharacter(c);
      state.newConversation();
      final chat = state.active;
      expect(state.activeGreetingIndex(chat, c), isNull);
      expect(state.scenarioFor(chat, c), 'Anywhere at all.');
    });

    test('the greeting index survives the card growing a greeting', () async {
      final state = await _boot();
      final c = card();
      await state.addCharacter(c);
      final chatId = state.startChatWithCharacter(c);
      await state.setSwipe(chatId, 0, 1);

      // The author adds a fourth greeting after the chat started: the opening
      // turn still holds three swipes, so the index is matched by text instead.
      c.alternateGreetings = [...c.alternateGreetings, 'Fourth greeting.'];
      await state.saveCharacter(c);

      expect(state.activeGreetingIndex(state.conversationById(chatId)!, c), 1);
      expect(state.scenarioFor(state.conversationById(chatId)!, c),
          'In the rain.');
    });

    test('the chosen scenario is what goes out on the wire', () async {
      final client = FakeClient();
      final state = await _boot(client);
      final c = card();
      await state.addCharacter(c);
      final chatId = state.startChatWithCharacter(c);
      await state.setSwipe(chatId, 0, 1);

      await state.send('hello');
      final sent = client.lastHistory!.map((m) => m.content).join('\n');
      expect(sent, contains('In the rain.'));
      expect(sent, isNot(contains('The card says a library.')));
    });
  });

  group('the creator preference', () {
    test('persists and survives a restart', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final state = AppState(client: FakeClient());
      await state.init();
      expect(state.creatorVersion, CreatorVersion.v2);

      await state.setCreatorVersion(CreatorVersion.v1);
      expect(state.creatorVersion, CreatorVersion.v1);

      final reopened = AppState(client: FakeClient());
      await reopened.init();
      expect(reopened.creatorVersion, CreatorVersion.v1);
      // …and the browse layouts it shares an entry with are untouched.
      expect(reopened.browseLayout(BrowseSection.characters),
          BrowseLayout.grid);
    });
  });
}
