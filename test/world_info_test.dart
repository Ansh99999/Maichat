import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/world_info.dart';

/// A book with one entry, so a test only has to say what it is varying.
Lorebook _book(
  List<LorebookEntry> entries, {
  String name = 'Book',
  int? tokenBudget,
  int? scanDepth,
  bool recursive = false,
}) =>
    Lorebook(
      id: name,
      name: name,
      entries: entries,
      tokenBudget: tokenBudget,
      scanDepth: scanDepth,
      recursive: recursive,
    );

LorebookEntry _entry({
  int uid = 0,
  String name = 'Entry',
  String content = 'The fact.',
  List<String> keys = const ['dragon'],
  List<String> secondaryKeys = const [],
  bool enabled = true,
  bool constant = false,
  bool selective = true,
  SelectiveLogic logic = SelectiveLogic.andAny,
  int priority = 100,
  int weight = 100,
  LorebookPosition position = LorebookPosition.beforeChar,
  int depth = 4,
  LoreRole role = LoreRole.system,
  int probability = 100,
  bool useProbability = true,
  bool? caseSensitive,
  bool? matchWholeWords,
  int? scanDepth,
  bool excludeRecursion = false,
  bool preventRecursion = false,
  int delayUntilRecursion = 0,
  String group = '',
  bool groupOverride = false,
  int groupWeight = 100,
}) =>
    LorebookEntry(
      uid: uid,
      name: name,
      content: content,
      keys: keys,
      secondaryKeys: secondaryKeys,
      enabled: enabled,
      constant: constant,
      selective: selective,
      selectiveLogic: logic,
      priority: priority,
      weight: weight,
      position: position,
      depth: depth,
      role: role,
      probability: probability,
      useProbability: useProbability,
      caseSensitive: caseSensitive,
      matchWholeWords: matchWholeWords,
      scanDepth: scanDepth,
      excludeRecursion: excludeRecursion,
      preventRecursion: preventRecursion,
      delayUntilRecursion: delayUntilRecursion,
      group: group,
      groupOverride: groupOverride,
      groupWeight: groupWeight,
    );

/// Chat turns oldest first, alternating speakers, which is the order the app
/// hands its history to the scanner in.
List<ChatMessage> _chat(List<String> lines) => [
      for (var i = 0; i < lines.length; i++)
        ChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: lines[i],
        ),
    ];

