import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Captures what AppState hands the wire layer.
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

Character _alice() => Character(
      id: 'alice',
      name: 'Alice',
      description: 'A curious explorer who calls {{user}} by name.',
      personality: 'Bold and kind.',
      scenario: 'A market at dawn.',
    );

String _dump(List<ChatMessage>? h) =>
    (h ?? const <ChatMessage>[]).map((m) => '[${m.role}] ${m.content}').join('\n');

void main() {
  test('a preset lacking definition markers still sends the definition',
      () async {
    final (state, client) = await _state();

    // A trimmed/imported-style preset: instructions + chat only, none of the
    // character-definition markers. Before the fix this dropped the whole
    // definition, sending just the main prompt and the last user message.
    final preset = Preset.create(name: 'Minimal')
      ..promptOrder.clear()
      ..promptOrder.addAll([
        PromptOrderEntry(identifier: PromptId.main),
        PromptOrderEntry(identifier: PromptId.chatHistory),
      ]);
    await state.addPreset(preset);
    await state.setDefaultPreset(preset.id);

    final alice = _alice();
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    await state.send('Who are you?');

    final text = _dump(client.lastHistory);
    expect(text, contains('A curious explorer who calls User by name.'),
        reason: 'description must reach the model even without a marker');
    expect(text, contains('Bold and kind.'));
    expect(text, contains('A market at dawn.'));
  });

  test('the definition marker path is not duplicated by the fallback',
      () async {
    final (state, client) = await _state();
    // Default preset (has the markers): the definition comes through once.
    final alice = _alice();
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    await state.send('hi');

    final text = _dump(client.lastHistory);
    final occurrences = 'Bold and kind.'.allMatches(text).length;
    expect(occurrences, 1, reason: 'no double-injection when markers emit');
  });

  test('disabling every definition marker still yields the definition',
      () async {
    final (state, client) = await _state();
    final preset = Preset.create(name: 'DefsOff');
    for (final e in preset.promptOrder) {
      if (const {
        PromptId.charDescription,
        PromptId.charPersonality,
        PromptId.scenario,
        PromptId.dialogueExamples,
      }.contains(e.identifier)) {
        e.enabled = false;
      }
    }
    await state.addPreset(preset);
    await state.setDefaultPreset(preset.id);

    final alice = _alice();
    await state.addCharacter(alice);
    state.startChatWithCharacter(alice);
    await state.send('hi');

    expect(_dump(client.lastHistory), contains('A curious explorer'));
  });
}
