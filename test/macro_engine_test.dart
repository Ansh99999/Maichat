import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/macro_context.dart';
import 'package:maichat/services/macro_engine.dart';

/// Builds a [MacroContext] with a representative character and chat so the
/// tests can exercise every macro category against real data.
MacroContext buildContext({
  String userName = 'Alex',
  String charName = 'Lana',
  List<ChatMessage>? messages,
  MacroVariables? variables,
  Map<String, String Function()>? dynamicMacros,
  DateTime? lastUserActivity,
}) {
  final character = Character(
    id: 'c1',
    name: 'Lana',
    description: 'A curious explorer.',
    personality: 'Bold and witty.',
    scenario: 'Aboard a drifting station.',
    firstMes: 'Greetings, traveller.',
    alternateGreetings: ['Alt one.', 'Alt two.'],
    mesExample: '<START>\nExample line.',
    systemPrompt: 'You are Lana.',
    postHistoryInstructions: 'Stay in character.',
    creatorNotes: 'Made with care.',
    characterVersion: '1.2.0',
  );
  return MacroContext(
    userName: userName,
    charName: charName,
    character: character,
    messages: messages ??
        [
          ChatMessage(role: 'user', content: 'first user line'),
          ChatMessage(role: 'assistant', content: 'first char line'),
          ChatMessage(role: 'user', content: 'second user line'),
        ],
    model: 'gpt-test',
    maxContext: 8192,
    maxResponse: 512,
    maxPrompt: 7680,
    input: 'typed text',
    generationType: 'normal',
    isMobile: true,
    lastUserActivity: lastUserActivity,
    variables: variables,
    dynamicMacros: dynamicMacros,
  );
}

