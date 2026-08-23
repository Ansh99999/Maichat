import 'dart:math';
import 'dart:typed_data';

import '../models/embedding.dart';
import '../models/lorebook.dart';
import '../models/message.dart';
import 'embedding_store.dart';
import 'text_chunk.dart';

/// Embeds a batch of texts with the given model. Injected so the engine is pure
/// logic — the app wires this to `ChatClient.embed`, tests to a deterministic
/// fake. May throw [ChatApiException]; the engine retries 429s with backoff.
typedef Embedder = Future<List<Float32List>> Function(
    List<String> texts, String model);

/// A retrieved chunk and how close it was to the query (cosine, 0..1).
class ScoredChunk {
  const ScoredChunk({required this.key, required this.text, required this.score});
  final String key;
  final String text;
  final double score;
}

/// The semantic-memory engine: it turns text into vectors (via the injected
/// [Embedder]), keeps them in file-backed collections (via [EmbeddingStore]),
/// and answers "what stored text is closest in meaning to this query?".
///
/// Indexing is incremental and keyed by a content hash, so unchanged text is
/// never re-embedded and an edited/removed message drops out on the next pass.
/// Nothing here touches the UI or the chat's streaming path.
class EmbeddingIndex {
  EmbeddingIndex({
    required this.store,
    required this.embed,
    this.batchSize = 64,
    this.maxRetries = 2,
  });

  final EmbeddingStore store;
  final Embedder embed;

  /// How many texts go in one `/embeddings` request while indexing.
  final int batchSize;

  /// Retries per batch on a 429 (rate limit), with exponential backoff.
  final int maxRetries;

  static String chatCollection(String convId) => 'chat-$convId';
  static String loreCollection(String bookId) => 'lore-$bookId';
  static String docCollection(String docId) => 'doc-$docId';

  /// Cosine similarity of two equal-length vectors, guarding zero-length ones.
  /// (`text-embedding-3-small` returns L2-normalised vectors, so this reduces to
  /// a dot product, but dividing by the norms keeps any model honest.)
  static double cosine(Float32List a, Float32List b) {
    if (a.isEmpty || a.length != b.length) return 0;
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      na += a[i] * a[i];
      nb += b[i] * b[i];
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (sqrt(na) * sqrt(nb));
  }

  /// A stable, order-independent hash of a chunk's text — its record key. FNV-1a
  /// over the UTF-16 code units; collisions are astronomically unlikely for this.
  static String hashText(String text) {
    var hash = 0xcbf29ce484222325;
    for (final unit in text.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
    }
    return hash.toRadixString(16);
  }

  /// Embeds [texts] in batches, retrying each batch on a 429. Returns vectors in
  /// input order. Any other failure propagates.
  Future<List<Float32List>> _embedAll(List<String> texts, String model) async {
    final out = <Float32List>[];
    for (var i = 0; i < texts.length; i += batchSize) {
      final slice = texts.sublist(i, min(i + batchSize, texts.length));
      out.addAll(await _embedBatch(slice, model));
    }
    return out;
  }

  Future<List<Float32List>> _embedBatch(List<String> slice, String model) async {
    for (var attempt = 0;; attempt++) {
      try {
        return await embed(slice, model);
      } catch (e) {
        final msg = e.toString().toLowerCase();
        final rateLimited = msg.contains('429') || msg.contains('rate limit');
        if (rateLimited && attempt < maxRetries) {
          await Future<void>.delayed(
              Duration(milliseconds: 800 * (1 << attempt)));
          continue;
        }
        rethrow;
      }
    }
  }

