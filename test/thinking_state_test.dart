import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Replays a scripted reply, and records the params it was called with.
class _FakeClient extends ChatClient {
  _FakeClient({this.deltas = const <ChatDelta>[]});

  final List<ChatDelta> deltas;
  GenParams? lastParams;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastParams = params;
    for (final delta in deltas) {
      yield delta;
    }
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

Future<(AppState, _FakeClient)> _state({
  List<ChatDelta> deltas = const <ChatDelta>[],
  String model = 'gpt-4o',
}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = _FakeClient(deltas: deltas);
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(Provider(
    id: 'p',
    name: 'p',
    kind: ProviderKind.openai,
    baseUrl: 'https://example.com/v1',
    model: model,
    apiKey: 'k',
  ));
  return (state, client);
}

Future<Preset> _preset(AppState state, void Function(Preset) edit) async {
  final preset = state.defaultPreset!;
  edit(preset);
  await state.savePreset(preset);
  return preset;
}

void main() {
  test('tagged thinking is lifted off the reply and timed', () async {
    final (state, _) = await _state(deltas: const [
      ChatDelta(text: '<think>'),
      ChatDelta(text: 'weighing it up'),
      ChatDelta(text: '</think>'),
      ChatDelta(text: 'Hello!'),
    ]);

    await state.send('hi');

    final reply = state.active.messages.last;
    expect(reply.content, 'Hello!');
    expect(reply.reasoning, 'weighing it up');
    expect(reply.hasReasoning, isTrue);
    expect(reply.error, isFalse);
    // Timed from the request, so it is always a real measurement.
    expect(reply.thinkingMs, isNotNull);
  });

  test('a mid-stream tag fragment is never shown as message text', () async {
    final (state, _) = await _state(deltas: const [
      ChatDelta(text: '<thi'),
      ChatDelta(text: 'nk>hidden</thi'),
      ChatDelta(text: 'nk>Visible'),
    ]);

    await state.send('hi');

    expect(state.active.messages.last.content, 'Visible');
    expect(state.active.messages.last.reasoning, 'hidden');
  });

  test('reasoning the provider returns separately lands in the same place',
      () async {
    final (state, _) = await _state(deltas: const [
      ChatDelta(reasoning: 'first I check'),
      ChatDelta(text: 'Then I answer.'),
    ]);

    await state.send('hi');

    final reply = state.active.messages.last;
    expect(reply.reasoning, 'first I check');
    expect(reply.content, 'Then I answer.');
    expect(reply.thinkingMs, isNotNull);
  });

  test('thinking with no answer is reported, keeping the thinking', () async {
    final (state, _) = await _state(deltas: const [
      ChatDelta(text: '<think>ran out of room'),
    ]);

    await state.send('hi');

    final reply = state.active.messages.last;
    expect(reply.error, isTrue);
    expect(reply.content, contains('no answer'));
    expect(reply.reasoning, 'ran out of room');
  });

  test('an empty reply with no thinking still reads as empty', () async {
    final (state, _) = await _state();
    await state.send('hi');
    expect(state.active.messages.last.error, isTrue);
    expect(state.active.messages.last.content, contains('empty'));
  });

  test('clearing a tag leaves the reply exactly as it arrives', () async {
    final (state, _) = await _state(deltas: const [
      ChatDelta(text: '<think>visible now</think>Hi'),
    ]);
    await _preset(state, (p) => p.thinkEndTag = '');

    await state.send('hi');

    expect(state.active.messages.last.content, '<think>visible now</think>Hi');
    expect(state.active.messages.last.hasReasoning, isFalse);
  });

  test('thinking is never sent back on the next turn', () async {
    final (state, client) = await _state(deltas: const [
      ChatDelta(text: '<think>secret</think>Hello!'),
    ]);
    await state.send('hi');
    await state.send('again');

    final sent = state.active.messages
        .where((m) => !m.isUser)
        .map((m) => m.toApi()['content'])
        .toList();
    expect(sent, everyElement(isNot(contains('secret'))));
    expect(client.lastParams, isNotNull);
  });

  test('the preset carries thinking settings to the wire', () async {
    final (state, client) = await _state();
    await _preset(state, (p) {
      p.thinking = true;
      p.thinkingBudget = 2048;
      p.reasoningEffort = 'high';
      p.stream = false;
    });

    await state.send('hi');

    expect(client.lastParams!.thinking, isTrue);
    expect(client.lastParams!.thinkingBudget, 2048);
    expect(client.lastParams!.reasoningEffort, 'high');
    expect(client.lastParams!.stream, isFalse);
  });

  test('thinking survives a save/load round trip', () async {
    final (state, _) = await _state(deltas: const [
      ChatDelta(text: '<think>remembered</think>Hi'),
    ]);
    await state.send('hi');

    final reloaded = AppState(client: _FakeClient());
    await reloaded.init();
    final reply = reloaded.conversations.first.messages.last;
    expect(reply.reasoning, 'remembered');
    expect(reply.thinkingMs, isNotNull);
  });

  group('use model max context if known', () {
    test('a known model overrides the preset number', () async {
      final (state, _) = await _state(model: 'gpt-4o');
      await _preset(state, (p) {
        p.maxContext = 4095;
        p.useMaxContext = true;
      });
      await state.send('hi');

      final assembled = state.assemblePromptForMessage(state.active, 0);
      expect(assembled.maxContext, 128000);
    });

    test('an unknown model keeps the preset number rather than guessing',
        () async {
      final (state, _) = await _state(model: 'my-local-finetune');
      await _preset(state, (p) {
        p.maxContext = 4095;
        p.useMaxContext = true;
      });
      await state.send('hi');

      expect(state.assemblePromptForMessage(state.active, 0).maxContext, 4095);
    });

    test('the switch off leaves the preset in charge', () async {
      final (state, _) = await _state(model: 'gpt-4o');
      await _preset(state, (p) {
        p.maxContext = 4095;
        p.useMaxContext = false;
      });
      await state.send('hi');

      expect(state.assemblePromptForMessage(state.active, 0).maxContext, 4095);
    });
  });
}
