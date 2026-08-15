import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/services/lorebook_codec.dart';

/// A SillyTavern world-info file: `entries` keyed by entry id, the name in
/// `comment`, the switch inverted in `disable`.
String _sillyTavernWorld() => jsonEncode({
      'entries': {
        '0': {
          'uid': 0,
          'key': ['dragon', 'wyrm'],
          'keysecondary': ['fire'],
          'comment': 'Dragons',
          'content': 'Dragons hoard gold.',
          'constant': false,
          'selective': true,
          'selectiveLogic': 0,
          'order': 42,
          'position': 1,
          'disable': false,
          'depth': 6,
          'role': 1,
          'probability': 80,
          'useProbability': true,
          'caseSensitive': true,
          'matchWholeWords': false,
          'scanDepth': 3,
          'excludeRecursion': true,
          'preventRecursion': true,
          'group': 'beasts',
          'groupWeight': 25,
          'automationId': 'qr-dragons',
        },
        '7': {
          'uid': 7,
          'key': ['castle'],
          'comment': 'Castle',
          'content': 'The castle is ruined.',
          'order': 5,
          'disable': true,
        },
      },
    });

/// An Agnai memory book: entries are a list, the text is `entry`, the keys
/// `keywords`, and the discard priority is separate from the ordering weight.
String _agnaiBook() => jsonEncode({
      'kind': 'memory',
      'name': 'Kingdom',
      'description': 'Facts about the kingdom.',
      'entries': [
        {
          'name': 'Capital',
          'entry': 'The capital is Valeport.',
          'keywords': ['capital', 'valeport'],
          'priority': 30,
          'weight': 70,
          'enabled': true,
        },
        {
          'name': 'Off',
          'entry': 'Unused.',
          'keywords': ['nothing'],
          'priority': 0,
          'weight': 0,
          'enabled': false,
        },
      ],
    });

/// A V2 character card carrying a `character_book`: a list of entries with the
/// spec's snake_case names, everything SillyTavern-only inside `extensions`.
String _characterCard() => jsonEncode({
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': {
        'name': 'Mira',
        'character_book': {
          'name': '',
          'scan_depth': 4,
          'token_budget': 700,
          'recursive_scanning': true,
          'entries': [
            {
              'id': 3,
              'keys': ['harbour'],
              'secondary_keys': ['ship'],
              'comment': 'Harbour',
              'content': 'The harbour never sleeps.',
              'enabled': true,
              'insertion_order': 12,
              'priority': 55,
              'position': 'before_char',
              'case_sensitive': false,
              'extensions': {'depth': 2, 'role': 2, 'prevent_recursion': true},
            },
          ],
        },
      },
    });

