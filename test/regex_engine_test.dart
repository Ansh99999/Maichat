import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/regex_rule.dart';
import 'package:maichat/services/regex_engine.dart';

RegexRule rule({
  String find = '',
  String replace = '',
  List<String>? trim,
  List<int>? placement,
  bool disabled = false,
  bool markdownOnly = false,
  bool promptOnly = false,
  bool runOnEdit = true,
  RegexMacroMode macroMode = RegexMacroMode.none,
  int? minDepth,
  int? maxDepth,
}) =>
    RegexRule(
      id: 'r',
      find: find,
      replace: replace,
      trimStrings: trim,
      placement: placement ?? [RegexTarget.aiOutput.code],
      disabled: disabled,
      markdownOnly: markdownOnly,
      promptOnly: promptOnly,
      runOnEdit: runOnEdit,
      macroMode: macroMode,
      minDepth: minDepth,
      maxDepth: maxDepth,
    );

void main() {
  setUp(RegexEngine.clearCache);

  group('runRule — patterns and flags', () {
    test('bare pattern replaces the first match only (no global flag)', () {
      expect(RegexEngine.runRule(rule(find: 'a', replace: 'X'), 'banana'),
          'bXnana');
    });

    test('the global flag replaces every match', () {
      expect(RegexEngine.runRule(rule(find: '/a/g', replace: 'X'), 'banana'),
          'bXnXnX');
    });

    test('the ignore-case flag matches regardless of case', () {
      expect(
          RegexEngine.runRule(rule(find: '/hello/gi', replace: 'hi'),
              'Hello HELLO hello'),
          'hi hi hi');
    });

    test('the dotAll flag lets . cross newlines', () {
      expect(
          RegexEngine.runRule(
              rule(find: '/a.b/s', replace: 'X'), 'a\nb'),
          'X');
    });

    test('an invalid pattern leaves the text untouched', () {
      expect(RegexEngine.runRule(rule(find: '(', replace: 'X'), 'abc'), 'abc');
    });

    test('an empty find is a no-op', () {
      expect(RegexEngine.runRule(rule(find: '', replace: 'X'), 'abc'), 'abc');
    });
  });

  group('runRule — replacement tokens', () {
    test(r'$1 reuses a numbered capture group', () {
      expect(
          RegexEngine.runRule(
              rule(find: r'/(\w+)@(\w+)/g', replace: r'$2 dot $1'),
              'user@host'),
          'host dot user');
    });

    test(r'{{match}} is an alias for the whole match', () {
      expect(
          RegexEngine.runRule(
              rule(find: '/cat/g', replace: '[{{match}}]'), 'a cat'),
          'a [cat]');
    });

    test(r'$<name> reuses a named capture group', () {
      expect(
          RegexEngine.runRule(
              rule(find: r'/(?<who>\w+) said/g', replace: r'$<who>:'),
              'Bob said'),
          'Bob:');
    });

    test('an empty replacement deletes the match', () {
      expect(
          RegexEngine.runRule(
              rule(find: '/\\s*\\(OOC:[^)]*\\)/g', replace: ''),
              'Sure (OOC: note) done'),
          'Sure done');
    });
  });

  group('runRule — trim and macros', () {
    test('trim strings are stripped from a match before it is reused', () {
      expect(
          RegexEngine.runRule(
            rule(find: r'/<b>(.*?)<\/b>/g', replace: r'**$1**', trim: ['<i>', '</i>']),
            '<b>a<i>b</i>c</b>',
          ),
          '**abc**');
    });

    test('{{user}} and {{char}} resolve in the replacement', () {
      expect(
          RegexEngine.runRule(
            rule(find: '/NAME/g', replace: '{{char}}'),
            'NAME waves',
            charName: 'Aria',
            userName: 'You',
          ),
          'Aria waves');
    });

    test('escaped macro mode escapes regex specials in the find', () {
      // The character name contains a regex-special char; escaped mode should
      // match it literally rather than as a group.
      expect(
          RegexEngine.runRule(
            rule(find: '{{char}}', replace: 'X', macroMode: RegexMacroMode.escaped),
            'a+b here',
            charName: 'a+b',
          ),
          'X here');
    });
  });

  group('apply — mode gating', () {
    final permanent = rule(find: '/x/g', replace: 'P');
    final display = rule(find: '/x/g', replace: 'D', markdownOnly: true);
    final prompt = rule(find: '/x/g', replace: 'R', promptOnly: true);
    final rules = [permanent, display, prompt];

    test('a permanent call runs only permanent rules', () {
      expect(RegexEngine.apply(rules, 'x', target: RegexTarget.aiOutput), 'P');
    });

    test('a display call runs only display rules', () {
      expect(
          RegexEngine.apply(rules, 'x',
              target: RegexTarget.aiOutput, isDisplay: true),
          'D');
    });

    test('a prompt call runs only prompt rules', () {
      expect(
          RegexEngine.apply(rules, 'x',
              target: RegexTarget.aiOutput, isPrompt: true),
          'R');
    });

    test('a disabled rule never runs', () {
      final off = rule(find: '/x/g', replace: 'P', disabled: true);
      expect(RegexEngine.apply([off], 'x', target: RegexTarget.aiOutput), 'x');
    });

    test('a rule only touches the target it is aimed at', () {
      final aiOnly = rule(find: '/x/g', replace: 'P');
      expect(
          RegexEngine.apply([aiOnly], 'x', target: RegexTarget.userInput), 'x');
    });
  });

  group('apply — edit and depth gating', () {
    test('a rule that does not run on edit is skipped on an edit pass', () {
      final r = rule(find: '/x/g', replace: 'P', runOnEdit: false);
      expect(
          RegexEngine.apply([r], 'x', target: RegexTarget.aiOutput, isEdit: true),
          'x');
      expect(RegexEngine.apply([r], 'x', target: RegexTarget.aiOutput), 'P');
    });

    test('minDepth keeps a rule off messages nearer than the window', () {
      final r = rule(find: '/x/g', replace: 'P', minDepth: 2);
      expect(
          RegexEngine.apply([r], 'x', target: RegexTarget.aiOutput, depth: 0),
          'x');
      expect(
          RegexEngine.apply([r], 'x', target: RegexTarget.aiOutput, depth: 3),
          'P');
    });

    test('maxDepth keeps a rule off messages deeper than the window', () {
      final r = rule(find: '/x/g', replace: 'P', maxDepth: 1);
      expect(
          RegexEngine.apply([r], 'x', target: RegexTarget.aiOutput, depth: 5),
          'x');
      expect(
          RegexEngine.apply([r], 'x', target: RegexTarget.aiOutput, depth: 0),
          'P');
    });
  });

  group('apply — order', () {
    test('rules run in order, each feeding the next', () {
      final first = rule(find: '/a/g', replace: 'b');
      final second = rule(find: '/b/g', replace: 'c');
      expect(
          RegexEngine.apply([first, second], 'a', target: RegexTarget.aiOutput),
          'c');
    });
  });

  group('hasWork', () {
    test('is false when no enabled rule targets the placement', () {
      expect(
          RegexEngine.hasWork([rule(find: '/x/g', replace: 'P')],
              target: RegexTarget.userInput),
          isFalse);
    });

    test('is true when a matching enabled rule exists', () {
      expect(
          RegexEngine.hasWork([rule(find: '/x/g', replace: 'P')],
              target: RegexTarget.aiOutput),
          isTrue);
    });
  });
}