void main() {
  // A fixed seed so the probability and inclusion-group rolls are repeatable.
  WorldInfoScanner scanner() => WorldInfoScanner(random: Random(7));

  group('keyword matching', () {
    test('activates on a keyword in recent chat, and not otherwise', () {
      final books = [_book([_entry()])];
      final hit = scanner().scan(
        books: books,
        history: _chat(['I saw a dragon today']),
      );
      expect(hit.before, 'The fact.');
      expect(hit.activated.single.triggeredBy, 'dragon');

      final miss = scanner().scan(
        books: books,
        history: _chat(['I saw a horse today']),
      );
      expect(miss.isEmpty, isTrue);
      expect(miss.activated, isEmpty);
    });

    test('matches whole words only by default', () {
      final books = [_book([_entry(keys: const ['book'])])];
      expect(
        scanner().scan(books: books, history: _chat(['read the book.'])).before,
        'The fact.',
      );
      expect(
        scanner().scan(books: books, history: _chat(['an ebook'])).isEmpty,
        isTrue,
      );
    });

    test('treats * and ? as wildcards, the way Agnai books expect', () {
      final books = [_book([_entry(keys: const ['book*'])])];
      expect(
        scanner().scan(books: books, history: _chat(['a booking'])).before,
        'The fact.',
      );
      expect(
        scanner().scan(books: books, history: _chat(['an ebook'])).isEmpty,
        isTrue,
      );
    });

    test('uses a /pattern/ key as a regular expression', () {
      final books = [_book([_entry(keys: const [r'/dragons?/i'])])];
      expect(
        scanner().scan(books: books, history: _chat(['many DRAGONS'])).before,
        'The fact.',
      );
      // A malformed pattern matches nothing rather than throwing.
      final broken = [_book([_entry(keys: const [r'/([unclosed/'])])];
      expect(
        scanner().scan(books: broken, history: _chat(['unclosed'])).isEmpty,
        isTrue,
      );
    });

    test('searches the speaker names too, as both originals do', () {
      final books = [_book([_entry(keys: const ['Alice'])])];
      final lore = scanner().scan(
        books: books,
        // The second turn is the assistant's, so it is labelled with the
        // character's name — which is why a name works as a keyword.
        history: _chat(['hello?', 'hello there']),
        charName: 'Alice',
      );
      expect(lore.before, 'The fact.');
    });
  });

  group('what activates', () {
    test('a constant entry needs no keyword and no history', () {
      final books = [_book([_entry(constant: true, keys: const [])])];
      final lore = scanner().scan(books: books, history: const []);
      expect(lore.before, 'The fact.');
      expect(lore.activated.single.constant, isTrue);
      expect(lore.activated.single.triggeredBy, isEmpty);
    });

    test('a switched-off or empty entry never activates', () {
      expect(
        scanner()
            .scan(
              books: [_book([_entry(enabled: false)])],
              history: _chat(['a dragon']),
            )
            .isEmpty,
        isTrue,
      );
      expect(
        scanner()
            .scan(
              books: [_book([_entry(content: '   ')])],
              history: _chat(['a dragon']),
            )
            .isEmpty,
        isTrue,
      );
    });

    test('probability 0 never fires and 100 always does', () {
      expect(
        scanner()
            .scan(
              books: [_book([_entry(probability: 0)])],
              history: _chat(['a dragon']),
            )
            .isEmpty,
        isTrue,
      );
      expect(
        scanner()
            .scan(
              books: [_book([_entry(probability: 0, useProbability: false)])],
              history: _chat(['a dragon']),
            )
            .before,
        'The fact.',
      );
    });

    test('only scans as far back as the depth allows', () {
      final chat = _chat(['a dragon', 'one', 'two', 'three', 'four']);
      final shallow = [_book([_entry(scanDepth: 2)])];
      expect(scanner().scan(books: shallow, history: chat).isEmpty, isTrue);
      final deep = [_book([_entry(scanDepth: 5)])];
      expect(scanner().scan(books: deep, history: chat).before, 'The fact.');
      // The book's own depth applies when the entry does not override it.
      final byBook = [_book([_entry()], scanDepth: 2)];
      expect(scanner().scan(books: byBook, history: chat).isEmpty, isTrue);
    });
  });

  group('secondary keys', () {
    WorldInfo run(SelectiveLogic logic, String line) => scanner().scan(
          books: [
            _book([
              _entry(
                keys: const ['dragon'],
                secondaryKeys: const ['fire', 'ice'],
                logic: logic,
              )
            ])
          ],
          history: _chat([line]),
        );

    test('any secondary key is enough for AND_ANY', () {
      expect(run(SelectiveLogic.andAny, 'a dragon of fire').isEmpty, isFalse);
      expect(run(SelectiveLogic.andAny, 'a dragon of mud').isEmpty, isTrue);
    });

    test('AND_ALL needs every one of them', () {
      expect(run(SelectiveLogic.andAll, 'a dragon of fire').isEmpty, isTrue);
      expect(
        run(SelectiveLogic.andAll, 'a dragon of fire and ice').isEmpty,
        isFalse,
      );
    });

    test('NOT_ANY needs none of them', () {
      expect(run(SelectiveLogic.notAny, 'a dragon of mud').isEmpty, isFalse);
      expect(run(SelectiveLogic.notAny, 'a dragon of fire').isEmpty, isTrue);
    });

    test('NOT_ALL needs at least one to be missing', () {
      expect(run(SelectiveLogic.notAll, 'a dragon of fire').isEmpty, isFalse);
      expect(
        run(SelectiveLogic.notAll, 'a dragon of fire and ice').isEmpty,
        isTrue,
      );
    });

    test('are ignored when the entry is not selective', () {
      final lore = scanner().scan(
        books: [
          _book([
            _entry(
              keys: const ['dragon'],
              secondaryKeys: const ['fire'],
              selective: false,
            )
          ])
        ],
        history: _chat(['a dragon of mud']),
      );
      expect(lore.before, 'The fact.');
    });
  });

  group('budget and ordering', () {
    test('drops the lowest priority first when the budget runs out', () {
      final books = [
        _book(
          [
            _entry(uid: 0, name: 'Cheap', content: 'aaa', priority: 10),
            _entry(uid: 1, name: 'Dear', content: 'bbb', priority: 90),
          ],
          // Room for one short entry only.
          tokenBudget: 2,
        )
      ];
      final lore = scanner().scan(books: books, history: _chat(['a dragon']));
      expect(lore.activated.map((a) => a.entry), ['Dear']);
    });

    test('orders by weight, heaviest closest to the reply', () {
      final books = [
        _book([
          _entry(uid: 0, content: 'light', weight: 1),
          _entry(uid: 1, content: 'heavy', weight: 900),
          _entry(uid: 2, content: 'middling', weight: 50),
        ])
      ];
      final lore = scanner().scan(books: books, history: _chat(['a dragon']));
      expect(lore.before, 'light\nmiddling\nheavy');
    });

    test('pools the entries of every active book', () {
      final lore = scanner().scan(
        books: [
          _book([_entry(content: 'from one', keys: const ['dragon'])],
              name: 'One'),
          _book([_entry(content: 'from two', keys: const ['castle'])],
              name: 'Two'),
        ],
        history: _chat(['a dragon near the castle']),
      );
      expect(lore.activated.map((a) => a.book), containsAll(['One', 'Two']));
      expect(lore.before, contains('from one'));
      expect(lore.before, contains('from two'));
    });

    test('reports what it cost, measured like the prompt budget', () {
      final lore = scanner().scan(
        books: [_book([_entry(content: 'a few words of lore')])],
        history: _chat(['a dragon']),
      );
      expect(lore.tokens, greaterThan(0));
      expect(lore.activated.single.tokens, lore.tokens);
    });
  });

  group('placement', () {
    test('puts each entry in the slot its position asks for', () {
      final lore = scanner().scan(
        books: [
          _book([
            _entry(
                uid: 0,
                content: 'ahead',
                position: LorebookPosition.beforeChar),
            _entry(
                uid: 1, content: 'behind', position: LorebookPosition.afterChar),
            _entry(uid: 2, content: 'over', position: LorebookPosition.emTop),
            _entry(uid: 3, content: 'under', position: LorebookPosition.emBottom),
            _entry(
              uid: 4,
              content: 'in the chat',
              position: LorebookPosition.atDepth,
              depth: 2,
              role: LoreRole.user,
            ),
          ])
        ],
        history: _chat(['a dragon']),
      );
      expect(lore.before, 'ahead');
      expect(lore.after, 'behind');
      expect(lore.exampleTop, 'over');
      expect(lore.exampleBottom, 'under');
      expect(lore.injections.single.text, 'in the chat');
      expect(lore.injections.single.depth, 2);
      expect(lore.injections.single.role, LoreRole.user);
    });

    test('anchors the author-note slots to the definitions instead', () {
      final lore = scanner().scan(
        books: [
          _book([
            _entry(uid: 0, content: 'top', position: LorebookPosition.anTop),
            _entry(uid: 1, content: 'bottom', position: LorebookPosition.anBottom),
          ])
        ],
        history: _chat(['a dragon']),
      );
      expect(lore.before, 'top');
      expect(lore.after, 'bottom');
    });

    test('groups entries sharing a depth and role into one injection', () {
      final lore = scanner().scan(
        books: [
          _book([
            _entry(uid: 0, content: 'one', position: LorebookPosition.atDepth),
            _entry(uid: 1, content: 'two', position: LorebookPosition.atDepth),
          ])
        ],
        history: _chat(['a dragon']),
      );
      expect(lore.injections, hasLength(1));
      expect(lore.injections.single.text, 'one\ntwo');
    });
  });

  group('recursion', () {
    List<Lorebook> chain({
      bool recursive = true,
      bool preventRecursion = false,
      bool excludeRecursion = false,
    }) =>
        [
          _book(
            [
              _entry(
                uid: 0,
                name: 'Dragons',
                content: 'Dragons serve the Queen.',
                keys: const ['dragon'],
                preventRecursion: preventRecursion,
              ),
              _entry(
                uid: 1,
                name: 'Queen',
                content: 'The Queen is very old.',
                keys: const ['Queen'],
                excludeRecursion: excludeRecursion,
              ),
            ],
            recursive: recursive,
          )
        ];

    test('lore can pull in more lore when the book asks for it', () {
      final lore =
          scanner().scan(books: chain(), history: _chat(['a dragon!']));
      expect(lore.activated.map((a) => a.entry), containsAll(['Dragons', 'Queen']));
    });

    test('and cannot when it does not', () {
      final lore = scanner()
          .scan(books: chain(recursive: false), history: _chat(['a dragon!']));
      expect(lore.activated.map((a) => a.entry), ['Dragons']);
    });

    test('preventRecursion keeps an entry out of the second scan', () {
      final lore = scanner().scan(
        books: chain(preventRecursion: true),
        history: _chat(['a dragon!']),
      );
      expect(lore.activated.map((a) => a.entry), ['Dragons']);
    });

    test('excludeRecursion keeps an entry from being pulled in', () {
      final lore = scanner().scan(
        books: chain(excludeRecursion: true),
        history: _chat(['a dragon!']),
      );
      expect(lore.activated.map((a) => a.entry), ['Dragons']);
    });

    test('an entry can be held back until the recursive pass', () {
      final books = [
        _book(
          [
            _entry(uid: 0, name: 'First', content: 'Something.', keys: const ['dragon']),
            _entry(
              uid: 1,
              name: 'Late',
              content: 'Only later.',
              keys: const ['dragon'],
              delayUntilRecursion: 1,
            ),
          ],
          recursive: true,
        )
      ];
      final lore = scanner().scan(books: books, history: _chat(['a dragon!']));
      expect(lore.activated.map((a) => a.entry), containsAll(['First', 'Late']));

      // Without recursion there is no later pass for it to arrive in.
      final once = [
        _book(
          [
            _entry(uid: 0, name: 'First', content: 'Something.', keys: const ['dragon']),
            _entry(
              uid: 1,
              name: 'Late',
              content: 'Only later.',
              keys: const ['dragon'],
              delayUntilRecursion: 1,
            ),
          ],
          recursive: false,
        )
      ];
      expect(
        scanner().scan(books: once, history: _chat(['a dragon!'])).activated
            .map((a) => a.entry),
        ['First'],
      );
    });
  });
}





