/// Reads and writes a whole-app backup: one archive that holds every stored
/// entry, every picture file and every vector file, so a restore puts each
/// thing back exactly where it was rather than approximately.
///
/// The shape is deliberately the *store itself*, not a hand-written list of
/// models. Every feature in this app persists through `Storage`'s keyed
/// entries, so copying those verbatim means a backup cannot silently miss a
/// field somebody added later — the alternative (enumerate every model, map it
/// by hand) is exactly the code that goes stale and drops a per-chat override.
///
/// An archive is a zip:
///
/// ```
/// maichat-backup.json   the manifest: header, counts and every store entry
/// pictures/<name>       the picture files, byte for byte
/// vectors/<name>        the embedding collections
/// ```
///
/// A bare manifest `.json` is accepted on the way in too, which is what a
/// pictures-excluded export of a small store amounts to.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/backup.dart';

/// The manifest's discriminator. A file that does not carry it is not ours.
const String kBackupKind = 'maichat-backup';

/// Bumped when the archive's shape changes in a way a reader must know about.
const int kBackupFormatVersion = 1;

const String kBackupManifestName = 'maichat-backup.json';
const String kBackupPictureFolder = 'pictures';
const String kBackupVectorFolder = 'vectors';

/// Store entries a backup deliberately leaves out.
///
/// The backup settings and the list of backups taken are *about* backups, not
/// data the user authored. Carrying them would mean restoring last month's
/// snapshot disconnected Google Drive and erased every record since — including
/// the record of the restore being read.
const Set<String> kBackupExcludedKeys = <String>{'backupPrefs', 'backups'};

/// The API-key fields inside each entry that holds one, by store key. Used both
/// to strip keys out of an export and to keep live keys when a keyless backup
/// comes back in. Deliberately specific: a blanket search for "key" would blank
/// a vector record's `key`, which is a chunk id.
const Map<String, List<String>> kBackupSecretFields = <String, List<String>>{
  'providers': <String>['apiKey', 'apiKeys'],
  'imageGen': <String>['apiKey'],
  'settings': <String>['apiKey'],
};

/// What went wrong reading an archive, in a sentence fit for a snackbar.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}
/// One stored entry, kept with enough type information to be handed back to
/// `shared_preferences` unchanged.
///
/// Almost everything this app stores is a JSON string, so those are held
/// *decoded* — the manifest then reads as one nested document rather than a map
/// of escaped strings, and a person looking into a backup can see their own
/// chats. The scalars (the active conversation id, the default persona) keep
/// their own type so a restore writes an int back as an int.
class StoreEntry {
  const StoreEntry(this.kind, this.value);

  /// One of `json`, `string`, `int`, `double`, `bool`, `stringList`.
  final String kind;

  /// The decoded JSON for `json`, otherwise the value itself.
  final Object? value;

  /// Classifies a raw `shared_preferences` value. A string that parses as a JSON
  /// object or list becomes [kind] `json`; a string that merely looks numeric
  /// stays a string, because that is how it was stored.
  factory StoreEntry.of(Object? raw) {
    if (raw is String) {
      final trimmed = raw.trimLeft();
      if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map || decoded is List) {
            return StoreEntry('json', decoded);
          }
        } catch (_) {
          // Not JSON after all — keep the string exactly as it is.
        }
      }
      return StoreEntry('string', raw);
    }
    if (raw is bool) return StoreEntry('bool', raw);
    if (raw is int) return StoreEntry('int', raw);
    if (raw is double) return StoreEntry('double', raw);
    if (raw is List) {
      return StoreEntry('stringList', raw.map((e) => e.toString()).toList());
    }
    return StoreEntry('string', raw?.toString() ?? '');
  }

  /// The value to write back into the store.
  Object? get stored => kind == 'json' ? jsonEncode(value) : value;

  /// The entry's decoded JSON as a map, or null when it is not one.
  Map<String, dynamic>? get asMap =>
      kind == 'json' && value is Map ? Map<String, dynamic>.from(value as Map) : null;

  /// The entry's decoded JSON as a list, or null when it is not one.
  List<dynamic>? get asList => kind == 'json' && value is List ? value as List : null;

  Map<String, dynamic> toJson() => {'kind': kind, 'value': value};

  factory StoreEntry.fromJson(Object? json) {
    if (json is Map) {
      final kind = json['kind']?.toString() ?? 'string';
      final value = json['value'];
      if (kind == 'json') return StoreEntry('json', value);
      if (kind == 'bool') return StoreEntry('bool', value == true);
      if (kind == 'int') return StoreEntry('int', (value as num?)?.toInt() ?? 0);
      if (kind == 'double') {
        return StoreEntry('double', (value as num?)?.toDouble() ?? 0);
      }
      if (kind == 'stringList') {
        return StoreEntry(
          'stringList',
          (value as List?)?.map((e) => e.toString()).toList() ?? <String>[],
        );
      }
      return StoreEntry('string', value?.toString() ?? '');
    }
    // A manifest written by hand, or a future shape: treat it as the value.
    return StoreEntry.of(json);
  }
}
/// Everything a backup carries, in memory: the store, the pictures and the
/// vector collections. [encodeBackup] turns one into an archive and
/// [decodeBackup] reads one back.
class BackupSnapshot {
  BackupSnapshot({
    required this.store,
    this.pictures = const <String, Uint8List>{},
    this.vectors = const <String, String>{},
    required this.createdAt,
    this.appVersion = '',
    this.includesKeys = true,
    this.formatVersion = kBackupFormatVersion,
  });

