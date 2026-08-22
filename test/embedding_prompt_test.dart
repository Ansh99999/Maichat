import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/services/macro_context.dart';
import 'package:maichat/services/prompt_builder.dart';

/// Minimal macro engine (mirrors prompt_builder_test) so these stay independent
/// of the real engine.
class _FakeMacros implements MacroEngine {
  @override
  String evaluate(String text, MacroContext ctx) => text
      .replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), ctx.charName)
      .replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), ctx.userName);
}

List<ChatMessage> _history(int n) => [
      for (var i = 0; i < n; i++)
        ChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'turn $i'),
    ];

void main() {
  final builder = PromptBuilder(macros: _FakeMacros());

  test('recalled memory and documents are injected at depth as a user turn',
      () {
    final built = builder.build(
      preset: Preset.create(),
      character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
      history: _history(6),
      memoryText: 'Past events:\nRECALLEDMEMORY',
      docsText: 'Related information:\nRELATEDDOC',
      memoryDepth: 2,
    );

    // The injected memory reaches the wire...
    final all = built.messages.map((m) => m.content).join('\n');
    expect(all, contains('RECALLEDMEMORY'));
    expect(all, contains('RELATEDDOC'));

    // ...as user turns, never as extra system messages: exactly one system
    // message, at position 0 (the one-leading-system invariant).
    final systems = built.messages.where((m) => m.role == 'system').toList();
    expect(systems.length, 1);
    expect(built.messages.first.role, 'system');
    expect(built.messages.first.content, isNot(contains('RECALLEDMEMORY')));

    // The memory rode in on a user turn.
    final carrier =
        built.messages.firstWhere((m) => m.content.contains('RECALLEDMEMORY'));
    expect(carrier.role, 'user');
  });

  test('no memory text means no injection', () {
    final built = builder.build(
      preset: Preset.create(),
      character: Character(id: 'a', name: 'Alice'),
      history: _history(4),
    );
    expect(built.messages.where((m) => m.role == 'system').length, 1);
    expect(built.messages.map((m) => m.content).join(),
        isNot(contains('RECALLEDMEMORY')));
  });
}
