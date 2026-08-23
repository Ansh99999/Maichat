import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/embedding.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/services/embedding_index.dart';
import 'package:maichat/services/embedding_store.dart';
import 'package:maichat/services/text_chunk.dart';

/// A deterministic, network-free embedder: each text becomes a bag-of-keywords
/// vector, so texts sharing words land close in cosine space. Enough to exercise
/// indexing and retrieval without a real provider.
const _vocab = ['cat', 'dog', 'fish', 'space', 'rocket', 'castle', 'dragon', 'love'];

Float32List _fakeVector(String text) {
  final lower = text.toLowerCase();
  final v = Float32List(_vocab.length);
  for (var i = 0; i < _vocab.length; i++) {
    v[i] = RegExp(_vocab[i]).allMatches(lower).length.toDouble();
  }
  return v;
}

int _embedCalls = 0;

Future<List<Float32List>> _embed(List<String> texts, String model) async {
  _embedCalls++;
  return texts.map(_fakeVector).toList();
}

EmbeddingIndex _index(Directory dir) =>
    EmbeddingIndex(store: EmbeddingStore(dir), embed: _embed);

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('mc_embed_test');
    _embedCalls = 0;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('cosine', () {
    test('is 1 for identical, 0 for orthogonal vectors', () {
      final a = Float32List.fromList(const [1, 0, 0]);
      final b = Float32List.fromList(const [0, 1, 0]);
      expect(EmbeddingIndex.cosine(a, a), closeTo(1.0, 1e-9));
      expect(EmbeddingIndex.cosine(a, b), 0.0);
    });

    test('is 0 for a zero vector or a length mismatch', () {
      expect(
        EmbeddingIndex.cosine(
            Float32List.fromList(const [0, 0]), Float32List.fromList(const [1, 1])),
        0.0,
      );
      expect(
        EmbeddingIndex.cosine(
            Float32List.fromList(const [1]), Float32List.fromList(const [1, 1])),
        0.0,
      );
    });
  });

  group('chunkText', () {
    test('returns the whole text when it fits', () {
      expect(chunkText('short', size: 400), ['short']);
    });

    test('splits long text into multiple chunks', () {
      final text = List.filled(50, 'sentence.').join(' ');
      final chunks = chunkText(text, size: 100);
      expect(chunks.length, greaterThan(1));
      expect(chunks.every((c) => c.isNotEmpty), true);
    });

    test('overlap makes chunks share text', () {
      final text = List.generate(40, (i) => 'word$i').join(' ');
      final none = chunkText(text, size: 80, overlapPercent: 0);
      final some = chunkText(text, size: 80, overlapPercent: 40);
      expect(some.length, greaterThanOrEqualTo(none.length));
    });
  });

  group('indexChat + retrieve', () {
    List<ChatMessage> history() => [
          ChatMessage(role: 'user', content: 'Tell me about the space rocket.'),
          ChatMessage(role: 'assistant', content: 'The rocket flew to space.'),
          ChatMessage(role: 'user', content: 'And the castle dragon?'),
          ChatMessage(role: 'assistant', content: 'A dragon guards the castle.'),
        ];

    test('retrieves the message closest in meaning to the query', () async {
      final index = _index(dir);
      await index.indexChat('c1', history(), model: 'm', chunkSize: 400);
      final qv = await index.embedQuery('rocket in space', model: 'm');
      final hits = await index.retrieve(
        EmbeddingIndex.chatCollection('c1'),
        qv!,
        topK: 1,
        threshold: 0.1,
        model: 'm',
      );
      expect(hits, isNotEmpty);
      expect(hits.first.text.toLowerCase(), contains('rocket'));
    });

    test('threshold filters out weak matches', () async {
      final index = _index(dir);
      await index.indexChat('c1', history(), model: 'm', chunkSize: 400);
      final qv = await index.embedQuery('fish', model: 'm');
      final hits = await index.retrieve(
        EmbeddingIndex.chatCollection('c1'),
        qv!,
        topK: 5,
        threshold: 0.1,
        model: 'm',
      );
      expect(hits, isEmpty); // nothing in the chat mentions fish
    });

    test('excludeKeys drops the protected recent messages', () async {
      final index = _index(dir);
      final msgs = history();
      await index.indexChat('c1', msgs, model: 'm', chunkSize: 400);
      final qv = await index.embedQuery('dragon castle', model: 'm');
      // Exclude the last message's chunk (its hash), so it can't be recalled.
      final exclude = EmbeddingIndex.chatChunks([msgs.last], 400)
          .map(EmbeddingIndex.hashText)
          .toSet();
      final hits = await index.retrieve(
        EmbeddingIndex.chatCollection('c1'),
        qv!,
        topK: 5,
        threshold: 0.1,
        model: 'm',
        excludeKeys: exclude,
      );
      expect(hits.any((h) => h.text == 'A dragon guards the castle.'), false);
    });

    test('incremental indexing only embeds new messages', () async {
      final index = _index(dir);
      await index.indexChat('c1', history(), model: 'm', chunkSize: 400);
      final firstPass = _embedCalls;
      // Re-index the same history: nothing new, so no further embed calls.
      await index.indexChat('c1', history(), model: 'm', chunkSize: 400);
      expect(_embedCalls, firstPass);
      // Add a message: exactly one more embed batch.
      final grown = history()
        ..add(ChatMessage(role: 'user', content: 'A fish swims.'));
      await index.indexChat('c1', grown, model: 'm', chunkSize: 400);
      expect(_embedCalls, greaterThan(firstPass));
    });

    test('a model change re-embeds the whole collection', () async {
      final index = _index(dir);
      await index.indexChat('c1', history(), model: 'm', chunkSize: 400);
      final before = _embedCalls;
      await index.indexChat('c1', history(), model: 'other', chunkSize: 400);
      expect(_embedCalls, greaterThan(before));
      // Retrieval with the old model now sees a stale collection → empty.
      final qv = await index.embedQuery('rocket', model: 'm');
      final hits = await index.retrieve(
        EmbeddingIndex.chatCollection('c1'),
        qv!,
        topK: 3,
        threshold: 0.1,
        model: 'm',
      );
      expect(hits, isEmpty);
    });
  });

  group('indexDocument', () {
    test('chunks, embeds and reports the chunk count', () async {
      final index = _index(dir);
      final text = List.filled(20, 'The dragon flew over the castle.').join(' ');
      final count = await index.indexDocument('d1', text,
          model: 'm', chunkSize: 60, overlapPercent: 0);
      expect(count, greaterThan(1));
      final qv = await index.embedQuery('dragon', model: 'm');
      final hits = await index.retrieve(
        EmbeddingIndex.docCollection('d1'),
        qv!,
        topK: 2,
        threshold: 0.1,
        model: 'm',
      );
      expect(hits, isNotEmpty);
    });

    test('stores the exact source text for re-editing (overlap not duplicated)',
        () async {
      final index = _index(dir);
      final text = List.generate(30, (i) => 'Sentence number $i.').join(' ');
      await index.indexDocument('d2', text,
          model: 'm', chunkSize: 80, overlapPercent: 20);
      final col = await EmbeddingStore(dir).read(EmbeddingIndex.docCollection('d2'));
      expect(col.sourceText, text); // exact, not the overlapped chunk join
    });
  });

  group('indexLore + activation keys', () {
    test('a lore hit key carries the entry uid', () async {
      final index = _index(dir);
      final entries = [
        LorebookEntry(uid: 7, content: 'The dragon hoards gold.', keys: ['dragon']),
        LorebookEntry(uid: 8, content: 'A fish lives in the sea.', keys: ['fish']),
      ];
      await index.indexLore('b1', entries, model: 'm');
      final qv = await index.embedQuery('dragon', model: 'm');
      final hits = await index.retrieve(
        EmbeddingIndex.loreCollection('b1'),
        qv!,
        topK: 1,
        threshold: 0.1,
        model: 'm',
      );
      expect(hits, isNotEmpty);
      // Keys are `<uid>:<hash>` — the uid is recoverable for force-activation.
      expect(hits.first.key.split(':').first, '7');
    });
  });

  group('EmbeddingStore', () {
    test('round-trips a collection through disk', () async {
      final store = EmbeddingStore(dir);
      final records = [
        VectorRecord(
            key: 'a', text: 'alpha', vector: Float32List.fromList(const [1, 2, 3])),
        VectorRecord(
            key: 'b', text: 'beta', vector: Float32List.fromList(const [4, 5, 6])),
      ];
      await store.write('chat-x', 'm', records);
      final read = await store.read('chat-x');
      expect(read.model, 'm');
      expect(read.records.length, 2);
      expect(read.records.first.text, 'alpha');
      expect(read.records[1].vector, [4, 5, 6]);
    });

    test('writing an empty list deletes the file', () async {
      final store = EmbeddingStore(dir);
      await store.write('chat-x', 'm', [
        VectorRecord(key: 'a', text: 't', vector: Float32List.fromList(const [1])),
      ]);
      expect(store.exists('chat-x'), true);
      await store.write('chat-x', 'm', const []);
      expect(store.exists('chat-x'), false);
    });

    test('sweep removes collections not in the keep set', () async {
      final store = EmbeddingStore(dir);
      final rec = [
        VectorRecord(key: 'a', text: 't', vector: Float32List.fromList(const [1])),
      ];
      await store.write('chat-keep', 'm', rec);
      await store.write('chat-drop', 'm', rec);
      await store.sweep({'chat-keep'});
      expect(store.exists('chat-keep'), true);
      expect(store.exists('chat-drop'), false);
    });
  });
}
