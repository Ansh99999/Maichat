import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/embedding.dart';

/// A stored vector collection: the embedding [model] its vectors were built with
/// plus the [records] themselves. If a caller's current model differs from
/// [model], the collection is stale and should be rebuilt (mixing vectors from
/// two models makes cosine similarity meaningless).
class VectorCollection {
  const VectorCollection({required this.model, required this.records});

  final String model;
  final List<VectorRecord> records;

  static const VectorCollection empty =
      VectorCollection(model: '', records: <VectorRecord>[]);

  bool get isEmpty => records.isEmpty;
}

/// Where embedding vectors live: files on disk, one per collection, exactly like
/// [AvatarStore] keeps pictures out of the preferences store.
///
/// A single 1536-float vector is ~6 KB; a long chat is several megabytes. That
/// belongs nowhere near `shared_preferences`, which is read and rewritten whole
/// on every reply and, past Android's parser limits, becomes unopenable. So each
/// collection — `chat-<id>`, `lore-<id>`, `doc-<id>` — is its own JSON file that
/// nothing reads until retrieval needs it.
class EmbeddingStore {
  EmbeddingStore(this.directory);

  final Directory directory;

  /// Opens (creating if needed) the vectors directory. Returns null when the
  /// platform will not say where to put it, in which case the feature stays off.
  static Future<EmbeddingStore?> open() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/vectors');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      return EmbeddingStore(dir);
    } catch (error) {
      debugPrint('MaiChat: no vectors directory available ($error)');
      return null;
    }
  }

  /// Turns a collection id into a safe file name (ids are numeric today, but a
  /// stray character must never let a write escape the directory).
  String _fileNameFor(String collectionId) {
    final safe = collectionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return '$safe.json';
  }

  File _fileFor(String collectionId) =>
      File('${directory.path}/${_fileNameFor(collectionId)}');

  bool exists(String collectionId) => _fileFor(collectionId).existsSync();

  /// Reads a collection, or [VectorCollection.empty] when it is absent or
  /// unreadable (a corrupt file is treated as "not indexed yet", never fatal).
  Future<VectorCollection> read(String collectionId) async {
    final file = _fileFor(collectionId);
    if (!file.existsSync()) return VectorCollection.empty;
    try {
      final json = jsonDecode(await file.readAsString());
      if (json is Map<String, dynamic>) {
        final records = (json['records'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(VectorRecord.fromJson)
            .where((r) => r.key.isNotEmpty && r.vector.isNotEmpty)
            .toList();
        return VectorCollection(
          model: json['model'] as String? ?? '',
          records: records,
        );
      }
    } catch (error) {
      debugPrint('MaiChat: could not read vectors for $collectionId ($error)');
    }
    return VectorCollection.empty;
  }

  /// Writes [records] for [collectionId], stamped with [model]. An empty list
  /// deletes the file rather than leaving an empty husk behind.
  Future<void> write(
    String collectionId,
    String model,
    List<VectorRecord> records,
  ) async {
    if (records.isEmpty) {
      await delete(collectionId);
      return;
    }
    final file = _fileFor(collectionId);
    await file.writeAsString(
      jsonEncode({
        'model': model,
        'dims': records.first.vector.length,
        'records': records.map((r) => r.toJson()).toList(),
      }),
      flush: true,
    );
  }

  Future<void> delete(String collectionId) async {
    final file = _fileFor(collectionId);
    try {
      if (file.existsSync()) await file.delete();
    } catch (error) {
      debugPrint('MaiChat: could not delete vectors for $collectionId ($error)');
    }
  }

  /// Deletes collection files whose id is not in [keep] — called when chats,
  /// lorebooks or documents are removed, and once at startup to clear orphans.
  Future<int> sweep(Iterable<String> keep) async {
    final referenced = keep.map(_fileNameFor).toSet();
    var removed = 0;
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (referenced.contains(name)) continue;
        entity.deleteSync();
        removed++;
      }
    } catch (error) {
      debugPrint('MaiChat: vector sweep failed ($error)');
    }
    return removed;
  }

  /// Total bytes the vector files occupy — for the storage report.
  Future<int> sizeBytes() async {
    var total = 0;
    try {
      for (final entity in directory.listSync()) {
        if (entity is File) total += entity.lengthSync();
      }
    } catch (_) {
      // Best-effort; a missing directory reports zero.
    }
    return total;
  }
}
