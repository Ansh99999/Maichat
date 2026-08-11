import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/services/macro_context.dart';
import 'package:maichat/services/prompt_builder.dart';

/// A minimal stand-in for the real macro engine: resolves just the two macros
/// the builder's markers rely on, so these tests stay independent of the full
/// engine implementation.
class FakeMacroEngine implements MacroEngine {
  @override
  String evaluate(String text, MacroContext ctx) => text
      .replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), ctx.charName)
      .replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), ctx.userName);
}

Character _alice() => Character(
      id: 'a',
      name: 'Alice',
      description: 'A curious explorer.',
      personality: 'Bold and kind.',
      scenario: 'A market at dawn.',
      mesExample: '<START>\nAlice: Hi!',
    );

List<ChatMessage> _history(int n) => [
      for (var i = 0; i < n; i++)
        ChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'msg $i'),
    ];

void main() {
  final builder = PromptBuilder(macros: FakeMacroEngine());

  test('assembles blocks in order with markers filled and macros resolved', () {
    final built = builder.build(
      preset: Preset.create(),
      character: _alice(),
      history: _history(2),
    );
    final contents = built.messages.map((m) => m.content).toList();

    // Leading system blocks: main, description, personality, scenario, examples.
    expect(built.messages.first.role, 'system');
    expect(contents.first, contains('Alice')); // {{char}} resolved in main
    expect(contents, contains('A curious explorer.'));
    expect(contents, contains('Bold and kind.'));
    expect(contents, contains('A market at dawn.'));
    // History follows, in chronological order.
    expect(contents.sublist(contents.length - 2), ['msg 0', 'msg 1']);
    // Empty blocks (nsfw, worldInfo, jailbreak) are dropped.
    expect(contents.where((c) => c.trim().isEmpty), isEmpty);
  });

  test('character system prompt overrides the main block', () {
    final built = builder.build(
      preset: Preset.create(),
      character: _alice()..systemPrompt = 'Custom {{char}} directive.',
      history: const [],
    );
    expect(built.messages.first.content, 'Custom Alice directive.');
  });

  test('history is truncated newest-first to fit the context budget', () {
    final preset = Preset.create()
      ..maxContext = 40 // tiny budget after subtracting the response reserve
      ..maxResponseTokens = 0;
    // Disable everything but chat history so the whole budget is history's.
    for (final e in preset.promptOrder) {
      e.enabled = e.identifier == PromptId.chatHistory ||
          e.identifier == PromptId.main;
    }
    preset.blockById(PromptId.main)!.content = '';
    final built = builder.build(preset: preset, history: _history(50));
    final kept = built.messages.where((m) => m.content.startsWith('msg ')).toList();
    expect(kept, isNotEmpty);
    expect(kept.length, lessThan(50));
    // The kept messages are the most recent ones, in order.
    expect(kept.last.content, 'msg 49');
  });

  test('squashSystemMessages merges consecutive system turns', () {
    final preset = Preset.create()..squashSystemMessages = true;
    final built = builder.build(
      preset: preset,
      character: _alice(),
      history: const [],
    );
    final systemRuns = built.messages.where((m) => m.role == 'system').length;
    // Everything collapses to a single system message when there is no history.
    expect(systemRuns, 1);
  });

  test('disabled blocks are skipped (except main)', () {
    final preset = Preset.create();
    preset.promptOrder
        .firstWhere((e) => e.identifier == PromptId.scenario)
        .enabled = false;
    final built = builder.build(
      preset: preset,
      character: _alice(),
      history: const [],
    );
    expect(
      built.messages.map((m) => m.content),
      isNot(contains('A market at dawn.')),
    );
  });
}
