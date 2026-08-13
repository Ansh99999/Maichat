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
    m.map((x) => x.content).join('\n').indexOf(needle);

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
        ChatMessage(role: 'user', content: 'HIST_ONE'),
        ChatMessage(role: 'assistant', content: 'HIST_TWO'),
        ChatMessage(role: 'user', content: 'HIST_LAST'),
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
    // <last_message>…</last_message>, then the task block after it. Offsets are
    // measured in the assembled text, since same-role runs are merged into one
    // turn before sending.
    expect(_indexOf(m, '<chat_history>'), lessThan(_indexOf(m, 'HIST_ONE')));
    expect(_indexOf(m, 'HIST_ONE'), lessThan(_indexOf(m, 'HIST_TWO')));
    expect(_indexOf(m, 'HIST_TWO'), lessThan(_indexOf(m, '</chat_history>')));
    expect(_indexOf(m, '</chat_history>'), lessThan(_indexOf(m, '<last_message>')));
    expect(_indexOf(m, '<last_message>'), lessThan(_indexOf(m, 'HIST_LAST')));
    expect(_indexOf(m, 'HIST_LAST'), lessThan(_indexOf(m, '</last_message>')));
    expect(_indexOf(m, '</last_message>'), lessThan(_indexOf(m, '<task>')));
  });

  test('the payload is merged into few turns, not dozens of system fragments',
      () {
    final built = builder.build(
      preset: preset,
      character: _alice(),
      history: [ChatMessage(role: 'user', content: 'Who are you?')],
    );
    // Before merging this preset produced ~38 messages, 37 of them `system`
    // fragments as short as a bare `<role>` tag — hosts that honour only the
    // first system message then saw none of the definition.
    expect(built.messages.length, lessThan(12));
    // The definition must ride in the FIRST system turn, which is the one a
    // system-collapsing host keeps.
    final firstSystem =
        built.messages.firstWhere((x) => x.role == 'system').content;
    expect(firstSystem, contains('A curious explorer.'));
    expect(firstSystem, contains('Bold and kind.'));
    expect(firstSystem, contains('A market at dawn.'));
    // No two adjacent turns share a role.
    for (var i = 1; i < built.messages.length; i++) {
      expect(built.messages[i].role, isNot(built.messages[i - 1].role),
          reason: 'adjacent turns at $i share a role');
    }
  });
}
