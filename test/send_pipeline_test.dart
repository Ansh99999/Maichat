import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures the exact history + params AppState hands to the wire layer, so the
/// tests assert on what the model actually receives.
class _CaptureClient extends ChatClient {
  List<ChatMessage>? lastHistory;
  GenParams? lastParams;

  @override
  Stream<String> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = history;
    lastParams = params;
    yield 'ok';
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

Character _alice() => Character(
      id: 'alice',
      name: 'Alice',
      description: 'A curious explorer who calls {{user}} by name.',
      personality: 'Bold and kind.',
      scenario: 'A market at dawn.',
      firstMes: 'Hello {{user}}, I am {{char}}.',
    );

Character _bob() => Character(
      id: 'bob',
      name: 'Bob',
      description: 'A gruff sailor.',
      personality: 'Weathered.',
    );

String _dump(List<ChatMessage>? h) =>
    (h ?? []).map((m) => '[${m.role}] ${m.content}').join('\n---\n');

void main() {
  test('the character definition reaches the model', () async {
    final (state, client) = await _state();
    final alice = _alice();
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);

    await state.send('Who are you?');

    final text = _dump(client.lastHistory);
    expect(text, contains('A curious explorer'),
        reason: 'description must be sent');
    expect(text, contains('Bold and kind.'), reason: 'personality must be sent');
    expect(text, contains('A market at dawn.'), reason: 'scenario must be sent');
  });

  test('impersonation rebinds {{user}} in card fields and the greeting',
      () async {
    final (state, client) = await _state();
    final alice = _alice();
    final bob = _bob();
    await state.addCharacter(alice);
    await state.addCharacter(bob);
    state.startChatWithCharacter(alice);

    await state.setImpersonation(bob);
    await state.send('Ahoy.');

    final msgs = client.lastHistory ?? const <ChatMessage>[];
    final text = _dump(msgs);

    // {{user}} in Alice's description resolves to the impersonated name.
    expect(text, contains('calls Bob by name'));
    expect(text, isNot(contains('calls User by name')));

    // The greeting, stored with macros intact, resolves at build time — so it
    // now addresses Bob, not the stale "User" baked in at chat creation.
    final greeting =
        msgs.firstWhere((m) => m.content.startsWith('Hello'), orElse: () =>
            ChatMessage(role: 'assistant', content: ''));
    expect(greeting.content, 'Hello Bob, I am Alice.');

    // Bob's persona is injected so the model knows who the user is.
    expect(text, contains('roleplaying as Bob'));
  });

  test('clearing impersonation restores {{user}} to the default', () async {
    final (state, client) = await _state();
    final alice = _alice();
    final bob = _bob();
    await state.addCharacter(alice);
    await state.addCharacter(bob);
    state.startChatWithCharacter(alice);

    await state.setImpersonation(bob);
    await state.send('one');
    await state.setImpersonation(null);
    await state.send('two');

    final text = _dump(client.lastHistory);
    expect(text, contains('calls User by name'));
    expect(text, isNot(contains('roleplaying as Bob')));
  });

  test('a deleted character still contributes its definition via the snapshot',
      () async {
    final (state, client) = await _state();
    final alice = _alice();
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    // The live character disappears, but the thread keeps its stored persona.
    await state.deleteCharacter(alice.id);

    await state.send('Still there?');

    final text = _dump(client.lastHistory);
    expect(text, contains('A curious explorer'),
        reason: 'the stored composed persona must still reach the model');
  });

  test('assemblePromptForMessage truncates per role and reports sections',
      () async {
    final (state, _) = await _state();
    final alice = _alice();
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice); // seeds a greeting (assistant, idx 0)
    await state.send('first'); // user idx1, assistant idx2
    await state.send('second'); // user idx3, assistant idx4

    final conv = state.active;
    // The assistant turn at idx 2 was produced from history BEFORE it — so its
    // prompt must not contain the later "second" turn.
    final atAssistant = state.assemblePromptForMessage(conv, 2);
    final aDump =
        atAssistant.messages.map((m) => m.content).join('\n');
    expect(aDump, contains('first'));
    expect(aDump, isNot(contains('second')));

    // A user turn shows what would be sent next — it includes that turn.
    final atUser = state.assemblePromptForMessage(conv, 3);
    expect(atUser.messages.map((m) => m.content).join('\n'), contains('second'));

    // Sections + budget are populated and self-consistent.
    expect(atAssistant.sections, isNotEmpty);
    expect(atAssistant.totalTokens, greaterThan(0));
    expect(atAssistant.maxContext, greaterThan(0));
    final sum =
        atAssistant.sections.fold<int>(0, (a, s) => a + s.tokens);
    expect(sum, atAssistant.totalTokens);
    expect(
      atAssistant.sections.map((s) => s.label),
      contains('Character description'),
    );
  });

  test('impersonation surfaces a User persona section in the breakdown',
      () async {
    final (state, _) = await _state();
    final alice = _alice();
    final bob = _bob();
    await state.addCharacter(alice);
    await state.addCharacter(bob);
    state.startChatWithCharacter(alice);
    await state.setImpersonation(bob);
    await state.send('hi');

    final conv = state.active;
    final assembled = state.assemblePromptForMessage(conv, conv.messages.length - 1);
    expect(
      assembled.sections.map((s) => s.label),
      contains('User persona'),
    );
  });
}
