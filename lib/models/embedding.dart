import 'dart:convert';
import 'dart:typed_data';

/// The model MaiChat vectorises text with by default — OpenAI's small, cheap
/// embedding model, understood by every OpenAI-compatible gateway. Returns
/// 1536-dimension, already L2-normalised vectors, so a dot product is cosine.
const String kDefaultEmbeddingModel = 'text-embedding-3-small';

/// App-wide embedding settings, mirroring SillyTavern's Vector Storage defaults.
/// One provider (by id) supplies the `/embeddings` endpoint; everything else is
/// how retrieval behaves. Persisted whole under the `embeddings` prefs key.
class EmbeddingConfig {
  const EmbeddingConfig({
    this.enabled = false,
    this.providerId,
    this.model = kDefaultEmbeddingModel,
    this.chatRecallDefault = false,
    this.loreActivation = false,
    this.insert = 3,
    this.queryMessages = 2,
    this.protect = 5,
    this.threshold = 0.25,
    this.messageChunkSize = 400,
    this.docChunkSize = 5000,
    this.docOverlapPercent = 10,
    this.depth = 2,
    this.template = 'Past events:\n{{text}}',
    this.docTemplate = 'Related information:\n{{text}}',
  });

  /// Master switch: nothing indexes, retrieves or costs anything while off.
  final bool enabled;

  /// The OpenAI-kind [Provider] whose base URL + key serve `/embeddings`. Null
  /// until the user picks one; retrieval is inert without it.
  final String? providerId;

  /// The embedding model name sent in the request body.
  final String model;

  /// Whether a newly created chat has semantic recall on by default. (A chat can
  /// still be toggled individually — this is only the default.)
  final bool chatRecallDefault;

  /// Whether lorebook entries may be activated semantically (in addition to the
  /// keyword scan) for books that opt in via [Lorebook.vectorized].
  final bool loreActivation;

  /// Top-K: how many retrieved chunks to inject (ST `insert`).
  final int insert;

  /// How many of the most recent messages form the retrieval query (ST `query`).
  final int queryMessages;

  /// The last N messages are never retrieved/injected — they are already in
  /// context (ST `protect`).
  final int protect;

  /// Minimum cosine similarity for a chunk to count as a hit (ST
  /// `score_threshold`).
  final double threshold;

  /// Message chunking size in characters (ST `message_chunk_size`).
  final int messageChunkSize;

  /// Document chunking size in characters (ST Data Bank `chunk_size`).
  final int docChunkSize;

  /// Percentage overlap between adjacent document chunks.
  final int docOverlapPercent;

  /// How many messages from the end the injected memory block sits at.
  final int depth;

  /// Wrapper for injected chat memories; `{{text}}` is the joined chunks.
  final String template;

  /// Wrapper for injected document chunks; `{{text}}` is the joined chunks.
  final String docTemplate;

  bool get isReady => enabled && (providerId?.trim().isNotEmpty ?? false);

  EmbeddingConfig copyWith({
    bool? enabled,
    String? providerId,
    bool clearProvider = false,
    String? model,
    bool? chatRecallDefault,
    bool? loreActivation,
    int? insert,
    int? queryMessages,
    int? protect,
    double? threshold,
    int? messageChunkSize,
    int? docChunkSize,
    int? docOverlapPercent,
    int? depth,
    String? template,
    String? docTemplate,
  }) =>
      EmbeddingConfig(
        enabled: enabled ?? this.enabled,
        providerId: clearProvider ? null : (providerId ?? this.providerId),
        model: model ?? this.model,
        chatRecallDefault: chatRecallDefault ?? this.chatRecallDefault,
        loreActivation: loreActivation ?? this.loreActivation,
        insert: insert ?? this.insert,
        queryMessages: queryMessages ?? this.queryMessages,
        protect: protect ?? this.protect,
        threshold: threshold ?? this.threshold,
        messageChunkSize: messageChunkSize ?? this.messageChunkSize,
        docChunkSize: docChunkSize ?? this.docChunkSize,
        docOverlapPercent: docOverlapPercent ?? this.docOverlapPercent,
        depth: depth ?? this.depth,
        template: template ?? this.template,
        docTemplate: docTemplate ?? this.docTemplate,
      );

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        if (providerId != null) 'providerId': providerId,
        'model': model,
        'chatRecallDefault': chatRecallDefault,
        'loreActivation': loreActivation,
        'insert': insert,
        'queryMessages': queryMessages,
        'protect': protect,
        'threshold': threshold,
        'messageChunkSize': messageChunkSize,
        'docChunkSize': docChunkSize,
        'docOverlapPercent': docOverlapPercent,
        'depth': depth,
        'template': template,
        'docTemplate': docTemplate,
      };

  factory EmbeddingConfig.fromJson(Map<String, dynamic> json) {
    int intOr(String k, int fallback) =>
        (json[k] as num?)?.toInt() ?? fallback;
    return EmbeddingConfig(
      enabled: json['enabled'] as bool? ?? false,
      providerId: (json['providerId'] as String?)?.trim().isEmpty ?? true
          ? null
          : (json['providerId'] as String).trim(),
      model: (json['model'] as String?)?.trim().isNotEmpty ?? false
          ? (json['model'] as String).trim()
          : kDefaultEmbeddingModel,
      chatRecallDefault: json['chatRecallDefault'] as bool? ?? false,
      loreActivation: json['loreActivation'] as bool? ?? false,
      insert: intOr('insert', 3),
      queryMessages: intOr('queryMessages', 2),
      protect: intOr('protect', 5),
      threshold: (json['threshold'] as num?)?.toDouble() ?? 0.25,
      messageChunkSize: intOr('messageChunkSize', 400),
      docChunkSize: intOr('docChunkSize', 5000),
      docOverlapPercent: intOr('docOverlapPercent', 10),
      depth: intOr('depth', 2),
      template: (json['template'] as String?)?.isNotEmpty ?? false
          ? json['template'] as String
          : 'Past events:\n{{text}}',
      docTemplate: (json['docTemplate'] as String?)?.isNotEmpty ?? false
          ? json['docTemplate'] as String
          : 'Related information:\n{{text}}',
    );
  }
}

