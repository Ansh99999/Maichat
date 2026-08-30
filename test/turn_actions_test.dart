import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The three ways to get a turn without typing one: continue the reply that is
/// there, ask for another reply, and have the model write the user's own line.
///
/// Each is asserted against the **outgoing request** as well as the transcript:
/// what makes "continue" a continuation rather than a fresh reply is entirely in
/// what reaches the model, and reasoning about the assembly alone has shipped
/// this kind of thing broken before.
class _FakeClient extends ChatClient {
  _FakeClient({this.reply = 'ok'});

  String reply;

  /// When set, the request throws with this message instead of answering.
  String? fail;

  List<ChatMessage>? lastHistory;
  int calls = 0;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    calls++;
    lastHistory = List<ChatMessage>.from(history);
    final failure = fail;
    if (failure != null) throw ChatApiException(failure);
    if (reply.isEmpty) return;
    // In two deltas, so the progress cadence has something to report.
    yield ChatDelta(text: reply.substring(0, 1));
    yield ChatDelta(text: reply.substring(1));
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Future<(AppState, _FakeClient)> _boot({String reply = 'ok'}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = _FakeClient(reply: reply);
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
      description: 'A curious explorer.',
    );

/// A chat with one exchange already in it, ending on Alice's reply.
Future<(AppState, _FakeClient)> _midChat({String reply = 'ok'}) async {
  final (state, client) = await _boot(reply: reply);
  final alice = _alice();
  await state.addCharacter(alice);
  state.startChatWithCharacter(alice);
  state.active.messages
    ..clear()
    ..add(ChatMessage(role: 'user', content: 'Where are we?'))
    ..add(ChatMessage(role: 'assistant', content: 'The harbour at dawn'));
  return (state, client);
}

String _dump(List<ChatMessage>? h) =>
    (h ?? []).map((m) => '[${m.role}] ${m.content}').join('\n---\n');

void main() {
  group('continue', () {
    test('extends the reply in place and hands the model what to carry on from',
        () async {
      final (state, client) = await _midChat(reply: ', gulls everywhere.');

      await state.continueReply();

      // One turn, longer than it was — not a second reply underneath it.
      expect(state.active.messages, hasLength(2));
      expect(state.active.messages.last.content,
          'The harbour at dawn, gulls everywhere.');
      // The reply so far went out as the start of the model's own answer, and it
      // is the last thing on the wire so nothing follows it.
      final sent = client.lastHistory!;
      expect(sent.last.role, 'assistant');
      expect(sent.last.content, endsWith('The harbour at dawn'),
          reason: 'the prefill must be the tail of the request:\n'
              '${_dump(sent)}');
    });

    test('has nothing to do when the last turn is the user\'s', () async {
      final (state, client) = await _midChat();
      state.active.messages.add(ChatMessage(role: 'user', content: 'And now?'));

      expect(state.continuableIndex(state.active), isNull);
      await state.continueReply();
      expect(client.calls, 0);
      expect(state.active.messages, hasLength(3));
    });

    test('has nothing to do in an empty chat, or on a failure notice', () async {
      final (state, _) = await _boot();
      expect(state.continuableIndex(state.active), isNull);

      state.active.messages.add(ChatMessage(
        role: 'assistant',
        swipes: const [MessageVariant(content: 'It broke.', error: true)],
      ));
      expect(state.continuableIndex(state.active), isNull);
    });

    test('a failed continuation leaves the reply it was extending intact',
        () async {
      final (state, client) = await _midChat();
      client.fail = 'The host said no.';

      await state.continueReply();

      // The reply is exactly as it was, and the failure is reported under it
      // rather than written over it.
      expect(state.active.messages.first.content, 'Where are we?');
      expect(state.active.messages[1].content, 'The harbour at dawn');
      expect(state.active.messages[1].error, isFalse);
      expect(state.active.messages.last.error, isTrue);
      expect(state.active.messages.last.content, 'The host said no.');
    });

    test('a continuation that comes back empty leaves the reply alone',
        () async {
      final (state, _) = await _midChat(reply: '');

      await state.continueReply();

      expect(state.active.messages[1].content, 'The harbour at dawn');
      expect(state.active.messages[1].error, isFalse);
      expect(state.active.messages.last.error, isTrue,
          reason: 'the user is told nothing came back');
    });

    test('the prefill never ends in whitespace (Anthropic rejects that)',
        () async {
      final (state, client) = await _midChat();
      state.active.messages[1] =
          ChatMessage(role: 'assistant', content: 'Half a thought   \n');

      await state.continueReply();

      expect(client.lastHistory!.last.content, isNot(endsWith(' ')));
      expect(client.lastHistory!.last.content, isNot(endsWith('\n')));
      // The message itself keeps the text it always had, plus what arrived.
      expect(state.active.messages[1].content, 'Half a thought   \nok');
    });
  });

  group('respond again', () {
    test('adds a reply with no user turn in front of it', () async {
      final (state, client) = await _midChat(reply: 'Gulls, mostly.');

      await state.respondAgain();

      expect(state.active.messages, hasLength(3));
      expect(state.active.messages.last.role, 'assistant');
      expect(state.active.messages.last.content, 'Gulls, mostly.');
      expect(state.active.messages.where((m) => m.isUser), hasLength(1),
          reason: 'nothing was typed, so nothing is added as the user');
      expect(client.calls, 1);
    });

    test('tells the model to start a new message when the request would '
        'otherwise end on its own words', () async {
      final (state, client) = await _midChat();

      await state.respondAgain();

      final sent = client.lastHistory!;
      expect(sent.last.role, 'user');
      expect(sent.last.content, contains('Alice'));
      expect(sent.last.content, contains('next message'),
          reason: 'the nudge is the tail of the request:\n${_dump(sent)}');
    });

    test('does nothing in an empty chat', () async {
      final (state, client) = await _boot();
      await state.respondAgain();
      expect(client.calls, 0);
      expect(state.active.messages, isEmpty);
    });
  });

  group('generate for me', () {
    test('returns the line and puts nothing in the chat', () async {
      final (state, client) = await _midChat(reply: 'Same as ever.');

      final written = await state.writeForUser();

      expect(written, 'Same as ever.');
      expect(state.active.messages, hasLength(2),
          reason: 'the line belongs in the composer until it is sent');
      expect(client.calls, 1);
    });

    test('asks the model for the user\'s voice, last thing on the wire',
        () async {
      final (state, client) = await _midChat();
      final bob = Character(id: 'bob', name: 'Bob', description: 'A sailor.');
      await state.addCharacter(bob);
      await state.setImpersonation(bob);

      await state.writeForUser();

      final sent = client.lastHistory!;
      expect(sent.last.role, 'user');
      expect(sent.last.content, contains('Bob’s next message'));
      expect(sent.last.content, contains('nothing for Alice'),
          reason: 'the fence against writing the other side:\n${_dump(sent)}');
    });

    test('reports progress as it is written', () async {
      final (state, _) = await _midChat(reply: 'Aye.');
      final seen = <String>[];

      await state.writeForUser(onProgress: seen.add);

      expect(seen, isNotEmpty);
      expect(seen.last, 'Aye.');
    });

    test('a failure is thrown for the caller to show, with nothing changed',
        () async {
      final (state, client) = await _midChat();
      client.fail = 'No key for that.';

      await expectLater(
        state.writeForUser(),
        throwsA(isA<ChatApiException>()),
      );
      expect(state.active.messages, hasLength(2));
      expect(state.streaming, isFalse);
    });

    test('a model that says nothing yields null', () async {
      final (state, _) = await _midChat(reply: '');
      expect(await state.writeForUser(), isNull);
      expect(state.active.messages, hasLength(2));
    });
  });

  test('nothing new starts while a reply is in flight', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final gate = Completer<void>();
    final client = _HoldingClient(gate);
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
    state.active.messages.add(ChatMessage(role: 'assistant', content: 'hello'));

    final inFlight = state.respondAgain();
    // The request is out and the stream is being held open.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(state.streaming, isTrue);
    expect(client.calls, 1);

    // Every one of the three refuses to pile on top of it.
    await state.continueReply();
    await state.respondAgain();
    expect(await state.writeForUser(), isNull);
    expect(client.calls, 1);

    gate.complete();
    await inFlight;
    expect(state.streaming, isFalse);
  });
}

/// Stands in for a client whose stream does not finish until it is released, so
/// the "already busy" refusals can be observed mid-flight.
class _HoldingClient extends ChatClient {
  _HoldingClient(this.gate);

  final Completer<void> gate;
  int calls = 0;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    calls++;
    yield const ChatDelta(text: 'thinking');
    await gate.future;
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}
