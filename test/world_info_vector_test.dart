import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/world_info.dart';

/// Semantic (embedding) activation: [WorldInfoScanner.scan]'s `forceActivate`
/// set turns entries on by id, even when no keyword matches — the path the
/// embedding index drives. These tests cover the scanner half only; the vector
/// math lives in embedding_index_test.
void main() {
  final scanner = WorldInfoScanner();

  Lorebook book(List<LorebookEntry> entries, {String id = 'b1'}) =>
      Lorebook(id: id, name: id, entries: entries, vectorized: true);

  List<ChatMessage> history() =>
      [ChatMessage(role: 'user', content: 'A quiet, ordinary morning.')];

  test('a forced entry activates with no keyword match', () {
    final entry = LorebookEntry(
      uid: 3,
      name: 'Hidden lore',
      content: 'The ancient pact still holds.',
      keys: const [], // no keywords at all
    );
    // Without forcing, a keyword-less non-constant entry never activates.
    final off = scanner.scan(books: [book([entry])], history: history());
    expect(off.isEmpty, true);

    // Forced by its `<bookId>#<uid>` key, it does.
    final on = scanner.scan(
      books: [book([entry])],
      history: history(),
      forceActivate: {'b1#3'},
    );
    expect(on.isEmpty, false);
    expect(on.activated.single.entry, 'Hidden lore');
    expect(on.activated.single.triggeredBy, '(semantic)');
  });

  test('forcing is scoped to the right book by id', () {
    final entry = LorebookEntry(uid: 1, content: 'Fact.', keys: const []);
    final result = scanner.scan(
      books: [book([entry], id: 'other')],
      history: history(),
      forceActivate: {'b1#1'}, // wrong book id
    );
    expect(result.isEmpty, true);
  });

  test('forced and keyword activation combine without duplicates', () {
    final keyword = LorebookEntry(
      uid: 1,
      name: 'Dragon',
      content: 'The dragon sleeps.',
      keys: const ['dragon'],
    );
    final forced = LorebookEntry(
      uid: 2,
      name: 'Secret',
      content: 'A secret door.',
      keys: const [],
    );
    final result = scanner.scan(
      books: [book([keyword, forced])],
      history: [ChatMessage(role: 'user', content: 'I see a dragon.')],
      forceActivate: {'b1#2'},
    );
    final names = result.activated.map((a) => a.entry).toSet();
    expect(names, {'Dragon', 'Secret'});
  });
}