/// Where a document's text came from.
enum DocSource {
  file('File'),
  url('Web link'),
  paste('Pasted text');

  const DocSource(this.label);
  final String label;

  static DocSource fromName(Object? value) {
    for (final s in DocSource.values) {
      if (s.name == value) return s;
    }
    return DocSource.paste;
  }
}

/// A knowledge source attached to chats and searched semantically — a "Data
/// Bank" document. The chunk text + vectors live in a file-backed `doc-<id>`
/// collection (see `EmbeddingStore`); only this small record is in prefs.
class EmbeddingDocument {
  EmbeddingDocument({
    required this.id,
    required this.name,
    required this.source,
    this.origin = '',
    this.chunkCount = 0,
    this.tokens = 0,
    this.model = kDefaultEmbeddingModel,
    List<String>? tags,
    DateTime? addedAt,
  })  : tags = tags ?? <String>[],
        addedAt = addedAt ?? DateTime.now();

  final String id;
  String name;

  /// How it was ingested (file / URL / paste).
  final DocSource source;

  /// The original URL or file name, for display and re-indexing.
  final String origin;

  /// How many chunks were embedded — 0 means it has not been indexed yet.
  int chunkCount;

  /// Approximate token count of the source text (for the size readout).
  int tokens;

  /// Free-form tags for filtering the document shelf.
  List<String> tags;

  /// The embedding model its vectors were built with; a change forces a reindex.
  String model;

  final DateTime addedAt;

  String get displayName => name.trim().isEmpty ? 'Untitled document' : name.trim();

  bool get isIndexed => chunkCount > 0;

  /// Whether [query] matches this document by name, tag or source.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        origin.toLowerCase().contains(q) ||
        tags.any((t) => t.toLowerCase().contains(q));
  }

  EmbeddingDocument copyWith({
    String? name,
    int? chunkCount,
    int? tokens,
    List<String>? tags,
    String? model,
  }) =>
      EmbeddingDocument(
        id: id,
        name: name ?? this.name,
        source: source,
        origin: origin,
        chunkCount: chunkCount ?? this.chunkCount,
        tokens: tokens ?? this.tokens,
        tags: tags ?? List<String>.from(this.tags),
        model: model ?? this.model,
        addedAt: addedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'source': source.name,
        if (origin.isNotEmpty) 'origin': origin,
        'chunkCount': chunkCount,
        if (tokens > 0) 'tokens': tokens,
        if (tags.isNotEmpty) 'tags': tags,
        'model': model,
        'addedAt': addedAt.toIso8601String(),
      };

  factory EmbeddingDocument.fromJson(Map<String, dynamic> json) =>
      EmbeddingDocument(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        source: DocSource.fromName(json['source']),
        origin: json['origin'] as String? ?? '',
        chunkCount: (json['chunkCount'] as num?)?.toInt() ?? 0,
        tokens: (json['tokens'] as num?)?.toInt() ?? 0,
        tags: (json['tags'] as List?)
            ?.map((e) => e.toString().trim())
            .where((s) => s.isNotEmpty)
            .toList(),
        model: (json['model'] as String?)?.trim().isNotEmpty ?? false
            ? (json['model'] as String).trim()
            : kDefaultEmbeddingModel,
        addedAt: DateTime.tryParse(json['addedAt'] as String? ?? ''),
      );
}

/// One stored vector: the source [text] and its embedding. [key] is a stable id
/// (a content hash for messages, `docId#n` for document chunks) used to add and
/// remove incrementally without re-embedding what is unchanged.
class VectorRecord {
  const VectorRecord({
    required this.key,
    required this.text,
    required this.vector,
  });

  final String key;
  final String text;
  final Float32List vector;

  Map<String, dynamic> toJson() => {
        'key': key,
        'text': text,
        'v': base64Encode(vector.buffer.asUint8List()),
      };

  factory VectorRecord.fromJson(Map<String, dynamic> json) {
    final bytes = base64Decode(json['v'] as String? ?? '');
    return VectorRecord(
      key: json['key'] as String? ?? '',
      text: json['text'] as String? ?? '',
      vector: bytes.buffer.asFloat32List(
        bytes.offsetInBytes,
        bytes.lengthInBytes ~/ 4,
      ),
    );
  }
}
