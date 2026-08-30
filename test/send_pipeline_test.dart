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
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = history;
    lastParams = params;
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

  test('the message and the turn waiting for a reply are published before the '
      'request is built', () async {
    // Why this is worth pinning: assembling a request is real work — macros over
    // the whole history, then a BPE pass over everything the context budget can
    // fit — and it used to run *before* the first notification, so on a long chat
    // the tap on send did nothing visible for as long as that took. Publishing
    // the pending turn first is the difference between "instant" and "stuck".
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final client = _OrderClient();
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
    var notifications = 0;
    state.addListener(() {
      notifications++;
      client.notifications = notifications;
      client.publishedTurns = state.active.messages.length;
      client.publishedStreaming = state.streaming;
    });

    await state.send('Where are we?');

    expect(client.turnsAtRequest, 2,
        reason: 'the user turn and the turn the reply lands in were both '
            'published before the request went out');
    expect(client.streamingAtRequest, isTrue,
        reason: 'and the composer had already flipped to Stop');
    expect(client.notificationsAtRequest, greaterThan(0),
        reason: 'something reached the screen before the work started');
    expect(notifications, greaterThan(client.notificationsAtRequest),
        reason: 'and more followed as the reply arrived');
  });
}

/// Records what the app had already told its listeners by the time the request
/// was actually made.
class _OrderClient extends ChatClient {
  int notifications = 0;
  int publishedTurns = 0;
  bool publishedStreaming = false;

  int turnsAtRequest = -1;
  bool streamingAtRequest = false;
  int notificationsAtRequest = -1;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    turnsAtRequest = publishedTurns;
    streamingAtRequest = publishedStreaming;
    notificationsAtRequest = notifications;
    yield const ChatDelta(text: 'The harbour.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}
