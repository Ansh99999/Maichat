import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the history a send would have transmitted.
class FakeClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = List<ChatMessage>.from(history);
    yield const ChatDelta(text: 'ok');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Provider _provider() => Provider(
      id: 'p',
      name: 'Test',
      kind: ProviderKind.openai,
      baseUrl: 'https://host.tld/v1',
      apiKey: '',
      model: 'm',
    );

Future<AppState> _state([FakeClient? client]) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final state = AppState(client: client ?? FakeClient());
  await state.init();
  return state;
}

Character _character({String id = 'c', String name = 'Aria'}) => Character(
      id: id,
      name: name,
      description: 'A calm librarian.',
      firstMes: 'Hello there.',
    );

void main() {
  test('add, update, delete and duplicate characters', () async {
    final state = await _state();

    await state.addCharacter(_character());
    expect(state.characters, hasLength(1));

    final edited = state.characters.single..name = 'Aria II';
    await state.saveCharacter(edited);
    expect(state.characters.single.name, 'Aria II');

    final copy = await state.duplicateCharacter(state.characters.single);
    expect(state.characters, hasLength(2));
    expect(copy.name, contains('(copy)'));
    expect(copy.id, isNot('c'));

    await state.deleteCharacter('c');
    expect(state.characters, hasLength(1));
    expect(state.characterById('c'), isNull);
  });

  test('starring flips and persists', () async {
    final state = await _state();
    await state.addCharacter(_character());

    await state.toggleCharacterStar('c');
    expect(state.characterById('c')!.starred, isTrue);

    final reopened = AppState(client: FakeClient());
    await reopened.init();
    expect(reopened.characterById('c')!.starred, isTrue);
  });

  test('characters reload from storage', () async {
    final state = await _state();
    await state.addCharacter(_character());

    final reopened = AppState(client: FakeClient());
    await reopened.init();
    expect(reopened.characters, hasLength(1));
    expect(reopened.characterById('c')!.name, 'Aria');
  });

  test('starting a character chat seeds the greeting and binds identity',
      () async {
    final state = await _state();
    final character = _character();
    await state.addCharacter(character);

    final id = state.startChatWithCharacter(character);

    final chat = state.conversations.firstWhere((c) => c.id == id);
    expect(chat.characterId, 'c');
    expect(chat.title, 'Aria');
    expect(chat.systemPrompt, isNotEmpty);
    expect(chat.messages.single.role, 'assistant');
    expect(chat.messages.single.content, 'Hello there.');
  });

  test('a character chat injects its persona as a leading system turn',
      () async {
    final client = FakeClient();
    final state = await _state(client);
    await state.addProvider(_provider());
    final character = Character(
      id: 'c',
      name: 'Aria',
      description: 'A calm librarian.',
    ); // no greeting, to keep the history minimal
    await state.addCharacter(character);
    state.startChatWithCharacter(character);

    await state.send('hi');

    // The default preset assembles the persona from the character's fields:
    // a leading system turn, a system block carrying the description, and the
    // user's message last.
    final history = client.lastHistory!;
    expect(history.first.role, 'system');
    expect(
      history.any((m) => m.role == 'system' && m.content.contains('A calm librarian.')),
      isTrue,
    );
    expect(history.last.role, 'user');
    expect(history.last.content, 'hi');
  });

  test('restarting a character chat re-seeds the greeting and keeps identity',
      () async {
    final state = await _state();
    final character = _character();
    await state.addCharacter(character);
    state.startChatWithCharacter(character);

    await state.restartConversation();

    final chat = state.active;
    expect(chat.characterId, 'c');
    expect(chat.title, 'Aria');
    expect(chat.messages.single.content, 'Hello there.');
  });
}