  /// Every store entry the backup holds, by its `shared_preferences` key.
  final Map<String, StoreEntry> store;

  /// Picture files by name, exactly as they sit in the pictures directory. The
  /// names matter: a `local:<name>` reference in a chat resolves by name, so
  /// restoring under the same names is what puts a picture back in its message.
  final Map<String, Uint8List> pictures;

  /// Vector collection files by name (`chat-<id>.json`, `doc-<id>.json`, …).
  final Map<String, String> vectors;

  final DateTime createdAt;
  final String appVersion;

  /// Whether provider API keys are in here in plain text.
  final bool includesKeys;

  final int formatVersion;

  BackupCounts get counts =>
      countStore(store, pictures: pictures.length, vectors: vectors.length);
}

/// Counts what a store holds, for the record kept beside a backup and for the
/// confirmation shown before a restore.
BackupCounts countStore(
  Map<String, StoreEntry> store, {
  int pictures = 0,
  int vectors = 0,
}) {
  int listLength(String key) => store[key]?.asList?.length ?? 0;
  int nestedLength(String key, String field) {
    final map = store[key]?.asMap;
    final list = map?[field];
    return list is List ? list.length : 0;
  }

  var messages = 0;
  for (final chat in store['conversations']?.asList ?? const <dynamic>[]) {
    if (chat is Map && chat['messages'] is List) {
      messages += (chat['messages'] as List).length;
    }
  }

  return BackupCounts(
    characters: listLength('characters'),
    chats: listLength('conversations'),
    messages: messages,
    presets: nestedLength('presets', 'presets'),
    lorebooks: listLength('lorebooks'),
    scenarios: listLength('scenarios'),
    documents: listLength('documents'),
    gallery: listLength('gallery'),
    providers: nestedLength('providers', 'providers'),
    pictures: pictures,
    vectors: vectors,
  );
}
/// The manifest document on its own — the whole backup when there are no files
/// to carry, and the first entry of the zip when there are.
Map<String, dynamic> backupManifest(BackupSnapshot snapshot) => {
      'kind': kBackupKind,
      'formatVersion': kBackupFormatVersion,
      'createdAt': snapshot.createdAt.toIso8601String(),
      if (snapshot.appVersion.isNotEmpty) 'appVersion': snapshot.appVersion,
      'includesKeys': snapshot.includesKeys,
      'counts': snapshot.counts.toJson(),
      'store': {
        for (final entry in snapshot.store.entries)
          entry.key: entry.value.toJson(),
      },
      'pictures': snapshot.pictures.keys.toList(),
      'vectors': snapshot.vectors.keys.toList(),
    };

