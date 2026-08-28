import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/services/scenario_codec.dart';

/// The scenario model and the formats it travels in. A scenario is worth nothing
/// unless the text that comes out is the text that went in, so the emphasis here
/// is on [Scenario.appliedOver] — the one piece of logic that decides what the
/// model is actually told — and on round-tripping the two shapes this app reads.
void main() {
  group('the model', () {
    test('an untitled scenario still has something to show', () {
      final s = Scenario(id: 's', text: 'The radio is dead.');
      expect(s.displayName, 'Untitled scenario');
      expect(s.blurb, 'The radio is dead.');
      expect(s.isUsable, isTrue);
    });

    test('whitespace is not a scenario', () {
      final s = Scenario(id: 's', text: '   \n ');
      expect(s.isUsable, isFalse);
      expect(s.blurb, isEmpty);
    });

    test('the blurb is one line, whatever the prompt looks like', () {
      final s = Scenario(id: 's', text: 'Snowed  in.\n\nThe   radio is dead.');
      expect(s.blurb, 'Snowed in. The radio is dead.');
    });

    test('search reaches the title, the tags and the prompt itself', () {
      final s = Scenario(
        id: 's',
        name: 'Snowed in',
        text: 'The radio has been dead since Tuesday.',
        tags: const ['winter'],
      );
      expect(s.matches(''), isTrue);
      expect(s.matches('snowed'), isTrue);
      expect(s.matches('WINTER'), isTrue);
      expect(s.matches('tuesday'), isTrue);
      expect(s.matches('desert'), isFalse);
    });
  });

  group('applied over a card', () {
    Scenario replacing() => Scenario(id: 's', text: 'Mine.');
    Scenario adding() =>
        Scenario(id: 's', text: 'Mine.', overwriteCharacterScenario: false);

    test('replacing sets the card aside', () {
      expect(replacing().appliedOver('Card.'), 'Mine.');
    });

    test('adding keeps the card first, then this', () {
      expect(adding().appliedOver('Card.'), 'Card.\n\nMine.');
    });

    test('adding to nothing is just this', () {
      expect(adding().appliedOver(''), 'Mine.');
      expect(adding().appliedOver('   '), 'Mine.');
    });

    test('an empty scenario changes nothing', () {
      final blank = Scenario(id: 's', text: '  ');
      expect(blank.appliedOver('Card.'), 'Card.');
      expect(
        Scenario(id: 's', text: '', overwriteCharacterScenario: false)
            .appliedOver('Card.'),
        'Card.',
      );
    });
  });

  group('storage', () {
    test('it round-trips through JSON', () {
      final s = Scenario(
        id: 's',
        name: 'Snowed in',
        text: 'The radio is dead.',
        tags: const ['winter', 'slow burn'],
        starred: true,
        overwriteCharacterScenario: false,
        format: ScenarioFormat.agnai,
        extensions: <String, dynamic>{'states': <String>['act1']},
      );
      final back = Scenario.fromJson(s.toJson());
      expect(back.id, 's');
      expect(back.name, 'Snowed in');
      expect(back.text, 'The radio is dead.');
      expect(back.tags, ['winter', 'slow burn']);
      expect(back.starred, isTrue);
      expect(back.overwriteCharacterScenario, isFalse);
      expect(back.format, ScenarioFormat.agnai);
      expect(back.extensions['states'], ['act1']);
    });

    test('an ordinary scenario writes no default keys', () {
      final s = Scenario(id: 's', name: 'A', text: 'B');
      final json = s.toJson();
      expect(json.containsKey('overwriteCharacterScenario'), isFalse);
      expect(json.containsKey('starred'), isFalse);
      expect(json.containsKey('format'), isFalse);
      // …and reads back as the defaults it left out.
      final back = Scenario.fromJson(json);
      expect(back.overwriteCharacterScenario, isTrue);
      expect(back.starred, isFalse);
      expect(back.format, ScenarioFormat.manual);
    });

    test('a copy is a copy — editing one does not touch the other', () {
      final s = Scenario(id: 's', name: 'A', text: 'B', tags: const ['x']);
      final copy = s.copyWith(id: 'other', name: 'C');
      copy.tags.add('y');
      expect(s.tags, ['x']);
      expect(copy.tags, ['x', 'y']);
      expect(s.name, 'A');
      expect(copy.createdAt, s.createdAt);
    });
  });
  group('reading what other apps write', () {
    test("an Agnai scenario keeps its text, its flag and its events", () {
      const agnai = '''
      {
        "kind": "scenario",
        "_id": "abc",
        "userId": "u",
        "name": "The Long Winter",
        "description": "A cold open.",
        "text": "Snowed in at the station.",
        "overwriteCharacterScenario": false,
        "instructions": "Keep it bleak.",
        "states": ["act1"],
        "entries": [
          {"name": "storm", "text": "The wind rises.", "trigger": {"kind": "onGreeting"}}
        ]
      }''';
      final one = ScenarioCodec.parse(agnai).single;
      expect(one.name, 'The Long Winter');
      expect(one.text, 'Snowed in at the station.');
      expect(one.overwriteCharacterScenario, isFalse);
      expect(one.format, ScenarioFormat.agnai);
      // Nothing is thrown away, and the import can say how much did not apply.
      expect(ScenarioCodec.eventCount(one), 1);
      expect(one.extensions['instructions'], 'Keep it bleak.');
      expect(one.extensions['description'], 'A cold open.');
    });

    test('an Agnai scenario exports again unchanged in the parts that matter',
        () {
      const agnai = '{"kind":"scenario","name":"W","text":"T",'
          '"overwriteCharacterScenario":false,"instructions":"I",'
          '"entries":[{"name":"e"}],"states":["s"]}';
      final one = ScenarioCodec.parse(agnai).single;
      final out = jsonDecode(ScenarioCodec.exportAgnai(one))
          as Map<String, dynamic>;
      expect(out['kind'], 'scenario');
      expect(out['name'], 'W');
      expect(out['text'], 'T');
      expect(out['overwriteCharacterScenario'], isFalse);
      expect(out['instructions'], 'I');
      expect((out['entries'] as List).length, 1);
      expect(out['states'], ['s']);
    });

    test('a character card gives up its scenario, named after the card', () {
      const card = '{"spec":"chara_card_v2","spec_version":"2.0","data":'
          '{"name":"Aria","description":"A librarian.",'
          '"scenario":"A rainy night at the archive.","tags":["cosy"]}}';
      final one = ScenarioCodec.parse(card).single;
      expect(one.name, "Aria's scenario");
      expect(one.text, 'A rainy night at the archive.');
      expect(one.tags, ['cosy']);
      expect(one.format, ScenarioFormat.characterCard);
    });

    test('a card with no scenario is not a scenario', () {
      const card = '{"spec":"chara_card_v2","data":{"name":"Aria",'
          '"description":"A librarian."}}';
      expect(() => ScenarioCodec.parse(card), throwsFormatException);
    });

    test('plain prose is taken as the prompt, first line as the title', () {
      final one = ScenarioCodec.parse(
        'Snowed in\nThe radio has been dead since Tuesday.',
      ).single;
      expect(one.name, 'Snowed in');
      expect(one.text, 'The radio has been dead since Tuesday.');
      expect(one.format, ScenarioFormat.plainText);
    });

    test('a single paragraph keeps all of itself and borrows the file name', () {
      final one = ScenarioCodec.parse(
        'The radio has been dead since Tuesday and nobody has come.',
        fileName: 'winter',
      ).single;
      expect(one.name, 'winter');
      expect(one.text, startsWith('The radio has been dead'));
    });

    test('an empty file says so rather than making an empty scenario', () {
      expect(() => ScenarioCodec.parse('   '), throwsFormatException);
    });

    test('an unrelated JSON file is refused', () {
      expect(() => ScenarioCodec.parse('{"unrelated":true}'),
          throwsFormatException);
      expect(() => ScenarioCodec.parse('[]'), throwsFormatException);
    });
  });

  group('this app\'s own shape', () {
    Scenario winter() => Scenario(
          id: 's',
          name: 'Snowed in',
          text: 'The radio is dead.',
          tags: const ['winter'],
          starred: true,
          overwriteCharacterScenario: false,
        );

    test('a native export reads back as what went out', () {
      final back = ScenarioCodec.parse(ScenarioCodec.exportNative(winter()));
      expect(back.length, 1);
      expect(back.single.name, 'Snowed in');
      expect(back.single.text, 'The radio is dead.');
      expect(back.single.tags, ['winter']);
      expect(back.single.starred, isTrue);
      expect(back.single.overwriteCharacterScenario, isFalse);
    });

    test('a multi-selection travels as one file and comes back as many', () {
      final many = [
        winter(),
        Scenario(id: 't', name: 'Heatwave', text: 'The tarmac is soft.'),
      ];
      final back = ScenarioCodec.parse(ScenarioCodec.exportManyNative(many));
      expect(back.map((s) => s.name), ['Snowed in', 'Heatwave']);
      expect(back.map((s) => s.id).toSet().length, 2,
          reason: 'an import is a copy, so ids must not collide');
    });

    test('an import never reuses the id it was given', () {
      final out = ScenarioCodec.exportNative(winter());
      final back = ScenarioCodec.parse(out).single;
      expect(back.id, isNot('s'));
    });
  });
}