  /// Re-embeds only what changed for a set of `{key: text}` pairs against the
  /// collection [id], writing the result back under [model]. Existing records
  /// whose key is gone are dropped; new keys are embedded. Returns the record
  /// count. A model change discards the whole collection first.
  Future<int> _sync(
    String id,
    String model,
    Map<String, String> desired, {
    String sourceText = '',
  }) async {
    final existing = await store.read(id);
    final fresh = model == existing.model;
    final kept = <String, VectorRecord>{};
    if (fresh) {
      for (final r in existing.records) {
        if (desired.containsKey(r.key)) kept[r.key] = r;
      }
    }
    final missing = <String, String>{
      for (final e in desired.entries)
        if (!kept.containsKey(e.key)) e.key: e.value,
    };
    if (missing.isNotEmpty) {
      final keys = missing.keys.toList();
      final vectors = await _embedAll(missing.values.toList(), model);
      for (var i = 0; i < keys.length && i < vectors.length; i++) {
        kept[keys[i]] = VectorRecord(
          key: keys[i],
          text: missing[keys[i]]!,
          vector: vectors[i],
        );
      }
    }
    // Preserve desired order for stable output.
    final records = <VectorRecord>[
      for (final key in desired.keys)
        if (kept.containsKey(key)) kept[key]!,
    ];
    await store.write(id, model, records, sourceText: sourceText);
    return records.length;
  }

  /// Indexes a chat's messages: each usable turn is chunked and embedded, keyed
  /// by content hash so only new/edited text costs an embed call.
  Future<void> indexChat(
    String convId,
    List<ChatMessage> messages, {
    required String model,
    required int chunkSize,
  }) async {
    final desired = <String, String>{};
    for (final chunk in chatChunks(messages, chunkSize)) {
      desired[hashText(chunk)] = chunk;
    }
    await _sync(chatCollection(convId), model, desired);
  }

  /// The chunks a chat contributes, in order — shared with retrieval so the
  /// "protect the last N messages" exclusion keys line up exactly.
  static List<String> chatChunks(List<ChatMessage> messages, int chunkSize) {
    final out = <String>[];
    for (final m in messages) {
      if (m.error) continue;
      if (m.role != 'user' && m.role != 'assistant') continue;
      final text = m.content.trim();
      if (text.isEmpty) continue;
      out.addAll(chunkText(text, size: chunkSize));
    }
    return out;
  }

  /// Indexes a lorebook's usable entries, keyed `<uid>:<contentHash>` so an
  /// edited entry re-embeds and the old vector drops out.
  Future<void> indexLore(
    String bookId,
    List<LorebookEntry> entries, {
    required String model,
  }) async {
    final desired = <String, String>{};
    for (final e in entries) {
      if (!e.isUsable) continue;
      final text = e.content.trim();
      if (text.isEmpty) continue;
      desired['${e.uid}:${hashText(text)}'] = text;
    }
    await _sync(loreCollection(bookId), model, desired);
  }

  /// Indexes a document's text as overlapping chunks. Returns the chunk count.
  Future<int> indexDocument(
    String docId,
    String text, {
    required String model,
    required int chunkSize,
    required int overlapPercent,
  }) async {
    final chunks = chunkText(text, size: chunkSize, overlapPercent: overlapPercent);
    final desired = <String, String>{
      for (var i = 0; i < chunks.length; i++) '$docId#$i': chunks[i],
    };
    return _sync(docCollection(docId), model, desired, sourceText: text);
  }

  /// Embeds a single query string; null when it is empty.
  Future<Float32List?> embedQuery(String text, {required String model}) async {
    final q = text.trim();
    if (q.isEmpty) return null;
    final vectors = await embed([q], model);
    return vectors.isEmpty ? null : vectors.first;
  }

  /// The top [topK] chunks in collection [id] whose cosine to [query] clears
  /// [threshold], best first. Records built with a different [model] are ignored
  /// (the collection is stale until re-indexed). [excludeKeys] drops chunks that
  /// are already in context (the protected recent messages).
  Future<List<ScoredChunk>> retrieve(
    String id,
    Float32List query, {
    required int topK,
    required double threshold,
    required String model,
    Set<String> excludeKeys = const <String>{},
  }) async {
    if (topK <= 0) return const <ScoredChunk>[];
    final col = await store.read(id);
    if (col.isEmpty || col.model != model) return const <ScoredChunk>[];
    final scored = <ScoredChunk>[];
    for (final r in col.records) {
      if (excludeKeys.contains(r.key)) continue;
      final score = cosine(query, r.vector);
      if (score < threshold) continue;
      scored.add(ScoredChunk(key: r.key, text: r.text, score: score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.length > topK ? scored.sublist(0, topK) : scored;
  }
}