/// Packs [snapshot] into the zip a user takes away. Compact JSON on purpose:
/// the conversations entry alone can be megabytes, and the archive is deflated
/// anyway, so pretty-printing would buy nothing but encoding time.
Uint8List encodeBackup(BackupSnapshot snapshot) {
  final archive = Archive();
  archive.add(ArchiveFile.string(
    kBackupManifestName,
    jsonEncode(backupManifest(snapshot)),
  ));
  for (final picture in snapshot.pictures.entries) {
    archive.add(ArchiveFile.bytes(
      '$kBackupPictureFolder/${picture.key}',
      picture.value,
    ));
  }
  for (final vector in snapshot.vectors.entries) {
    archive.add(ArchiveFile.string(
      '$kBackupVectorFolder/${vector.key}',
      vector.value,
    ));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// Whether [bytes] begins with a zip's local-file header.
bool looksLikeZip(Uint8List bytes) =>
    bytes.length > 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);

/// Whether [bytes] is one of ours — used by the importer to route a file before
/// committing to a format. Never throws.
bool looksLikeMaiChatBackup(Uint8List bytes) {
  try {
    if (looksLikeZip(bytes)) {
      final archive = ZipDecoder().decodeBytes(bytes);
      return _manifestEntry(archive) != null;
    }
    final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    return json is Map && json['kind'] == kBackupKind;
  } catch (_) {
    return false;
  }
}

ArchiveFile? _manifestEntry(Archive archive) {
  final named = archive.findFile(kBackupManifestName);
  if (named != null) return named;
  // Tolerate a re-zipped or renamed archive: any root-level JSON that carries
  // our discriminator counts as the manifest.
  for (final file in archive.files) {
    if (!file.isFile) continue;
    if (file.name.contains('/') || !file.name.endsWith('.json')) continue;
    final bytes = file.readBytes();
    if (bytes == null) continue;
    try {
      final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      if (json is Map && json['kind'] == kBackupKind) return file;
    } catch (_) {
      // Not the manifest; keep looking.
    }
  }
  return null;
}
/// Reads an archive (or a bare manifest) back into a [BackupSnapshot]. Throws
/// [BackupFormatException] with a sentence worth showing when it is not ours.
BackupSnapshot decodeBackup(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const BackupFormatException('That file is empty.');
  }
  if (!looksLikeZip(bytes)) {
    return _fromManifest(_parseManifest(bytes));
  }
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw BackupFormatException('That archive could not be opened ($error).');
  }
  final manifest = _manifestEntry(archive);
  if (manifest == null) {
    throw const BackupFormatException(
      'That zip has no $kBackupManifestName in it, so it is not a MaiChat '
      'backup.',
    );
  }
  final pictures = <String, Uint8List>{};
  final vectors = <String, String>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = _safeEntryName(file.name, kBackupPictureFolder);
    if (name != null) {
      final data = file.readBytes();
      if (data != null && data.isNotEmpty) pictures[name] = data;
      continue;
    }
    final vector = _safeEntryName(file.name, kBackupVectorFolder);
    if (vector != null) {
      final data = file.readBytes();
      if (data != null && data.isNotEmpty) {
        vectors[vector] = utf8.decode(data, allowMalformed: true);
      }
    }
  }
  return _fromManifest(
    _parseManifest(manifest.readBytes() ?? Uint8List(0)),
    pictures: pictures,
    vectors: vectors,
  );
}

/// The entry's bare file name when it sits directly inside [folder], else null.
/// Anything that tries to climb out of the folder is rejected outright — an
/// archive must not be able to write outside the two directories it owns.
String? _safeEntryName(String entryName, String folder) {
  final prefix = '$folder/';
  if (!entryName.startsWith(prefix)) return null;
  final name = entryName.substring(prefix.length);
  if (name.isEmpty || name.startsWith('.')) return null;
  if (name.contains('/') || name.contains('\\')) return null;
  return name;
}

