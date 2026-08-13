import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/macro_engine.dart';
import 'package:maichat/services/preset_io.dart';
import 'package:maichat/services/prompt_builder.dart';

/// Regression coverage for the real-world "Marinara's Spaghetti" SillyTavern
/// preset, which frames the chat with absolute (depth) injections — the tags
/// that wrap the history and the final message. A prior bug dropped/mis-placed
/// depth injections, so those wrappers came out broken.
Character _alice() => Character(
      id: 'a',
      name: 'Alice',
      description: 'A curious explorer.',
      personality: 'Bold and kind.',
      scenario: 'A market at dawn.',
      mesExample: 'Alice: Hi!',
    );

int _indexOf(List<ChatMessage> m, String needle) =>
    m.indexWhere((x) => x.content.trim() == needle);

void main() {
  final json = jsonDecode(
    File('test/fixtures/marinara_spaghetti.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final preset = importPreset(json);
  final builder = PromptBuilder(macros: const DefaultMacroEngine());

  test('imports as SillyTavern with the definition markers intact', () {
    expect(detectFormat(json), PresetFormat.sillyTavern);
    for (final id in ['charDescription', 'charPersonality', 'scenario']) {
      final block = preset.blockById(id);
      expect(block?.marker, isTrue, reason: '$id must survive as a marker');
      expect(preset.promptOrder.any((e) => e.identifier == id && e.enabled),
          isTrue);
    }
  });

  test('the character definition reaches the model', () {
    final built = builder.build(
      preset: preset,
      character: _alice(),
      history: [ChatMessage(role: 'user', content: 'Who are you?')],
    );
    final text = built.messages.map((m) => m.content).join('\n');
    expect(text, contains('A curious explorer.'));
    expect(text, contains('Bold and kind.'));
    expect(text, contains('A market at dawn.'));
  });

  test('depth injections wrap the history and the final message in order', () {
    final built = builder.build(
      preset: preset,
      character: _alice(),
      history: [
        ChatMessage(role: 'user', content: 'first'),
        ChatMessage(role: 'assistant', content: 'reply'),
        ChatMessage(role: 'user', content: 'Who are you?'),
      ],
    );
    final m = built.messages;

    // The wrapper tags must all be present...
    for (final tag in [
      '<chat_history>',
      '</chat_history>',
      '<last_message>',
      '</last_message>',
      '<task>',
      '</task>',
    ]) {
      expect(_indexOf(m, tag), isNonNegative, reason: '$tag missing');
    }

    // ...and in the right structural order: older history inside
    // <chat_history>…</chat_history>, the latest turn inside
    // <last_message>…</last_message>, then the task block after it.
    expect(_indexOf(m, '<chat_history>'), lessThan(_indexOf(m, 'first')));
    expect(_indexOf(m, 'first'), lessThan(_indexOf(m, 'reply')));
    expect(_indexOf(m, 'reply'), lessThan(_indexOf(m, '</chat_history>')));
    expect(_indexOf(m, '</chat_history>'), lessThan(_indexOf(m, '<last_message>')));
    expect(_indexOf(m, '<last_message>'), lessThan(_indexOf(m, 'Who are you?')));
    expect(_indexOf(m, 'Who are you?'), lessThan(_indexOf(m, '</last_message>')));
    expect(_indexOf(m, '</last_message>'), lessThan(_indexOf(m, '<task>')));
  });
}