void main() {
  group('SillyTavern world info', () {
    test('reads every field, inverting the switch', () {
      final book = LorebookCodec.parse(_sillyTavernWorld(),
          fileName: 'Fantasy')
          .single;

      expect(book.name, 'Fantasy'); // the file is the name
      expect(book.format, LorebookFormat.sillyTavern);
      expect(book.entries, hasLength(2));

      final dragons = book.entries.first;
      expect(dragons.uid, 0);
      expect(dragons.name, 'Dragons');
      expect(dragons.content, 'Dragons hoard gold.');
      expect(dragons.keys, ['dragon', 'wyrm']);
      expect(dragons.secondaryKeys, ['fire']);
      expect(dragons.enabled, isTrue);
      expect(dragons.weight, 42);
      // World info has one ordering knob, so it stands for both of ours.
      expect(dragons.priority, 42);
      expect(dragons.position, LorebookPosition.afterChar);
      expect(dragons.depth, 6);
      expect(dragons.role, LoreRole.user);
      expect(dragons.probability, 80);
      expect(dragons.caseSensitive, isTrue);
      expect(dragons.matchWholeWords, isFalse);
      expect(dragons.scanDepth, 3);
      expect(dragons.excludeRecursion, isTrue);
      expect(dragons.preventRecursion, isTrue);
      expect(dragons.group, 'beasts');
      expect(dragons.groupWeight, 25);
      expect(dragons.automationId, 'qr-dragons');

      // `disable: true` means switched off.
      expect(book.entries[1].uid, 7);
      expect(book.entries[1].enabled, isFalse);
    });

    test('exports as the one shape both ecosystems read', () {
      final book = LorebookCodec.parse(_sillyTavernWorld(), fileName: 'F').single;
      final json =
          jsonDecode(LorebookCodec.exportSillyTavern(book)) as Map<String, dynamic>;

      // Agnai only recognises a SillyTavern export when `entries` is the sole
      // top-level key, and SillyTavern is happy with that too.
      expect(json.keys, ['entries']);
      final entries = json['entries'] as Map<String, dynamic>;
      expect(entries.keys, containsAll(<String>['0', '7']));
      final first = entries['0'] as Map<String, dynamic>;
      expect(first['comment'], 'Dragons');
      expect(first['key'], ['dragon', 'wyrm']);
      expect(first['order'], 42);
      expect(first['disable'], isFalse);
      expect((entries['7'] as Map<String, dynamic>)['disable'], isTrue);
    });
  });

  group('Agnai memory book', () {
    test('reads the separate priority and weight', () {
      final book = LorebookCodec.parse(_agnaiBook()).single;
      expect(book.name, 'Kingdom');
      expect(book.description, 'Facts about the kingdom.');
      expect(book.format, LorebookFormat.agnai);
      expect(book.entries, hasLength(2));

      final capital = book.entries.first;
      expect(capital.name, 'Capital');
      expect(capital.content, 'The capital is Valeport.');
      expect(capital.keys, ['capital', 'valeport']);
      expect(capital.priority, 30);
      expect(capital.weight, 70);
      expect(book.entries[1].enabled, isFalse);
    });

    test('exports the six fields Agnai validates on every entry', () {
      final book = LorebookCodec.parse(_agnaiBook()).single;
      final json = jsonDecode(LorebookCodec.exportAgnai(book)) as Map<String, dynamic>;
      expect(json['kind'], 'memory');
      expect(json['name'], 'Kingdom');
      final entries = json['entries'] as List;
      expect(entries, hasLength(2));
      for (final entry in entries.cast<Map<String, dynamic>>()) {
        expect(
          entry.keys,
          containsAll(
              <String>['name', 'entry', 'keywords', 'priority', 'weight', 'enabled']),
        );
      }
      expect((entries.first as Map)['entry'], 'The capital is Valeport.');
    });
  });

  group("a character card's book", () {
    test('is read out of the card, named after its owner', () {
      final book = LorebookCodec.parse(_characterCard()).single;
      expect(book.name, "Mira's lorebook");
      expect(book.format, LorebookFormat.characterCard);
      expect(book.scanDepth, 4);
      expect(book.tokenBudget, 700);
      expect(book.recursive, isTrue);

      final entry = book.entries.single;
      expect(entry.uid, 3);
      expect(entry.name, 'Harbour');
      expect(entry.keys, ['harbour']);
      expect(entry.secondaryKeys, ['ship']);
      expect(entry.weight, 12);
      expect(entry.priority, 55);
      expect(entry.position, LorebookPosition.beforeChar);
      // SillyTavern's extras ride inside `extensions`.
      expect(entry.depth, 2);
      expect(entry.role, LoreRole.assistant);
      expect(entry.preventRecursion, isTrue);
    });
  });

  group('this app', () {
    test("round-trips its own extras SillyTavern has no field for", () {
      final book = Lorebook(
        id: 'b1',
        name: 'Styled',
        description: 'Has a look of its own.',
        thumbnail: 'local:cover.png',
        color: 0xFF7C5CFF,
        tags: const ['fantasy', 'wip'],
        starred: true,
        tokenBudget: 800,
        recursive: true,
        entries: [
          LorebookEntry(
            uid: 4,
            name: 'Only entry',
            content: 'Something true.',
            keys: const ['thing'],
            priority: 20,
            weight: 90,
          ),
        ],
      );

      final again = LorebookCodec.parse(LorebookCodec.exportNative(book)).single;
      expect(again.name, 'Styled');
      expect(again.description, 'Has a look of its own.');
      expect(again.thumbnail, 'local:cover.png');
      expect(again.color, 0xFF7C5CFF);
      expect(again.tags, ['fantasy', 'wip']);
      expect(again.starred, isTrue);
      expect(again.tokenBudget, 800);
      expect(again.recursive, isTrue);
      // A new id, because importing means adding a copy.
      expect(again.id, isNot('b1'));

      final entry = again.entries.single;
      expect(entry.uid, 4);
      expect(entry.name, 'Only entry');
      expect(entry.keys, ['thing']);
      // The two knobs stay apart even though world info only has one.
      expect(entry.priority, 20);
      expect(entry.weight, 90);
    });

    test('reads a bundle of books from one file', () {
      final many = LorebookCodec.exportManyNative([
        Lorebook(id: '1', name: 'One'),
        Lorebook(id: '2', name: 'Two'),
      ]);
      final books = LorebookCodec.parse(many);
      expect(books.map((b) => b.name), ['One', 'Two']);
      expect(books.first.id, isNot(books.last.id));
    });

    test('tolerates keys written as one comma-separated string', () {
      final book = LorebookCodec.parse(jsonEncode({
        'entries': {
          '0': {'uid': 0, 'key': 'a, b ,c', 'content': 'x'},
        },
      })).single;
      expect(book.entries.single.keys, ['a', 'b', 'c']);
    });

    test('refuses a file that is not a lorebook', () {
      expect(() => LorebookCodec.parse('{"hello":"world"}'),
          throwsA(isA<FormatException>()));
      expect(() => LorebookCodec.parse('not json at all'), throwsA(anything));
    });
  });
}