void main() {
  const engine = DefaultMacroEngine();
  String run(String text, [MacroContext? ctx]) =>
      engine.evaluate(text, ctx ?? buildContext());

  group('identity + legacy angle brackets', () {
    test('user and char resolve to names', () {
      expect(run('{{user}} meets {{char}}'), 'Alex meets Lana');
    });

    test('case-insensitive names', () {
      expect(run('{{USER}} and {{Char}}'), 'Alex and Lana');
    });

    test('group family collapses to the character in solo chats', () {
      expect(run('{{group}}/{{charIfNotGroup}}/{{groupNotMuted}}/{{notChar}}'),
          'Lana/Lana/Lana/Lana');
    });

    test('legacy angle-bracket tokens are rewritten', () {
      expect(run('<USER> / <BOT> / <CHAR> / <GROUP> / <CHARIFNOTGROUP>'),
          'Alex / Lana / Lana / Lana / Lana');
    });
  });

  group('card fields', () {
    test('card accessors and aliases', () {
      expect(run('{{description}}'), 'A curious explorer.');
      expect(run('{{charDescription}}'), 'A curious explorer.');
      expect(run('{{personality}}'), 'Bold and witty.');
      expect(run('{{scenario}}'), 'Aboard a drifting station.');
      expect(run('{{charPrompt}}'), 'You are Lana.');
      expect(run('{{charInstruction}}'), 'Stay in character.');
      expect(run('{{charJailbreak}}'), 'Stay in character.');
      expect(run('{{creatorNotes}}'), 'Made with care.');
      expect(run('{{charVersion}}/{{version}}/{{char_version}}'),
          '1.2.0/1.2.0/1.2.0');
      expect(run('{{persona}}|{{charDepthPrompt}}|{{original}}'), '||');
    });

    test('greeting resolves by index', () {
      expect(run('{{greeting}}'), 'Greetings, traveller.');
      expect(run('{{greeting::0}}'), 'Greetings, traveller.');
      expect(run('{{greeting::1}}'), 'Alt one.');
      expect(run('{{greeting::2}}'), 'Alt two.');
      expect(run('{{greeting::5}}'), '');
    });
  });

  group('chat + state', () {
    test('chat inspection macros', () {
      expect(run('{{lastMessage}}'), 'second user line');
      expect(run('{{lastMessageId}}'), '2');
      expect(run('{{lastUserMessage}}'), 'second user line');
      expect(run('{{lastCharMessage}}'), 'first char line');
      expect(run('{{allChatRange}}'), '0-2');
      expect(run('{{lastSwipeId}}/{{currentSwipeId}}'), '1/1');
    });

    test('empty chat yields empty range and ids', () {
      final ctx = buildContext(messages: []);
      expect(run('{{allChatRange}}', ctx), '');
      expect(run('{{lastMessageId}}', ctx), '');
      expect(run('{{lastMessage}}', ctx), '');
    });

    test('limits, model, device, generation type', () {
      expect(run('{{maxPrompt}}/{{maxPromptTokens}}'), '7680/7680');
      expect(run('{{maxContext}}/{{maxContextTokens}}'), '8192/8192');
      expect(run('{{maxResponse}}/{{maxResponseTokens}}'), '512/512');
      expect(run('{{model}}'), 'gpt-test');
      expect(run('{{isMobile}}'), 'true');
      expect(run('{{lastGenerationType}}'), 'normal');
      expect(run('{{hasExtension::foo}}'), 'false');
    });
  });

  group('recursive nesting', () {
    test('inner macros resolve before outer', () {
      final ctx = buildContext();
      // Roll into a variable, then read it back.
      run('{{setvar::x::{{roll::1d6}}}}', ctx);
      final value = int.parse(run('{{getvar::x}}', ctx));
      expect(value, inInclusiveRange(1, 6));
    });

    test('nested identity inside argument', () {
      final ctx = buildContext();
      run('{{setvar::who::{{char}}}}', ctx);
      expect(run('{{getvar::who}}', ctx), 'Lana');
    });
  });

  group('conditionals', () {
    test('truthy branch with card-field condition', () {
      expect(run('{{if description}}has desc{{/if}}'), 'has desc');
    });

    test('if/else picks the else branch when falsy', () {
      final ctx = buildContext();
      expect(run('{{if {{getvar::missing}}}}yes{{else}}no{{/if}}', ctx), 'no');
    });

    test('inline if with content argument', () {
      final ctx = buildContext();
      run('{{setvar::flag::on}}', ctx);
      expect(run('{{if {{getvar::flag}}::shown}}', ctx), 'shown');
    });

    test('inverted condition', () {
      final ctx = buildContext();
      expect(run('{{if !{{getvar::nope}}}}empty{{/if}}', ctx), 'empty');
    });

    test('condition reads a local var shorthand', () {
      final ctx = buildContext();
      run('{{setvar::ready::true}}', ctx);
      expect(run('{{if .ready}}go{{else}}wait{{/if}}', ctx), 'go');
    });

    test('falsy literals are treated as false', () {
      expect(run('{{if 0}}a{{else}}b{{/if}}'), 'b');
      expect(run('{{if off}}a{{else}}b{{/if}}'), 'b');
      expect(run('{{if false}}a{{else}}b{{/if}}'), 'b');
    });
  });

  group('variables', () {
    test('set/get local and global are independent', () {
      final ctx = buildContext();
      run('{{setvar::n::hi}}{{setglobalvar::n::bye}}', ctx);
      expect(run('{{getvar::n}}', ctx), 'hi');
      expect(run('{{getglobalvar::n}}', ctx), 'bye');
    });

    test('setvar/getvar return values', () {
      final ctx = buildContext();
      expect(run('{{setvar::a::5}}', ctx), '');
      expect(run('{{getvar::a}}', ctx), '5');
    });

    test('addvar numeric vs string', () {
      final ctx = buildContext();
      run('{{setvar::num::3}}', ctx);
      run('{{addvar::num::4}}', ctx);
      expect(run('{{getvar::num}}', ctx), '7');
      run('{{setvar::str::foo}}', ctx);
      run('{{addvar::str::bar}}', ctx);
      expect(run('{{getvar::str}}', ctx), 'foobar');
    });

    test('inc/dec return new value', () {
      final ctx = buildContext();
      run('{{setvar::c::10}}', ctx);
      expect(run('{{incvar::c}}', ctx), '11');
      expect(run('{{decvar::c}}', ctx), '10');
    });

    test('has and delete', () {
      final ctx = buildContext();
      run('{{setvar::k::v}}', ctx);
      expect(run('{{hasvar::k}}', ctx), 'true');
      expect(run('{{varexists::k}}', ctx), 'true');
      run('{{deletevar::k}}', ctx);
      expect(run('{{hasvar::k}}', ctx), 'false');
    });

    test('missing var reads as empty', () {
      expect(run('{{getvar::ghost}}'), '');
    });
  });

  group('variable DSL', () {
    test('assignment, read, and compound ops', () {
      final ctx = buildContext();
      expect(run('{{.count = 5}}', ctx), '');
      expect(run('{{.count}}', ctx), '5');
      expect(run('{{.count += 3}}', ctx), '');
      expect(run('{{.count}}', ctx), '8');
      expect(run('{{.count -= 2}}', ctx), '');
      expect(run('{{.count}}', ctx), '6');
      expect(run('{{.count++}}', ctx), '7');
      expect(run('{{.count--}}', ctx), '6');
    });

    test('global scope with dollar prefix', () {
      final ctx = buildContext();
      run('{{\$g = hello}}', ctx);
      expect(run('{{\$g}}', ctx), 'hello');
      expect(ctx.variables.global['g'], 'hello');
    });

    test('string equality and numeric comparison', () {
      final ctx = buildContext();
      run('{{.v = 7}}', ctx);
      expect(run('{{.v == 7}}', ctx), 'true');
      expect(run('{{.v != 9}}', ctx), 'true');
      expect(run('{{.v > 3}}', ctx), 'true');
      expect(run('{{.v <= 6}}', ctx), 'false');
    });

    test('logical or and nullish coalescing', () {
      final ctx = buildContext();
      expect(run('{{.miss || fallback}}', ctx), 'fallback');
      run('{{.set = value}}', ctx);
      expect(run('{{.set || other}}', ctx), 'value');
      expect(run('{{.newkey ??= created}}', ctx), 'created');
      expect(run('{{.newkey}}', ctx), 'created');
    });
  });

  group('randomness', () {
    test('roll stays within bounds', () {
      for (var i = 0; i < 50; i++) {
        final v = int.parse(run('{{roll::2d6}}'));
        expect(v, inInclusiveRange(2, 12));
      }
      expect(run('{{roll::1d1}}'), '1');
    });

    test('bare integer roll is treated as 1dN', () {
      for (var i = 0; i < 50; i++) {
        expect(int.parse(run('{{roll::6}}')), inInclusiveRange(1, 6));
      }
    });

    test('roll accepts space and single-colon syntax', () {
      expect(int.parse(run('{{roll 1d4}}')), inInclusiveRange(1, 4));
      expect(int.parse(run('{{roll:1d4}}')), inInclusiveRange(1, 4));
    });

    test('random picks a member of the list', () {
      for (var i = 0; i < 20; i++) {
        expect(['a', 'b', 'c'], contains(run('{{random::a::b::c}}')));
      }
    });

    test('random supports comma syntax', () {
      for (var i = 0; i < 20; i++) {
        expect(['x', 'y'], contains(run('{{random:x,y}}')));
      }
    });

    test('pick is stable for identical input', () {
      final first = run('{{pick::red::green::blue}}');
      final second = run('{{pick::red::green::blue}}');
      expect(first, second);
      expect(['red', 'green', 'blue'], contains(first));
    });
  });

  group('time', () {
    test('format sanity', () {
      expect(run('{{isotime}}'), matches(r'^\d{2}:\d{2}$'));
      expect(run('{{isodate}}'), matches(r'^\d{4}-\d{2}-\d{2}$'));
      expect(run('{{time}}'), matches(r'^\d{1,2}:\d{2} (AM|PM)$'));
      expect(run('{{time::UTC+2}}'), matches(r'^\d{1,2}:\d{2} (AM|PM)$'));
      expect(run('{{time_UTC-7}}'), matches(r'^\d{1,2}:\d{2} (AM|PM)$'));
      expect(run('{{datetimeformat::YYYY-MM-DD}}'),
          matches(r'^\d{4}-\d{2}-\d{2}$'));
      expect(
          [
            'Monday', 'Tuesday', 'Wednesday', 'Thursday',
            'Friday', 'Saturday', 'Sunday',
          ],
          contains(run('{{weekday}}')));
    });

    test('idle duration humanizes elapsed time', () {
      final ctx = buildContext(
        lastUserActivity: DateTime.now().subtract(const Duration(minutes: 5)),
      );
      expect(run('{{idle_duration}}', ctx), '5 minutes');
      expect(run('{{idleDuration}}', buildContext()), 'just now');
    });

    test('timeDiff is humanized with direction', () {
      expect(
          run('{{timeDiff::2023-01-01T15:00:00::2023-01-01T12:00:00}}'),
          'in 3 hours');
      expect(
          run('{{timeDiff::2023-01-01T12:00:00::2023-01-01T15:00:00}}'),
          '3 hours ago');
    });
  });

  group('utility, escaping, and unknowns', () {
    test('newline and space with counts', () {
      expect(run('a{{newline}}b'), 'a\nb');
      expect(run('a{{newline::2}}b'), 'a\n\nb');
      expect(run('a{{space::3}}b'), 'a   b');
    });

    test('reverse, noop, input', () {
      expect(run('{{reverse::abc}}'), 'cba');
      expect(run('x{{noop}}y'), 'xy');
      expect(run('{{input}}'), 'typed text');
    });

    test('banned and outlet resolve to empty', () {
      expect(run('{{banned::delve}}[{{outlet::key}}]'), '[]');
    });

    test('escaped braces stay literal', () {
      expect(run(r'\{\{not a macro\}\}'), '{{not a macro}}');
    });

    test('unknown macro is left literal with inner resolved', () {
      expect(run('{{totallyUnknown}}'), '{{totallyUnknown}}');
      expect(run('{{mystery::{{char}}}}'), '{{mystery::Lana}}');
    });

    test('comments are removed', () {
      expect(run('a{{// hidden}}b'), 'ab');
      expect(run('a{{comment}}b'), 'ab');
    });

    test('scoped trim collapses whitespace', () {
      expect(run('{{trim}}   hello   {{/trim}}'), 'hello');
    });

    test('non-scoped trim removes surrounding newlines', () {
      expect(run('a\n{{trim}}\nb'), 'ab');
    });

    test('instruct and system macros resolve to empty', () {
      expect(run('[{{instructInput}}][{{systemPrompt}}][{{chatStart}}]'),
          '[][][]');
    });

    test('dynamic macros take precedence for bare names', () {
      final ctx = buildContext(dynamicMacros: {'today': () => 'Friday'});
      expect(run('{{today}}', ctx), 'Friday');
    });
  });
}
