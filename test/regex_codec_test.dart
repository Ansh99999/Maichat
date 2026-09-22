import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/regex_rule.dart';
import 'package:maichat/services/regex_codec.dart';

void main() {
  group('parseRegexRules', () {
    test('reads a single SillyTavern rule object', () {
      const json = '''
      {
        "id": "abc",
        "scriptName": "Trim OOC",
        "findRegex": "/\\\\(OOC:[^)]*\\\\)/g",
        "replaceString": "",
        "trimStrings": [],
        "placement": [2],
        "disabled": false,
        "markdownOnly": false,
        "promptOnly": true,
        "runOnEdit": true,
        "substituteRegex": 0
      }''';
      final rules = parseRegexRules(json);
      expect(rules, hasLength(1));
      expect(rules.first.name, 'Trim OOC');
      expect(rules.first.promptOnly, isTrue);
      expect(rules.first.actsOn(RegexTarget.aiOutput), isTrue);
      expect(rules.first.mode, RegexMode.promptOnly);
    });

    test('reads an array of rules', () {
      const json = '[{"findRegex":"a"},{"findRegex":"b"}]';
      expect(parseRegexRules(json), hasLength(2));
    });

    test('reads rules wrapped under regex_scripts (card/preset extensions)', () {
      const json = '{"regex_scripts":[{"findRegex":"a"},{"findRegex":"b"}]}';
      expect(parseRegexRules(json), hasLength(2));
    });

    test('ignores objects that do not look like a rule', () {
      expect(parseRegexRules('{"foo":"bar"}'), isEmpty);
    });

    test('returns empty on invalid JSON rather than throwing', () {
      expect(parseRegexRules('not json'), isEmpty);
    });
  });

  group('encode / round-trip', () {
    test('a rule survives encode then parse unchanged', () {
      final original = RegexRule(
        id: 'x',
        name: 'Italicise actions',
        find: r'/\*(.*?)\*/g',
        replace: r'<i>$1</i>',
        trimStrings: ['foo', 'bar'],
        placement: [RegexTarget.aiOutput.code, RegexTarget.userInput.code],
        markdownOnly: true,
        macroMode: RegexMacroMode.raw,
        minDepth: 1,
        maxDepth: 4,
      );
      final restored = parseRegexRules(encodeRegexRule(original)).single;
      expect(restored.name, original.name);
      expect(restored.find, original.find);
      expect(restored.replace, original.replace);
      expect(restored.trimStrings, original.trimStrings);
      expect(restored.placement, original.placement);
      expect(restored.markdownOnly, isTrue);
      expect(restored.macroMode, RegexMacroMode.raw);
      expect(restored.minDepth, 1);
      expect(restored.maxDepth, 4);
    });

    test('encodeRegexRules writes an array both apps accept', () {
      final list = [RegexRule.create(name: 'a'), RegexRule.create(name: 'b')];
      // Give them a find so the sniff accepts them back.
      for (final r in list) {
        r.find = 'x';
      }
      final restored = parseRegexRules(encodeRegexRules(list));
      expect(restored.map((r) => r.name), ['a', 'b']);
    });
  });

  group('regexFileName', () {
    test('sanitises the rule name into a file name', () {
      final r = RegexRule.create(name: 'Trim / OOC: notes!');
      expect(regexFileName(r), startsWith('regex-'));
      expect(regexFileName(r), endsWith('.json'));
      expect(regexFileName(r), isNot(contains('/')));
    });

    test('falls back when the name is empty', () {
      expect(regexFileName(RegexRule.create()), 'regex-Untitled-rule.json');
    });
  });

  group('RegexRule mode / targets', () {
    test('mode maps to the two ephemerality flags', () {
      final r = RegexRule.create();
      r.mode = RegexMode.displayOnly;
      expect(r.markdownOnly, isTrue);
      expect(r.promptOnly, isFalse);
      r.mode = RegexMode.promptOnly;
      expect(r.markdownOnly, isFalse);
      expect(r.promptOnly, isTrue);
      r.mode = RegexMode.permanent;
      expect(r.markdownOnly, isFalse);
      expect(r.promptOnly, isFalse);
    });

    test('setTarget toggles a placement without duplicating', () {
      final r = RegexRule.create();
      r.setTarget(RegexTarget.userInput, true);
      r.setTarget(RegexTarget.userInput, true);
      expect(r.placement.where((c) => c == RegexTarget.userInput.code), hasLength(1));
      r.setTarget(RegexTarget.userInput, false);
      expect(r.actsOn(RegexTarget.userInput), isFalse);
    });
  });
}