Map<String, dynamic> _parseManifest(Uint8List bytes) {
  Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } catch (_) {
    throw const BackupFormatException(
      'That file is not a MaiChat backup — it is not even JSON.',
    );
  }
  if (json is! Map<String, dynamic>) {
    throw const BackupFormatException('That file is not a MaiChat backup.');
  }
  if (json['kind'] != kBackupKind) {
    throw const BackupFormatException(
      'That file is not a MaiChat backup. Try the Import screen — it reads '
      'SillyTavern, Agnai and Chub exports too.',
    );
  }
  final version = (json['formatVersion'] as num?)?.toInt() ?? 0;
  if (version > kBackupFormatVersion) {
    throw BackupFormatException(
      'That backup was made by a newer version of MaiChat (format v$version). '
      'Update the app and try again.',
    );
  }
  return json;
}
BackupSnapshot _fromManifest(
  Map<String, dynamic> json, {
  Map<String, Uint8List> pictures = const <String, Uint8List>{},
  Map<String, String> vectors = const <String, String>{},
}) {
  final rawStore = json['store'];
  if (rawStore is! Map) {
    throw const BackupFormatException(
      'That backup has no data in it (no "store" section).',
    );
  }
  final store = <String, StoreEntry>{};
  for (final entry in rawStore.entries) {
    final key = entry.key.toString();
    if (kBackupExcludedKeys.contains(key)) continue;
    store[key] = StoreEntry.fromJson(entry.value);
  }
  return BackupSnapshot(
    store: store,
    pictures: pictures,
    vectors: vectors,
    createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.now(),
    appVersion: json['appVersion'] as String? ?? '',
    includesKeys: json['includesKeys'] as bool? ?? true,
    formatVersion: (json['formatVersion'] as num?)?.toInt() ?? 0,
  );
}

/// A copy of [store] with every API key blanked. The fields are kept rather than
/// removed so a restore can tell "the user chose not to include this key" from
/// "this provider never had one" — see [preserveSecrets].
Map<String, StoreEntry> stripSecrets(Map<String, StoreEntry> store) {
  final out = <String, StoreEntry>{...store};
  for (final target in kBackupSecretFields.entries) {
    final entry = out[target.key];
    if (entry == null || entry.kind != 'json') continue;
    final value = _blankFields(entry.value, target.value);
    out[target.key] = StoreEntry('json', value);
  }
  return out;
}

/// Walks a decoded entry and blanks [fields] wherever they appear — a provider
/// list has them one level down, a settings map has them at the top.
Object? _blankFields(Object? value, List<String> fields) {
  if (value is List) {
    return value.map((item) => _blankFields(item, fields)).toList();
  }
  if (value is Map) {
    final out = <String, dynamic>{};
    for (final entry in value.entries) {
      final key = entry.key.toString();
      if (!fields.contains(key)) {
        out[key] = _blankFields(entry.value, fields);
        continue;
      }
      final current = entry.value;
      out[key] = current is List
          ? current.map((_) => '').toList()
          : '';
    }
    return out;
  }
  return value;
}
/// Fills in blanked API keys in [incoming] from what is live in [current].
///
/// A backup taken with "include API keys" off carries empty key fields. Writing
/// those back would silently un-configure every provider, so an empty incoming
/// key defers to the key already on the device; a non-empty one wins, because
/// that is the whole point of including them.
Map<String, StoreEntry> preserveSecrets({
  required Map<String, StoreEntry> current,
  required Map<String, StoreEntry> incoming,
}) {
  final out = <String, StoreEntry>{...incoming};

  final liveProviders = <String, Map<String, dynamic>>{};
  for (final provider in _nestedList(current['providers'], 'providers')) {
    if (provider is Map && provider['id'] != null) {
      liveProviders[provider['id'].toString()] =
          Map<String, dynamic>.from(provider);
    }
  }
  final incomingProviders = out['providers'];
  final providerMap = incomingProviders?.asMap;
  if (providerMap != null && providerMap['providers'] is List) {
    final list = (providerMap['providers'] as List).map((item) {
      if (item is! Map) return item;
      final next = Map<String, dynamic>.from(item);
      final live = liveProviders[next['id']?.toString() ?? ''];
      if (live == null) return next;
      final keys = (next['apiKeys'] as List?)
              ?.map((k) => k.toString())
              .where((k) => k.trim().isNotEmpty)
              .toList() ??
          const <String>[];
      final single = (next['apiKey'] as String? ?? '').trim();
      if (keys.isEmpty && single.isEmpty) {
        next['apiKey'] = live['apiKey'] ?? '';
        next['apiKeys'] = live['apiKeys'] ?? const <String>[];
      }
      return next;
    }).toList();
    out['providers'] = StoreEntry('json', {...providerMap, 'providers': list});
  }

  for (final key in const ['imageGen', 'settings']) {
    final map = out[key]?.asMap;
    if (map == null) continue;
    final live = current[key]?.asMap;
    final mine = (map['apiKey'] as String? ?? '').trim();
    final theirs = (live?['apiKey'] as String? ?? '').trim();
    if (mine.isEmpty && theirs.isNotEmpty) {
      out[key] = StoreEntry('json', {...map, 'apiKey': theirs});
    }
  }
  return out;
}

