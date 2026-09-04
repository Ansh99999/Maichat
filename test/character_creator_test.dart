import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/character_scenario.dart';
import 'package:maichat/models/character_theme.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/view_prefs.dart';
import 'package:maichat/services/character_codec.dart';
import 'package:maichat/services/lorebook_codec.dart';

/// What Creator v2 added to the *data* — a title, several scenarios each pinned
/// to greetings, attached lorebooks and a theme — has to survive three journeys:
/// a restart (the store), an export somebody else reads (a v2 card), and an
/// export read back here. Nothing here touches the UI; the screens are covered by
/// `character_creator_ui_test.dart`.
void main() {
  group('the new card fields', () {
    test('round trip through the store', () {
      final card = Character(
        id: 'c1',
        name: 'Serina',
        title: 'She was your sister, back then',
        titleShown: true,
        description: 'A retired duellist.',
        firstMes: 'Hello.',
        alternateGreetings: const ['Again?', 'You came.'],
        lorebookIds: const ['book-a', 'book-b'],
        theme: const CharacterTheme(
          seedColor: 0xFF112233,
          strength: CharacterThemeStrength.expressive,
        ),
        scenarios: [
          CharacterScenario(id: 's1', name: 'Funeral', text: 'At the funeral.',
              greetings: const [1]),
          CharacterScenario(id: 's2', text: 'Anywhere.'),
        ],
      );

      final back = Character.fromJson(
        jsonDecode(jsonEncode(card.toJson())) as Map<String, dynamic>,
      );

      expect(back.title, 'She was your sister, back then');
      expect(back.titleShown, isTrue);
      expect(back.hasTitle, isTrue);
      expect(back.lorebookIds, ['book-a', 'book-b']);
      expect(back.theme.seedColor, 0xFF112233);
      expect(back.theme.strength, CharacterThemeStrength.expressive);
      expect(back.scenarios, hasLength(2));
      expect(back.scenarios.first.name, 'Funeral');
      expect(back.scenarios.first.greetings, [1]);
      expect(back.scenarios.last.appliesToAll, isTrue);
    });

    test('a card written before any of this exists reads as plain', () {
      final back = Character.fromJson(<String, dynamic>{
        'id': 'old',
        'name': 'Aria',
        'scenario': 'A library.',
        'firstMes': 'Hello.',
      });

      expect(back.title, isEmpty);
      expect(back.titleShown, isFalse);
      expect(back.hasTitle, isFalse);
      expect(back.scenarios, isEmpty);
      expect(back.lorebookIds, isEmpty);
      expect(back.theme.isSet, isFalse);
      // The single scenario every other app understands is still the one in force.
      expect(back.activeScenario, 'A library.');
    });

    test('a stored title with no switch is shown — somebody wrote it', () {
      final back = Character.fromJson(<String, dynamic>{
        'id': 'x',
        'name': 'Aria',
        'title': 'The last archivist',
      });
      expect(back.titleShown, isTrue);
      expect(back.blurb, 'The last archivist');
    });

    test('the title leads the blurb, and falls back when there is none', () {
      final titled = Character(
        id: 'a',
        name: 'A',
        title: 'A hook',
        titleShown: true,
        creatorNotes: 'Notes about the card.',
      );
      expect(titled.blurb, 'A hook');

      final untitled = Character(
        id: 'b',
        name: 'B',
        title: 'A hook',
        creatorNotes: 'Notes about the card.',
      );
      expect(untitled.blurb, 'Notes about the card.');
    });

    test('clone and copyWith carry every new field', () {
      final card = Character(
        id: 'c',
        name: 'C',
        title: 'T',
        titleShown: true,
        lorebookIds: const ['b'],
        theme: const CharacterTheme(seedColor: 0xFF00FF00),
        scenarios: [CharacterScenario(id: 's', text: 'x', greetings: const [2])],
      );
      final copy = card.clone();
      expect(copy.title, 'T');
      expect(copy.titleShown, isTrue);
      expect(copy.lorebookIds, ['b']);
      expect(copy.theme.seedColor, 0xFF00FF00);
      expect(copy.scenarios.single.greetings, [2]);
      // Deep: editing the copy must not reach the original.
      copy.scenarios.single.greetings.add(3);
      copy.lorebookIds.add('other');
      expect(card.scenarios.single.greetings, [2]);
      expect(card.lorebookIds, ['b']);
    });
  });

  group('greetings are one list', () {
    test('blanks are dropped, in card order', () {
      final card = Character(
        id: 'c',
        name: 'C',
        firstMes: 'First.',
        alternateGreetings: const ['', 'Second.', '   ', 'Third.'],
      );
      expect(card.greetings, ['First.', 'Second.', 'Third.']);
    });

    test('an empty first message shifts the rest down', () {
      final card = Character(
        id: 'c',
        name: 'C',
        alternateGreetings: const ['Only one.'],
      );
      expect(card.greetings, ['Only one.']);
    });
  });

  group('which scenario a greeting gets', () {
    List<CharacterScenario> pair() => [
          CharacterScenario(id: 'a', text: 'Rain.', greetings: const [1]),
          CharacterScenario(id: 'b', text: 'Anywhere.'),
        ];

    test('a scenario naming the greeting beats one covering all of them', () {
      expect(CharacterScenario.resolve(pair(), 1), 'Rain.');
    });

    test('a greeting nobody named falls to the general one', () {
      expect(CharacterScenario.resolve(pair(), 0), 'Anywhere.');
    });

    test('no greeting at all can only use the general one', () {
      expect(CharacterScenario.resolve(pair(), null), 'Anywhere.');
    });

    test('with nothing general, an unnamed greeting gets nothing', () {
      final only = [
        CharacterScenario(id: 'a', text: 'Rain.', greetings: const [1]),
      ];
      expect(CharacterScenario.resolve(only, 0), isEmpty);
      expect(CharacterScenario.resolve(only, 1), 'Rain.');
    });

    test('an empty scenario is not a scenario', () {
      final list = [
        CharacterScenario(id: 'a', text: '   ', greetings: const [0]),
        CharacterScenario(id: 'b', text: 'Real.'),
      ];
      expect(CharacterScenario.resolve(list, 0), 'Real.');
    });

    test('the first of several matching wins — the author\'s order', () {
      final list = [
        CharacterScenario(id: 'a', text: 'One.', greetings: const [0, 1]),
        CharacterScenario(id: 'b', text: 'Two.', greetings: const [1]),
      ];
      expect(CharacterScenario.resolve(list, 1), 'One.');
    });
  });

  group('a card exported with its lorebooks', () {
    Lorebook book({String name = 'Port city', int uid = 0}) => Lorebook(
          id: 'book-$uid',
          name: name,
          description: 'Facts about the port.',
          tags: const ['setting'],
          color: 0xFF445566,
          entries: [
            LorebookEntry(
              uid: uid,
              name: 'The harbour',
              content: 'It never stops raining.',
              keys: const ['harbour', 'port'],
              secondaryKeys: const ['rain'],
              weight: 140,
              priority: 90,
              constant: true,
              position: LorebookPosition.atDepth,
              depth: 6,
              role: LoreRole.user,
            ),
          ],
        );

    test("the first goes out as the spec's character_book", () {
      final card = Character(id: 'c', name: 'Serina', description: 'A duellist.');
      final json = jsonDecode(
        CharacterCodec.exportTavernV2(card, books: [book()]),
      ) as Map<String, dynamic>;

      final data = json['data'] as Map<String, dynamic>;
      final embedded = data['character_book'] as Map<String, dynamic>;
      expect(embedded['name'], 'Port city');
      final entries = embedded['entries'] as List;
      expect(entries, hasLength(1));
      final entry = entries.single as Map<String, dynamic>;
      // The spec's own field names, so SillyTavern and Agnai can read it.
      expect(entry['keys'], ['harbour', 'port']);
      expect(entry['content'], 'It never stops raining.');
      expect(entry['insertion_order'], 140);
      expect(entry['enabled'], isTrue);
    });

    test('and comes back with every knob it left with', () {
      final card = Character(id: 'c', name: 'Serina');
      final text = CharacterCodec.exportTavernV2(card, books: [book()]);
      final bundle = CharacterCodec.parseBundleJson(text);

      expect(bundle.lorebooks, hasLength(1));
      final back = bundle.lorebooks.single;
      expect(back.name, 'Port city');
      expect(back.description, 'Facts about the port.');
      expect(back.tags, ['setting']);
      expect(back.color, 0xFF445566);
      final entry = back.entries.single;
      expect(entry.name, 'The harbour');
      expect(entry.keys, ['harbour', 'port']);
      expect(entry.secondaryKeys, ['rain']);
      expect(entry.weight, 140);
      expect(entry.priority, 90);
      expect(entry.constant, isTrue);
      expect(entry.position, LorebookPosition.atDepth);
      expect(entry.depth, 6);
      expect(entry.role, LoreRole.user);
    });

    test('a second and third book ride along too', () {
      final card = Character(id: 'c', name: 'Serina');
      final text = CharacterCodec.exportTavernV2(card, books: [
        book(name: 'One', uid: 1),
        book(name: 'Two', uid: 2),
        book(name: 'Three', uid: 3),
      ]);
      final bundle = CharacterCodec.parseBundleJson(text);
      expect(
        bundle.lorebooks.map((b) => b.name),
        ['One', 'Two', 'Three'],
      );
      // Fresh ids: importing means adding a copy, never overwriting.
      expect(bundle.lorebooks.map((b) => b.id).toSet(), hasLength(3));
      expect(bundle.lorebooks.map((b) => b.id), isNot(contains('book-1')));
    });

    test('a card with no books exports no character_book', () {
      final json = jsonDecode(
        CharacterCodec.exportTavernV2(Character(id: 'c', name: 'C')),
      ) as Map<String, dynamic>;
      final data = json['data'] as Map<String, dynamic>;
      expect(data.containsKey('character_book'), isFalse);
    });

    test('somebody else\'s card with a character_book still yields it', () {
      final foreign = jsonEncode(<String, dynamic>{
        'spec': 'chara_card_v2',
        'data': <String, dynamic>{
          'name': 'Theirs',
          'description': 'From over there.',
          'character_book': <String, dynamic>{
            'name': 'Their world',
            'entries': [
              <String, dynamic>{
                'keys': ['castle'],
                'content': 'It is cold.',
                'enabled': true,
                'insertion_order': 10,
              },
            ],
          },
        },
      });
      final bundle = CharacterCodec.parseBundleJson(foreign);
      expect(bundle.character.name, 'Theirs');
      expect(bundle.lorebooks.single.entries.single.content, 'It is cold.');
    });
  });

  group('the rest of a v2 card', () {
    test('the title, the scenarios and the theme survive an export', () {
      final card = Character(
        id: 'c',
        name: 'Serina',
        title: 'She was your sister',
        titleShown: true,
        scenario: 'A port city.',
        firstMes: 'Hello.',
        alternateGreetings: const ['Again.'],
        theme: const CharacterTheme(
          seedColor: 0xFF884422,
          strength: CharacterThemeStrength.faithful,
        ),
        scenarios: [
          CharacterScenario(id: 's1', text: 'Rain.', greetings: const [1]),
          CharacterScenario(id: 's2', text: 'A port city.'),
        ],
      );
      final back =
          CharacterCodec.parseBundleJson(CharacterCodec.exportTavernV2(card))
              .character;

      expect(back.title, 'She was your sister');
      expect(back.titleShown, isTrue);
      expect(back.theme.seedColor, 0xFF884422);
      expect(back.theme.strength, CharacterThemeStrength.faithful);
      expect(back.scenarios.map((s) => s.text), ['Rain.', 'A port city.']);
      expect(back.scenarios.first.greetings, [1]);
      // And the plain slot every other app reads still says something sensible.
      expect(back.activeScenario, 'A port city.');
    });

    test('a bulk export can carry each card\'s books', () {
      final one = Character(id: '1', name: 'One', lorebookIds: const ['b1']);
      final two = Character(id: '2', name: 'Two');
      final books = <String, List<Lorebook>>{
        '1': [Lorebook(id: 'b1', name: 'Only mine', entries: [
              LorebookEntry(uid: 0, keys: const ['k'], content: 'v'),
            ])],
      };
      final text = CharacterCodec.exportTavernV2Many(
        [one, two],
        booksOf: (c) => books[c.id] ?? const <Lorebook>[],
      );
      final bundles = CharacterCodec.parseBundles(
        _bytes(text),
      );
      expect(bundles, hasLength(2));
      expect(bundles.first.lorebooks.single.name, 'Only mine');
      expect(bundles.last.lorebooks, isEmpty);
    });

    test('parseCards still hands back plain characters', () {
      final text = CharacterCodec.exportTavernV2(
        Character(id: 'c', name: 'Serina'),
      );
      final cards = CharacterCodec.parseCards(_bytes(text));
      expect(cards.single.name, 'Serina');
    });
  });

  group('the creator preference', () {
    test('defaults to v2 and is not written out at its default', () {
      const prefs = ViewPrefs();
      expect(prefs.creatorVersion, CreatorVersion.v2);
      expect(prefs.toJson().containsKey('creatorVersion'), isFalse);
    });

    test('v1 round trips, and survives beside a layout', () {
      final prefs = const ViewPrefs()
          .withCreatorVersion(CreatorVersion.v1)
          .withLayout(BrowseSection.characters, BrowseLayout.list);
      final back = ViewPrefs.fromJson(
        jsonDecode(jsonEncode(prefs.toJson())) as Map<String, dynamic>,
      );
      expect(back.creatorVersion, CreatorVersion.v1);
      expect(back.layoutFor(BrowseSection.characters), BrowseLayout.list);
      expect(back, prefs);
    });

    test('an unknown stored value falls back to v2', () {
      final back = ViewPrefs.fromJson(<String, dynamic>{
        'creatorVersion': 'v9',
      });
      expect(back.creatorVersion, CreatorVersion.v2);
    });
  });

  group('a lorebook as a character_book', () {
    test('the writer and the reader agree about every field name', () {
      final original = Lorebook(
        id: 'b',
        name: 'World',
        entries: [
          LorebookEntry(
            uid: 3,
            name: 'Fact',
            content: 'True.',
            keys: const ['a'],
            selectiveLogic: SelectiveLogic.andAll,
            probability: 40,
            matchWholeWords: true,
            scanDepth: 12,
            excludeRecursion: true,
            preventRecursion: true,
            delayUntilRecursion: 2,
            group: 'g',
            groupOverride: true,
            groupWeight: 55,
            useGroupScoring: true,
            sticky: 4,
            cooldown: 5,
            delay: 6,
            automationId: 'auto',
          ),
        ],
      );
      final back = LorebookCodec.readBook(
        LorebookCodec.characterBookJson(original),
      );
      final entry = back.entries.single;
      expect(entry.uid, 3);
      expect(entry.selectiveLogic, SelectiveLogic.andAll);
      expect(entry.probability, 40);
      expect(entry.matchWholeWords, isTrue);
      expect(entry.scanDepth, 12);
      expect(entry.excludeRecursion, isTrue);
      expect(entry.preventRecursion, isTrue);
      expect(entry.delayUntilRecursion, 2);
      expect(entry.group, 'g');
      expect(entry.groupOverride, isTrue);
      expect(entry.groupWeight, 55);
      expect(entry.useGroupScoring, isTrue);
      expect(entry.sticky, 4);
      expect(entry.cooldown, 5);
      expect(entry.delay, 6);
      expect(entry.automationId, 'auto');
    });
  });
}

/// The bytes of [text], as the file importers see them.
Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));
