import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the exact request AppState hands to the wire layer. Assembly can
/// look right and still send the wrong thing, so lorebook behaviour is asserted
/// where it matters: on the messages the model receives.
class _CaptureClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = history;
    yield const ChatDelta(text: 'ok');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Future<(AppState, _CaptureClient)> _state() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = _CaptureClient();
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(Provider(
    id: 'p',
    name: 'p',
    kind: ProviderKind.openai,
    baseUrl: 'https://example.com/v1',
    model: 'gpt',
    apiKey: 'k',
  ));
  return (state, client);
}

Lorebook _book({
  String id = 'b1',
  String name = 'Kingdom',
  List<LorebookEntry>? entries,
}) =>
    Lorebook(
      id: id,
      name: name,
      entries: entries ??
          [
            LorebookEntry(
              uid: 0,
              name: 'Valeport',
              content: 'Valeport is the capital, built on seven bridges.',
              keys: const ['valeport', 'capital'],
            ),
          ],
    );

String _dump(List<ChatMessage>? h) =>
    (h ?? []).map((m) => '[${m.role}] ${m.content}').join('\n---\n');

void main() {
  test('an entry whose keyword was mentioned reaches the model', () async {
    final (state, client) = await _state();
    final book = _book();
    await state.addLorebook(book);
    await state.toggleConversationLorebook(state.active.id, book.id);

    await state.send('Tell me about the capital.');

    expect(_dump(client.lastHistory), contains('seven bridges'));
  });

  test('an entry nobody mentioned does not', () async {
    final (state, client) = await _state();
    final book = _book();
    await state.addLorebook(book);
    await state.toggleConversationLorebook(state.active.id, book.id);

    await state.send('Tell me about the weather.');

    expect(_dump(client.lastHistory), isNot(contains('seven bridges')));
  });

  test('a book that was never switched on contributes nothing', () async {
    final (state, client) = await _state();
    await state.addLorebook(_book());

    await state.send('Tell me about the capital.');

    expect(_dump(client.lastHistory), isNot(contains('seven bridges')));
  });

  test('several active books all contribute', () async {
    final (state, client) = await _state();
    final one = _book(id: 'b1', name: 'Places');
    final two = _book(
      id: 'b2',
      name: 'People',
      entries: [
        LorebookEntry(
          uid: 0,
          name: 'Queen',
          content: 'Queen Isolde has ruled for forty years.',
          keys: const ['queen'],
        ),
      ],
    );
    await state.addLorebook(one);
    await state.addLorebook(two);
    await state.toggleConversationLorebook(state.active.id, one.id);
    await state.toggleConversationLorebook(state.active.id, two.id);

    await state.send('Does the queen live in the capital?');

    final text = _dump(client.lastHistory);
    expect(text, contains('seven bridges'));
    expect(text, contains('forty years'));
  });

  test('lore keeps the one-leading-system-message shape', () async {
    final (state, client) = await _state();
    final book = _book(
      entries: [
        LorebookEntry(
          uid: 0,
          name: 'Ahead',
          content: 'Lore in front of the definitions.',
          keys: const ['capital'],
        ),
        LorebookEntry(
          uid: 1,
          name: 'In chat',
          content: 'Lore injected between the turns.',
          keys: const ['capital'],
          position: LorebookPosition.atDepth,
          depth: 1,
        ),
      ],
    );
    await state.addLorebook(book);
    await state.toggleConversationLorebook(state.active.id, book.id);

    // Two exchanges, so a depth-1 injection really does land between turns
    // rather than ahead of the only message there is.
    await state.send('Hello.');
    await state.send('What is the capital?');
    final msgs = client.lastHistory ?? const <ChatMessage>[];
    final text = _dump(msgs);
    expect(text, contains('in front of the definitions'));
    expect(text, contains('injected between the turns'));

    // The rule the whole prompt pipeline is built around: at most one system
    // message, and if there is one it is first. Lore injected at a chat depth
    // must therefore travel as a user turn, not as a second system message.
    final systems = msgs.where((m) => m.role == 'system').toList();
    expect(systems.length, lessThanOrEqualTo(1));
    if (systems.isNotEmpty) expect(msgs.first.role, 'system');
    final depthTurn =
        msgs.firstWhere((m) => m.content.contains('injected between the turns'));
    expect(depthTurn.role, isNot('system'));
  });

  test('macros in an entry resolve against the current identity', () async {
    final (state, client) = await _state();
    final alice = Character(id: 'a', name: 'Alice', description: 'An explorer.');
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    final book = _book(
      entries: [
        LorebookEntry(
          uid: 0,
          name: 'Bond',
          content: '{{char}} has known {{user}} for years.',
          keys: const ['history'],
        ),
      ],
    );
    await state.addLorebook(book);
    await state.toggleConversationLorebook(state.active.id, book.id);

    await state.send('What is our history?');

    expect(_dump(client.lastHistory), contains('Alice has known User for years'));
  });

  test('deleting a book switches it off everywhere it was used', () async {
    final (state, client) = await _state();
    final book = _book();
    await state.addLorebook(book);
    final chatId = state.active.id;
    await state.toggleConversationLorebook(chatId, book.id);
    expect(state.active.lorebookIds, [book.id]);

    await state.deleteLorebook(book.id);
    expect(state.active.lorebookIds, isEmpty);

    await state.send('Tell me about the capital.');
    expect(_dump(client.lastHistory), isNot(contains('seven bridges')));
  });

  test('an active book survives being reloaded from storage', () async {
    final (state, _) = await _state();
    final book = _book();
    await state.addLorebook(book);
    await state.toggleConversationLorebook(state.active.id, book.id);
    await state.send('Tell me about the capital.');

    final reopened = AppState(client: _CaptureClient());
    await reopened.init();
    expect(reopened.lorebooks.map((b) => b.name), ['Kingdom']);
    expect(reopened.lorebooksFor(reopened.active).map((b) => b.id), [book.id]);
    expect(
      reopened.lorebooks.single.entries.single.content,
      contains('seven bridges'),
    );
  });
}