List<dynamic> _nestedList(StoreEntry? entry, String field) {
  final map = entry?.asMap;
  final list = map?[field];
  return list is List ? list : const <dynamic>[];
}
/// The store keys that hold a plain list of things with an `id` — the ones a
/// merge can reconcile item by item.
const List<String> kBackupIdLists = <String>[
  'characters',
  'conversations',
  'lorebooks',
  'scenarios',
  'gallery',
  'documents',
];

/// The keys that hold a list nested inside an envelope, and the field it sits
/// under. The envelope's other fields (`activeId`, `defaultId`) point at one of
/// the items, so a merge keeps the device's own choice rather than the file's.
const Map<String, String> kBackupNestedLists = <String, String>{
  'providers': 'providers',
  'presets': 'presets',
};

/// Adds what is in [incoming] to what is already on the device, instead of
/// replacing it.
///
/// Lists reconcile by id: an item the file and the device both have is taken
/// from the file (it is the newer intent — the user just asked to import it),
/// one only the device has is kept, one only the file has is appended. Settings
/// and preferences are *not* touched, because "import my characters from that
/// backup" should not also re-theme the app.
Map<String, StoreEntry> mergeStores(
  Map<String, StoreEntry> current,
  Map<String, StoreEntry> incoming,
) {
  final out = <String, StoreEntry>{...current};

  for (final key in kBackupIdLists) {
    final theirs = incoming[key]?.asList;
    if (theirs == null) continue;
    out[key] = StoreEntry('json', _mergeById(out[key]?.asList, theirs));
  }

  for (final target in kBackupNestedLists.entries) {
    final theirMap = incoming[target.key]?.asMap;
    if (theirMap == null) continue;
    final theirs = theirMap[target.value];
    if (theirs is! List) continue;
    final mineMap = out[target.key]?.asMap ?? <String, dynamic>{};
    final merged = _mergeById(
      mineMap[target.value] is List
          ? mineMap[target.value] as List<dynamic>
          : null,
      theirs,
    );
    // The device's own pointers win — but only where it has one. A first import
    // into an app with no providers at all should adopt the file's active id
    // rather than end up with a list and nothing selected.
    final mineFields = {...mineMap}..removeWhere(
        (key, value) => value == null || (value is String && value.isEmpty));
    out[target.key] = StoreEntry('json', {
      ...theirMap,
      ...mineFields,
      target.value: merged,
    });
  }

  // A key the device has never written (the image studio on a fresh install,
  // say) is taken from the file; anything already set is left alone.
  for (final entry in incoming.entries) {
    if (out.containsKey(entry.key)) continue;
    if (kBackupExcludedKeys.contains(entry.key)) continue;
    out[entry.key] = entry.value;
  }
  return out;
}

/// Reconciles two lists of `{id: …}` maps: the device's order is kept, an id in
/// both takes the incoming version, and the rest are appended in file order.
List<dynamic> _mergeById(List<dynamic>? mine, List<dynamic> theirs) {
  final byId = <String, Map<String, dynamic>>{};
  for (final item in theirs) {
    if (item is Map && item['id'] != null) {
      byId[item['id'].toString()] = Map<String, dynamic>.from(item);
    }
  }
  final out = <dynamic>[];
  final used = <String>{};
  for (final item in mine ?? const <dynamic>[]) {
    final id = item is Map ? item['id']?.toString() : null;
    if (id != null && byId.containsKey(id)) {
      out.add(byId[id]);
      used.add(id);
    } else {
      out.add(item);
    }
  }
  for (final item in theirs) {
    final id = item is Map ? item['id']?.toString() : null;
    if (id == null || used.contains(id)) continue;
    out.add(byId[id]);
    used.add(id);
  }
  return out;
}
