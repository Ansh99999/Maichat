/// Reads a backup another app wrote — SillyTavern, Agnai, Chub/Venus — and turns
/// it into the things this app holds.
///
/// Two facts shape this file.
///
/// **Nothing is held in memory that does not have to be.** A SillyTavern data
/// folder is the largest file this app will ever be handed: hundreds of
/// megabytes of card art, generated pictures and wallpapers. Reading that into a
/// byte array — which is what a naive import does — is not slow, it is *fatal*:
/// Android kills the process and the app looks like it crashed for no reason. So
/// the archive is opened from disk and walked entry by entry, and every picture
/// is written straight into the pictures directory through [PictureStore] as it
/// is read. What stays in memory is text and file references.
///
/// **The layout is SillyTavern's real one**, taken from its own
/// `USER_DIRECTORY_TEMPLATE` (`src/constants.js`) and from the endpoints that
/// write each file:
///
/// | in the backup | becomes |
/// |---|---|
/// | `characters/<file>.png` | a character, its portrait, its tags |
/// | `chats/<file>/*.jsonl` | that character's chats — the folder is named after the *card file*, which is the only record of the binding (`chats.js`: `avatar_url` minus `.png`) |
/// | `groups/*.json` + `group chats/*.jsonl` | group chats, members and all |
/// | `worlds/*.json` | lorebooks |
/// | `OpenAI Settings/*.json` | presets |
/// | `settings.json` | personas (`power_user.personas`), their descriptions and pictures, which one is default, and the tag names in `tags`/`tag_map` |
/// | `User Avatars/*.png` | the personas' pictures |
/// | `user/images/**`, `backgrounds/*` | gallery pictures |
/// | `extra.media` on a turn | the pictures in the transcript, put back on the turn that carried them |
///
/// Everything else in there (themes, moving UI, quick replies, extensions,
/// vectors, thumbnails, secrets) has no home in this app and is counted and
/// reported rather than silently dropped.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/character.dart';
import '../models/lorebook.dart';
import '../models/preset.dart';
import '../models/provider.dart';
import '../models/scenario.dart';
import 'character_codec.dart';
import 'chat_codec.dart';
import 'lorebook_codec.dart';
import 'preset_io.dart';
import 'scenario_codec.dart';
/// Writes a picture into the app's pictures directory and returns the
/// `local:<file>` reference to keep, or null when there is nowhere to put it.
///
/// Injected rather than imported so this file never touches the filesystem
/// itself: the caller owns the pictures directory, and a test can hand in a fake
/// that counts what it was given.
typedef PictureStore = Future<String?> Function(Uint8List bytes);

/// Which app the file appears to have come from — shown in the import summary.
enum ForeignSource {
  agnai('Agnai'),
  sillyTavern('SillyTavern'),
  chub('Chub / Venus'),
  archive('An archive of files'),
  file('A single file');

  const ForeignSource(this.label);
  final String label;
}

/// One chat that came out of a backup, with the bindings a foreign file records
/// by name rather than by id.
class ForeignChat {
  ForeignChat({
    required this.chat,
    this.characterName = '',
    this.participantNames = const <String>[],
  });

  final ImportedChat chat;

  /// Whose chat it is. Ids from another app mean nothing here, so the binding
  /// travels as a name and is resolved against the roster on the way in.
  final String characterName;

  /// For a group chat, everyone in it — again by name.
  final List<String> participantNames;

  int get messageCount => chat.messageCount;
}

/// A picture that came with the backup and belongs in the gallery. Already a
/// file by the time it gets here: [ref] is a `local:` reference.
class ForeignPicture {
  const ForeignPicture({
    required this.ref,
    this.title = '',
    this.characterName = '',
    this.tags = const <String>[],
  });

  final String ref;
  final String title;
  final String characterName;
  final List<String> tags;
}
/// Everything recognised in a foreign backup, ready to be added.
class ForeignBackup {
  ForeignBackup({required this.source});

  final ForeignSource source;
  final List<Character> characters = <Character>[];
  final List<ForeignChat> chats = <ForeignChat>[];
  final List<Lorebook> lorebooks = <Lorebook>[];
  final List<Scenario> scenarios = <Scenario>[];
  final List<Preset> presets = <Preset>[];
  final List<Provider> providers = <Provider>[];
  final List<ForeignPicture> pictures = <ForeignPicture>[];

  /// The characters among [characters] that were the user's personas, not
  /// somebody to talk to — and which one was in use.
  final Set<String> personaNames = <String>{};
  String defaultPersonaName = '';

  /// What was in the file and has no home here, by kind: `{'themes': 12}`. Kept
  /// as counts rather than a line per file, because a data folder holds
  /// thousands of files and a wall of notes tells the user nothing.
  final Map<String, int> skipped = <String, int>{};

  /// Things that went wrong while reading, one line each (capped).
  final List<String> notes = <String>[];

  int get messages => chats.fold(0, (sum, chat) => sum + chat.messageCount);

  bool get isEmpty =>
      characters.isEmpty &&
      chats.isEmpty &&
      lorebooks.isEmpty &&
      scenarios.isEmpty &&
      presets.isEmpty &&
      providers.isEmpty &&
      pictures.isEmpty;

  /// A one-line "3 characters · 12 chats · 400 messages" for the confirmation.
  String summary() {
    final parts = <String>[
      if (characters.isNotEmpty) _plural(characters.length, 'character'),
      if (personaNames.isNotEmpty) '${personaNames.length} of them personas',
      if (chats.isNotEmpty) _plural(chats.length, 'chat'),
      if (messages > 0) _plural(messages, 'message'),
      if (lorebooks.isNotEmpty) _plural(lorebooks.length, 'lorebook'),
      if (scenarios.isNotEmpty) _plural(scenarios.length, 'scenario'),
      if (presets.isNotEmpty) _plural(presets.length, 'preset'),
      if (providers.isNotEmpty) _plural(providers.length, 'provider'),
      if (pictures.isNotEmpty) _plural(pictures.length, 'picture'),
    ];
    return parts.isEmpty ? 'Nothing recognised' : parts.join(' · ');
  }

  /// "Left out: 12 themes, 3 extensions" — the honest half of the summary.
  String? leftOut() {
    if (skipped.isEmpty) return null;
    final parts = skipped.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return 'Left out: ${parts.take(6).map((e) => '${e.value} ${e.key}').join(', ')}';
  }

  static String _plural(int count, String noun) =>
      '$count ${count == 1 ? noun : '${noun}s'}';

  /// Folds another file's findings into this one, so a multi-file import is
  /// applied once — which matters because a chat binds to a character by name,
  /// and the characters have to be in place before the chats arrive.
  void absorb(ForeignBackup other) {
    characters.addAll(other.characters);
    chats.addAll(other.chats);
    lorebooks.addAll(other.lorebooks);
    scenarios.addAll(other.scenarios);
    presets.addAll(other.presets);
    providers.addAll(other.providers);
    pictures.addAll(other.pictures);
    personaNames.addAll(other.personaNames);
    if (defaultPersonaName.isEmpty) defaultPersonaName = other.defaultPersonaName;
    other.skipped.forEach((kind, count) {
      skipped[kind] = (skipped[kind] ?? 0) + count;
    });
    for (final note in other.notes) {
      if (!notes.contains(note)) notes.add(note);
    }
  }

  void note(String message) {
    if (notes.length < 6) {
      notes.add(message);
    } else if (notes.length == 6) {
      notes.add('…and more that could not be read.');
    }
  }

  void skip(String kind, [int count = 1]) =>
      skipped[kind] = (skipped[kind] ?? 0) + count;
}
/// Reads the backup at [path]. The archive is opened from disk and never held in
/// memory whole; [storePicture] receives each picture as it is found.
///
/// Throws [FormatException] with a sentence worth showing when there is nothing
/// recognisable in there.
Future<ForeignBackup> readForeignBackupFile(
  String path, {
  String fileName = '',
  PictureStore? storePicture,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw const FormatException('That file is no longer there.');
  }
  final name = fileName.isEmpty ? _basename(path) : fileName;
  if (_isZip(await _head(file))) {
    final input = InputFileStream(path);
    try {
      final Archive archive;
      try {
        archive = ZipDecoder().decodeStream(input);
      } catch (error) {
        throw FormatException('That archive could not be opened ($error).');
      }
      return _orThrow(await _readArchive(archive, storePicture));
    } finally {
      await input.close();
    }
  }
  return readForeignBackupBytes(
    await file.readAsBytes(),
    fileName: name,
    storePicture: storePicture,
  );
}

/// The same, for bytes already in hand — a small single file, or a platform that
/// would not give a path.
Future<ForeignBackup> readForeignBackupBytes(
  Uint8List bytes, {
  String fileName = '',
  PictureStore? storePicture,
}) async {
  if (bytes.isEmpty) throw const FormatException('That file is empty.');
  if (_isZip(bytes)) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (error) {
      throw FormatException('That archive could not be opened ($error).');
    }
    return _orThrow(await _readArchive(archive, storePicture));
  }
  // One JSON document can be a whole Agnai backup — it says so at the top, and
  // it is worth saying which app the import came from.
  Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes, allowMalformed: true).trim());
  } catch (_) {
    json = null;
  }
  if (json is Map<String, dynamic> && _looksAgnaiBackup(json)) {
    final agnai = ForeignBackup(source: ForeignSource.agnai);
    await _readAgnai(agnai, json, null, storePicture);
    return _orThrow(agnai);
  }
  final backup = ForeignBackup(source: ForeignSource.file);
  await _readOne(
    backup,
    bytes,
    fileName.isEmpty ? 'file' : fileName,
    storePicture,
    lenient: true,
  );
  return _orThrow(backup);
}

ForeignBackup _orThrow(ForeignBackup backup) {
  if (backup.isEmpty) {
    throw const FormatException(
      'Nothing in there looked like characters, chats, lorebooks, scenarios or '
      'presets.',
    );
  }
  return backup;
}

Future<Uint8List> _head(File file, [int length = 4]) async {
  final handle = await file.open();
  try {
    return await handle.read(length);
  } finally {
    await handle.close();
  }
}

bool _isZip(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x50 &&
    bytes[1] == 0x4B &&
    (bytes[2] == 0x03 || bytes[2] == 0x05 || bytes[2] == 0x07);
/// The folders a SillyTavern user directory is made of, from its own
/// `USER_DIRECTORY_TEMPLATE`. Lower-cased because a zip made on Windows and one
/// made by its own exporter do not always agree on case.
const Set<String> _stFolders = <String>{
  'characters',
  'chats',
  'groups',
  'group chats',
  'worlds',
  'user avatars',
  'user',
  'backgrounds',
  'openai settings',
  'textgen settings',
  'novelai settings',
  'koboldai settings',
  'instruct',
  'context',
  'sysprompt',
  'reasoning',
  'themes',
  'movingui',
  'quickreplies',
  'assets',
  'vectors',
  'backups',
  'thumbnails',
  'extensions',
};

/// An archive's entries, addressable the way SillyTavern's own layout addresses
/// them: `characters/Aqua.png`, whatever the zip wrapped them in.
///
/// A backup made by SillyTavern itself has those at the root; one a person made
/// by hand has `SillyTavern/data/default-user/` in front. Both are the same
/// backup, so the prefix is found and dropped once, here.
class _ArchiveIndex {
  _ArchiveIndex(this.archive) {
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (name.isEmpty || _basename(name).startsWith('.')) continue;
      final relative = _relativise(name);
      _entries[relative] = entry;
      final slash = relative.indexOf('/');
      if (slash > 0) {
        _byFolder
            .putIfAbsent(relative.substring(0, slash).toLowerCase(), () => [])
            .add(relative);
      } else {
        _root.add(relative);
      }
    }
  }

  final Archive archive;
  final Map<String, ArchiveFile> _entries = <String, ArchiveFile>{};
  final Map<String, List<String>> _byFolder = <String, List<String>>{};
  final List<String> _root = <String>[];

  static String _relativise(String name) {
    final parts = name.split('/');
    for (var i = 0; i < parts.length - 1; i++) {
      if (_stFolders.contains(parts[i].toLowerCase())) {
        return parts.sublist(i).join('/');
      }
    }
    return name;
  }

  Iterable<String> get paths => _entries.keys;

  /// The entry paths directly or deeply inside [folder].
  List<String> under(String folder) =>
      _byFolder[folder.toLowerCase()] ?? const <String>[];

  /// A root-level file by name, wherever the archive kept it.
  ArchiveFile? root(String name) {
    final lower = name.toLowerCase();
    for (final path in _root) {
      if (path.toLowerCase() == lower) return _entries[path];
    }
    // A hand-made zip may leave settings.json one level down beside the folders.
    for (final path in _entries.keys) {
      if (_basename(path).toLowerCase() == lower) return _entries[path];
    }
    return null;
  }

  ArchiveFile? at(String path) => _entries[path];

  /// An entry by path, ignoring case — a zip written on Windows and one written
  /// by a Linux server disagree about `User Avatars` often enough to matter.
  ArchiveFile? find(String path) {
    final direct = _entries[path];
    if (direct != null) return direct;
    final lower = path.toLowerCase();
    for (final entry in _entries.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  /// An entry whose *file name* matches. A reference inside a backup points
  /// wherever the other app kept the file (`/assets/x.png`, `user/images/x.png`),
  /// which is not always where the archive kept it.
  ArchiveFile? findByName(String name) {
    final lower = _basename(name).toLowerCase();
    if (lower.isEmpty) return null;
    for (final entry in _entries.entries) {
      if (_basename(entry.key).toLowerCase() == lower) return entry.value;
    }
    return null;
  }

  Uint8List? bytes(String path) => _entries[path]?.readBytes();

  String? text(String path) {
    final data = bytes(path);
    return data == null ? null : utf8.decode(data, allowMalformed: true);
  }
}
Future<ForeignBackup> _readArchive(
  Archive archive,
  PictureStore? storePicture,
) async {
  final index = _ArchiveIndex(archive);
  // Agnai says what it is in a manifest, so it is asked first and cheaply.
  final agnai = _agnaiManifest(index);
  if (agnai != null) {
    final backup = ForeignBackup(source: ForeignSource.agnai);
    await _readAgnai(backup, agnai, index, storePicture);
    return backup;
  }
  final settings = _sillyTavernSettings(index);
  if (settings != null || _looksSillyTavern(index)) {
    return _readSillyTavern(index, settings, storePicture);
  }
  return _readLoose(index, storePicture);
}

Map<String, dynamic>? _agnaiManifest(_ArchiveIndex index) {
  for (final path in index.paths) {
    if (!path.toLowerCase().endsWith('.json')) continue;
    if (path.split('/').length > 2) continue;
    final text = index.text(path);
    if (text == null) continue;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic> && _looksAgnaiBackup(json)) return json;
    } catch (_) {
      // Not JSON, or not a manifest: keep looking.
    }
  }
  return null;
}

bool _looksAgnaiBackup(Map<String, dynamic> json) =>
    json['kind'] == 'agnai-user-backup' ||
    (json['characters'] is List &&
        (json['chats'] is List || json['presets'] is List));

/// SillyTavern's `settings.json`, decoded, when the archive has one. It is the
/// strongest signal there is: nothing else writes a `power_user` block.
Map<String, dynamic>? _sillyTavernSettings(_ArchiveIndex index) {
  final entry = index.root('settings.json');
  final bytes = entry?.readBytes();
  if (bytes == null) return null;
  try {
    final json = jsonDecode(utf8.decode(bytes, allowMalformed: true));
    if (json is Map<String, dynamic> &&
        (json.containsKey('power_user') || json.containsKey('oai_settings'))) {
      return json;
    }
  } catch (_) {
    // A settings file we cannot read is not a reason to reject the backup.
  }
  return null;
}

/// Two independent signs of a SillyTavern data folder. Two, because a single
/// folder called `characters` or `assets` is not evidence of anything.
bool _looksSillyTavern(_ArchiveIndex index) {
  var marks = 0;
  if (index.under('characters').isNotEmpty) marks++;
  if (index.under('chats').isNotEmpty) marks++;
  if (index.under('worlds').isNotEmpty) marks++;
  if (index.under('openai settings').isNotEmpty) marks++;
  if (index.under('user avatars').isNotEmpty) marks++;
  // Nothing else in this world has a folder called "group chats".
  if (index.under('group chats').isNotEmpty) marks += 2;
  return marks >= 2;
}
/// Reads a SillyTavern user directory.
///
/// Order matters: the cards are read first because everything else in the folder
/// refers to a character by its *card file name* — the chats are in a folder
/// named after it, the tags are keyed by it, a group lists its members by it.
Future<ForeignBackup> _readSillyTavern(
  _ArchiveIndex index,
  Map<String, dynamic>? settings,
  PictureStore? store,
) async {
  final backup = ForeignBackup(source: ForeignSource.sillyTavern);
  final pictures = _Pictures(index, store);
  final byCard = <String, Character>{};

  for (final path in index.under('characters')) {
    final data = index.bytes(path);
    if (data == null || data.isEmpty) continue;
    final stem = _stem(path);
    try {
      final cards = CharacterCodec.parseCards(data, filename: stem);
      for (final card in cards) {
        await _storeAvatar(card, pictures);
        backup.characters.add(card);
      }
      if (cards.length == 1) byCard[stem.toLowerCase()] = cards.single;
      // A card can carry its own lorebook. This app keeps books separately, so
      // it becomes one rather than being dropped with the rest of the wrapper.
      _readCardBook(backup, data, stem);
    } catch (_) {
      backup.skip('unreadable character cards');
    }
  }

  if (settings != null) {
    await _readSettings(backup, settings, byCard, pictures);
  }

  for (final path in index.under('worlds')) {
    if (!path.toLowerCase().endsWith('.json')) continue;
    _addLorebooks(backup, index.text(path) ?? '', _stem(path));
  }

  for (final path in index.under('openai settings')) {
    if (!path.toLowerCase().endsWith('.json')) continue;
    final text = index.text(path);
    if (text == null) continue;
    try {
      final json = jsonDecode(text);
      if (json is Map<String, dynamic>) _addPreset(backup, json, _stem(path));
    } catch (_) {
      backup.skip('unreadable presets');
    }
  }

  await _readSillyTavernChats(backup, index, byCard, pictures);
  await _readSillyTavernGroups(backup, index, byCard, pictures);
  await _readSillyTavernPictures(backup, index, byCard, pictures);
  _countTheRest(backup, index);
  return backup;
}
/// Pictures already written out, by the archive path they came from.
///
/// A picture in `user/images` is usually *both* an attachment on a turn and a
/// picture in the gallery. Without this it would be written twice and the app
/// would hold two copies of every generated image.
class _Pictures {
  _Pictures(this.index, this.store);

  final _ArchiveIndex index;
  final PictureStore? store;
  final Map<String, String?> _done = <String, String?>{};

  bool get enabled => store != null;

  /// The `local:` reference for the picture at [path] (or whose file name
  /// matches), writing it out the first time it is asked for.
  Future<String?> ref(String path) async {
    final store = this.store;
    if (store == null) return null;
    final key = path.trim();
    if (key.isEmpty) return null;
    if (_done.containsKey(key)) return _done[key];
    final entry = index.find(key) ?? index.findByName(key);
    final bytes = entry?.readBytes();
    if (bytes == null || bytes.isEmpty) return _done[key] = null;
    try {
      return _done[key] = await store(bytes);
    } catch (_) {
      return _done[key] = null;
    }
  }

  /// Writes [bytes] that are not an archive entry (a card's own portrait).
  Future<String?> add(Uint8List bytes) async {
    final store = this.store;
    if (store == null || bytes.isEmpty) return null;
    try {
      return await store(bytes);
    } catch (_) {
      return null;
    }
  }
}

/// Moves a freshly parsed card's portrait out of base64 and into a file. The
/// base64 exists for one moment, on one card, and never reaches the store — the
/// same rule the rest of the app follows.
Future<void> _storeAvatar(Character card, _Pictures pictures) async {
  final avatar = card.avatar.trim();
  if (!pictures.enabled || avatar.isEmpty) return;
  if (avatar.startsWith('http://') ||
      avatar.startsWith('https://') ||
      avatar.startsWith('local:')) {
    return;
  }
  try {
    final ref = await pictures.add(base64Decode(avatar));
    card.avatar = ref ?? '';
  } catch (_) {
    // Not base64 after all (an asset path Agnai wrote): nothing to keep.
    card.avatar = '';
  }
}
/// Reads `settings.json`: the personas (which SillyTavern keeps as a map of
/// avatar file to name, with the descriptions beside it), which persona was in
/// use, and the tag names the user pinned onto their cards.
///
/// A persona is exactly what this app calls a character used as the user's own
/// identity, so each one becomes a character and the default one is remembered.
Future<void> _readSettings(
  ForeignBackup backup,
  Map<String, dynamic> settings,
  Map<String, Character> byCard,
  _Pictures pictures,
) async {
  final power = settings['power_user'];
  if (power is Map) {
    final personas = power['personas'];
    final descriptions = power['persona_descriptions'];
    final defaultKey = power['default_persona']?.toString() ?? '';
    if (personas is Map) {
      for (final entry in personas.entries) {
        final avatarKey = entry.key.toString();
        final name = entry.value?.toString().trim() ?? '';
        if (name.isEmpty) continue;
        final meta = descriptions is Map ? descriptions[avatarKey] : null;
        final persona = Character(
          id: _freshId(),
          name: name,
          description:
              meta is Map ? (meta['description']?.toString() ?? '') : '',
          creatorNotes: meta is Map ? (meta['title']?.toString() ?? '') : '',
        );
        final ref = await pictures.ref('User Avatars/$avatarKey');
        if (ref != null) persona.avatar = ref;
        backup.characters.add(persona);
        backup.personaNames.add(persona.displayName);
        if (avatarKey == defaultKey) {
          backup.defaultPersonaName = persona.displayName;
        }
      }
    }
  }

  // Tags live apart from the cards: a list of {id, name} plus a map of card file
  // to tag ids. Nothing here has ids, so the names go onto the card itself.
  final names = <String, String>{};
  for (final tag in (settings['tags'] as List? ?? const <dynamic>[])) {
    if (tag is Map && tag['id'] != null) {
      final name = tag['name']?.toString().trim() ?? '';
      if (name.isNotEmpty) names[tag['id'].toString()] = name;
    }
  }
  final map = settings['tag_map'];
  if (names.isEmpty || map is! Map) return;
  map.forEach((key, ids) {
    final card = byCard[_stem(key.toString()).toLowerCase()];
    if (card == null || ids is! List) return;
    final extra = <String>[
      for (final id in ids)
        if (names[id.toString()] != null) names[id.toString()]!,
    ]..removeWhere(card.tags.contains);
    if (extra.isNotEmpty) card.tags = <String>[...card.tags, ...extra];
  });
}
/// `chats/<card file>/<name>.jsonl` — one folder per character, named after the
/// card *file* rather than the card's name (`chats.js` builds the path from
/// `avatar_url` minus `.png`). That folder is the only record of which character
/// a chat belongs to, which is why the cards are read first.
Future<void> _readSillyTavernChats(
  ForeignBackup backup,
  _ArchiveIndex index,
  Map<String, Character> byCard,
  _Pictures pictures,
) async {
  for (final path in index.under('chats')) {
    if (!path.toLowerCase().endsWith('.jsonl')) {
      backup.skip('other files beside the chats');
      continue;
    }
    final text = index.text(path);
    if (text == null || text.trim().isEmpty) continue;
    final parts = path.split('/');
    final folder = parts.length >= 3 ? parts[parts.length - 2] : '';
    final owner = byCard[folder.toLowerCase()];
    await _addSillyTavernChat(
      backup,
      text: text,
      index: index,
      pictures: pictures,
      title: _stem(path),
      characterName: owner?.displayName ?? folder,
    );
  }
}

/// `groups/<id>.json` holds the members (again by card file) and the ids of its
/// chats; `group chats/<id>.jsonl` is the transcript. Both halves are needed:
/// the transcript alone cannot say who was in the room.
Future<void> _readSillyTavernGroups(
  ForeignBackup backup,
  _ArchiveIndex index,
  Map<String, Character> byCard,
  _Pictures pictures,
) async {
  final byChatId = <String, Map<String, dynamic>>{};
  for (final path in index.under('groups')) {
    if (!path.toLowerCase().endsWith('.json')) continue;
    final text = index.text(path);
    if (text == null) continue;
    try {
      final json = jsonDecode(text);
      if (json is! Map<String, dynamic>) continue;
      for (final id in (json['chats'] as List? ?? const <dynamic>[])) {
        byChatId[id.toString()] = json;
      }
      final current = json['chat_id']?.toString() ?? '';
      if (current.isNotEmpty) byChatId[current] = json;
    } catch (_) {
      backup.skip('unreadable groups');
    }
  }

  for (final path in index.under('group chats')) {
    if (!path.toLowerCase().endsWith('.jsonl')) continue;
    final text = index.text(path);
    if (text == null || text.trim().isEmpty) continue;
    final group = byChatId[_stem(path)];
    final members = <String>[
      for (final member in (group?['members'] as List? ?? const <dynamic>[]))
        if (byCard[_stem(member.toString()).toLowerCase()] != null)
          byCard[_stem(member.toString()).toLowerCase()]!.displayName,
    ];
    await _addSillyTavernChat(
      backup,
      text: text,
      index: index,
      pictures: pictures,
      title: group?['name']?.toString() ?? _stem(path),
      characterName: members.isEmpty ? '' : members.first,
      participantNames: members,
    );
  }
}
Future<void> _addSillyTavernChat(
  ForeignBackup backup, {
  required String text,
  required _ArchiveIndex index,
  required _Pictures pictures,
  required String title,
  required String characterName,
  List<String> participantNames = const <String>[],
}) async {
  final resolved = await _resolveChatMedia(text, pictures);
  try {
    for (final chat in ChatCodec.parse(resolved, fileName: title)) {
      backup.chats.add(ForeignChat(
        chat: chat,
        characterName: characterName.isNotEmpty
            ? characterName
            : chat.conversation.characterName ?? '',
        participantNames: participantNames,
      ));
    }
  } on FormatException catch (error) {
    backup.note('Skipped the chat "$title" — ${error.message}');
  } catch (_) {
    backup.skip('unreadable chats');
  }
}

/// Rewrites the picture references inside a transcript so they point at files in
/// this app instead of paths in somebody else's folder.
///
/// SillyTavern keeps a turn's pictures in `extra.media[].url` (and, in files
/// written by older builds, `extra.image` and `extra.image_swipes`), each a path
/// like `user/images/Aqua/00042.png`. Resolving them here — before the transcript
/// is parsed — is what puts a generated picture back in the message that made it.
Future<String> _resolveChatMedia(String text, _Pictures pictures) async {
  if (!pictures.enabled || !text.contains('"extra"')) return text;
  final lines = <String>[];
  var changed = false;
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    Object? json;
    try {
      json = jsonDecode(trimmed);
    } catch (_) {
      lines.add(trimmed);
      continue;
    }
    if (json is! Map<String, dynamic>) {
      lines.add(trimmed);
      continue;
    }
    if (await _rewriteMedia(json, pictures)) changed = true;
    lines.add(jsonEncode(json));
  }
  return changed ? lines.join('\n') : text;
}

Future<bool> _rewriteMedia(
  Map<String, dynamic> turn,
  _Pictures pictures,
) async {
  final extra = turn['extra'];
  if (extra is! Map) return false;
  var changed = false;

  final media = extra['media'];
  if (media is List) {
    for (final item in media) {
      if (item is! Map) continue;
      final type = item['type']?.toString() ?? 'image';
      final url = item['url']?.toString() ?? '';
      if (type != 'image' || url.isEmpty) continue;
      final ref = await pictures.ref(url);
      if (ref != null) {
        item['url'] = ref;
        changed = true;
      }
    }
  }
  final single = extra['image'];
  if (single is String && single.isNotEmpty) {
    final ref = await pictures.ref(single);
    if (ref != null) {
      extra['image'] = ref;
      changed = true;
    }
  }
  final swipes = extra['image_swipes'];
  if (swipes is List) {
    for (var i = 0; i < swipes.length; i++) {
      final url = swipes[i];
      if (url is! String || url.isEmpty) continue;
      final ref = await pictures.ref(url);
      if (ref != null) {
        swipes[i] = ref;
        changed = true;
      }
    }
  }
  return changed;
}
/// `user/images/**` — everything the user generated or uploaded in a chat, which
/// SillyTavern files under the character's name. These are worth having as
/// gallery pictures whether or not a message still points at them.
Future<void> _readSillyTavernPictures(
  ForeignBackup backup,
  _ArchiveIndex index,
  Map<String, Character> byCard,
  _Pictures pictures,
) async {
  if (!pictures.enabled) return;
  for (final path in index.under('user')) {
    final lower = path.toLowerCase();
    if (!lower.startsWith('user/images/')) continue;
    if (!_isPictureName(lower)) continue;
    final ref = await pictures.ref(path);
    if (ref == null) continue;
    final parts = path.split('/');
    final folder = parts.length >= 4 ? parts[parts.length - 2] : '';
    final owner = byCard[folder.toLowerCase()];
    backup.pictures.add(ForeignPicture(
      ref: ref,
      title: _stem(path),
      characterName: owner?.displayName ?? '',
      tags: const <String>['sillytavern'],
    ));
  }
}

/// Everything in a data folder this app has no home for, counted by kind. The
/// point is to be able to say so: a silent omission looks like a bug, and a line
/// per file looks like a wall.
void _countTheRest(ForeignBackup backup, _ArchiveIndex index) {
  const homeless = <String, String>{
    'themes': 'interface themes',
    'movingui': 'window layouts',
    'quickreplies': 'quick replies',
    'assets': 'extension assets',
    'vectors': 'vector caches',
    'thumbnails': 'thumbnails',
    'extensions': 'extensions',
    'instruct': 'instruct templates',
    'context': 'context templates',
    'sysprompt': 'system prompts',
    'reasoning': 'reasoning templates',
    'textgen settings': 'text-completion presets',
    'novelai settings': 'NovelAI presets',
    'koboldai settings': 'KoboldAI presets',
    'backups': 'chat backups',
    'backgrounds': 'background pictures',
  };
  homeless.forEach((folder, label) {
    final count = index.under(folder).length;
    if (count > 0) backup.skip(label, count);
  });
  // The secrets file is the one thing that is deliberately not read: API keys
  // belong wherever the user put them, not carried across by an import.
  if (index.root('secrets.json') != null) backup.skip('API keys (not read)');
}
/// Reads an Agnai account or guest backup: `characters`, `chats` with `messages`
/// keyed by chat id, `books`/`memory`, `scenarios`, `presets`, `gallery`, and the
/// provider list on the user document. Its pictures sit in `assets/`.
Future<void> _readAgnai(
  ForeignBackup backup,
  Map<String, dynamic> json,
  _ArchiveIndex? index,
  PictureStore? store,
) async {
  final pictures = _Pictures(index ?? _ArchiveIndex(Archive()), store);
  List<Map<String, dynamic>> maps(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const <Map<String, dynamic>>[];

  final namesById = <String, String>{};
  for (final map in maps(json['characters'])) {
    final before = backup.characters.length;
    await _addCharacter(backup, map, _agnaiName(map), pictures);
    if (backup.characters.length > before) {
      final id = map['_id']?.toString() ?? '';
      if (id.isNotEmpty) namesById[id] = backup.characters.last.displayName;
    }
  }

  // Agnai keys messages by chat id; very old exports used one flat list.
  final byChat = <String, List<Map<String, dynamic>>>{};
  final rawMessages = json['messages'];
  if (rawMessages is Map) {
    for (final entry in rawMessages.entries) {
      byChat[entry.key.toString()] = maps(entry.value);
    }
  } else if (rawMessages is List) {
    for (final message in maps(rawMessages)) {
      final chatId = message['chatId']?.toString() ?? '';
      if (chatId.isEmpty) continue;
      (byChat[chatId] ??= <Map<String, dynamic>>[]).add(message);
    }
  }

  for (final chat in maps(json['chats'])) {
    final id = chat['_id']?.toString() ?? '';
    final name = (chat['name']?.toString() ?? '').trim();
    final envelope = <String, Object?>{
      if (name.isNotEmpty) 'name': name,
      if (chat['greeting'] != null) 'greeting': chat['greeting'],
      if (chat['scenario'] != null) 'scenario': chat['scenario'],
      'messages': byChat[id] ?? const <Map<String, dynamic>>[],
    };
    final owner = namesById[chat['characterId']?.toString() ?? ''] ?? '';
    try {
      for (final imported in ChatCodec.parse(
        jsonEncode(envelope),
        fileName: name.isEmpty ? 'Chat' : name,
      )) {
        backup.chats.add(ForeignChat(
          chat: imported,
          characterName: owner,
        ));
      }
    } on FormatException catch (error) {
      backup.note('Skipped the chat "$name" — ${error.message}');
    }
  }

  for (final book in maps(json['books'] ?? json['memory'])) {
    _addLorebooks(backup, jsonEncode(book), _agnaiName(book));
  }
  for (final scenario in maps(json['scenarios'] ?? json['scenario'])) {
    _addScenarios(backup, jsonEncode(scenario), _agnaiName(scenario));
  }
  for (final preset in maps(json['presets'])) {
    _addPreset(backup, preset, _agnaiName(preset));
  }
  for (final image in maps(json['gallery'])) {
    final ref = await pictures.ref(image['image']?.toString() ?? '');
    if (ref == null) continue;
    backup.pictures.add(ForeignPicture(
      ref: ref,
      title: image['title']?.toString() ?? '',
      characterName: namesById[image['characterId']?.toString() ?? ''] ?? '',
    ));
  }

  final user = json['user'] ?? json['config'];
  if (user is Map<String, dynamic>) {
    for (final provider in maps(user['providers'])) {
      final imported = _agnaiProvider(provider);
      if (imported != null) backup.providers.add(imported);
    }
  }
}

String _agnaiName(Map<String, dynamic> json) {
  final name = json['name']?.toString().trim() ?? '';
  return name.isEmpty ? 'Imported' : name;
}
/// A zip that is not a data folder and not an Agnai backup: a bag of cards and
/// lorebooks, which is what a Chub download or a hand-made archive is. Every
/// entry is read on its own merits.
Future<ForeignBackup> _readLoose(
  _ArchiveIndex index,
  PictureStore? store,
) async {
  final backup = ForeignBackup(source: _looksChub(index)
      ? ForeignSource.chub
      : ForeignSource.archive);
  final pictures = _Pictures(index, store);
  for (final path in index.paths) {
    final bytes = index.bytes(path);
    if (bytes == null || bytes.isEmpty) continue;
    await _readOne(backup, bytes, path, store, pictures: pictures);
  }
  return backup;
}

bool _looksChub(_ArchiveIndex index) => index.paths.any((path) {
      final lower = path.toLowerCase();
      return lower.contains('chub_meta') || lower.endsWith('/chub.json');
    });

/// Routes one file. Never throws: a file that cannot be read is counted and the
/// rest of the archive still imports.
///
/// [lenient] is set for a file the user picked by hand. Inside an archive the
/// extension is trusted and an unknown one is passed over; a file chosen
/// deliberately is worth sniffing, because exports arrive named anything at all.
Future<void> _readOne(
  ForeignBackup backup,
  Uint8List data,
  String path,
  PictureStore? store, {
  bool lenient = false,
  _Pictures? pictures,
}) async {
  final store2 = pictures ?? _Pictures(_ArchiveIndex(Archive()), store);
  final lower = path.toLowerCase();
  final stem = _stem(path);

  if (lower.endsWith('.jsonl')) {
    _addChats(backup, utf8.decode(data, allowMalformed: true), stem, path);
    return;
  }
  if (_isPictureName(lower) ||
      lower.endsWith('.charx') ||
      (lenient && _looksBinary(data))) {
    try {
      final cards = CharacterCodec.parseCards(data, filename: stem);
      for (final card in cards) {
        await _storeAvatar(card, store2);
        backup.characters.add(card);
      }
      _readCardBook(backup, data, stem);
    } catch (_) {
      // Not a card. A picture that is plainly somebody's gallery has a home
      // here; a wallpaper or a UI asset does not.
      if (lower.contains('gallery') || lower.contains('user/images/')) {
        final ref = await store2.add(data);
        if (ref != null) {
          backup.pictures.add(ForeignPicture(ref: ref, title: stem));
        }
      } else {
        backup.skip('pictures with no character card in them');
      }
    }
    return;
  }
  final known = lower.endsWith('.json') || lower.endsWith('.txt');
  if (!known && !lenient) {
    backup.skip('files of a kind this app does not read');
    return;
  }

  final text = utf8.decode(data, allowMalformed: true).trim();
  if (text.isEmpty) return;
  Object? json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    json = null;
  }
  if (json == null) {
    // One JSON object per line is a transcript, whatever the file is called.
    if (text.startsWith('{') && text.contains('\n')) {
      _addChats(backup, text, stem, path);
      return;
    }
    if (lower.endsWith('.json')) {
      backup.skip('files that are not valid JSON');
      return;
    }
    _addScenarios(backup, text, stem);
    return;
  }
  await _readJson(backup, json, path, store2);
}
/// Decides what a parsed JSON document is and hands it to that codec.
///
/// The order is the whole trick: the narrow discriminators first, and `messages`
/// before anything that could also carry a greeting — an Agnai chat export has a
/// `greeting` and a `scenario` on it too, and reading it as a character would
/// lose the conversation.
Future<void> _readJson(
  ForeignBackup backup,
  Object json,
  String path,
  _Pictures pictures,
) async {
  final stem = _stem(path);
  if (json is List) {
    final maps = json.whereType<Map<String, dynamic>>().toList();
    final looksLikeTurns = maps.isNotEmpty &&
        maps.every((m) =>
            m.containsKey('mes') ||
            m.containsKey('msg') ||
            m.containsKey('is_user') ||
            (m.containsKey('role') && m.containsKey('content')));
    if (looksLikeTurns) {
      _addChats(backup, jsonEncode(json), stem, path);
      return;
    }
    for (final item in maps) {
      await _readJson(backup, item, path, pictures);
    }
    return;
  }
  if (json is! Map<String, dynamic>) return;

  if (_looksAgnaiBackup(json)) {
    await _readAgnai(backup, json, pictures.index, pictures.store);
    return;
  }
  final kind = json['kind']?.toString() ?? '';
  if (kind == 'scenario' ||
      json.containsKey('overwriteCharacterScenario') ||
      json['scenarios'] is List) {
    _addScenarios(backup, jsonEncode(json), stem);
    return;
  }
  if (kind == 'memory' ||
      json['entries'] != null ||
      json['lorebooks'] is List ||
      json['book'] is Map) {
    _addLorebooks(backup, jsonEncode(json), stem);
    return;
  }
  if (json['messages'] is List ||
      json['mes'] != null ||
      json['data_visible'] is List ||
      json['histories'] is Map ||
      json['type'] == 'risuChat' ||
      json['savedsettings'] != null ||
      json['chats'] is List) {
    _addChats(backup, jsonEncode(json), stem, path);
    return;
  }
  if (kind == 'character' ||
      json['spec'] != null ||
      json.containsKey('first_mes') ||
      json.containsKey('persona') ||
      json.containsKey('greeting') ||
      json.containsKey('mes_example') ||
      (json['name'] != null && json['description'] != null)) {
    await _addCharacter(backup, json, stem, pictures);
    // A card in JSON can carry its book too.
    _readCardBook(backup, Uint8List.fromList(utf8.encode(jsonEncode(json))), stem);
    return;
  }
  if (detectFormat(json) != PresetFormat.unknown) {
    _addPreset(backup, json, stem);
    return;
  }
  if (json['text'] is String) {
    _addScenarios(backup, jsonEncode(json), stem);
    return;
  }
  backup.skip('files with nothing recognisable in them');
}
void _addChats(
  ForeignBackup backup,
  String text,
  String stem,
  String path,
) {
  try {
    final owner = _parentName(path);
    for (final chat in ChatCodec.parse(text, fileName: stem)) {
      backup.chats.add(ForeignChat(
        chat: chat,
        characterName: (chat.conversation.characterName ?? '').trim().isNotEmpty
            ? chat.conversation.characterName!
            : owner,
      ));
    }
  } on FormatException catch (error) {
    backup.note('Skipped ${_basename(path)} — ${error.message}');
  } catch (_) {
    backup.skip('unreadable chats');
  }
}

Future<void> _addCharacter(
  ForeignBackup backup,
  Map<String, dynamic> json,
  String stem,
  _Pictures pictures,
) async {
  try {
    final character = CharacterCodec.parseJson(jsonEncode(json));
    // Agnai points its avatar at its own asset folder, and the codec rightly
    // drops that — a server path is not a picture. Beside the archive that
    // carried the folder, it is one, so it is picked back up here.
    final raw = json['avatar'];
    if (character.avatar.trim().isEmpty &&
        raw is String &&
        (raw.startsWith('/assets/') || raw.startsWith('assets/'))) {
      final ref = await pictures.ref(raw);
      if (ref != null) character.avatar = ref;
    } else {
      await _storeAvatar(character, pictures);
    }
    backup.characters.add(character);
  } catch (_) {
    backup.skip('files that are not character cards');
  }
}

/// A card's own lorebook (`character_book`), which this app keeps as a book of
/// its own. Silent when there is none — most cards have none.
void _readCardBook(ForeignBackup backup, Uint8List cardBytes, String stem) {
  final json = CharacterCodec.cardJsonOf(cardBytes);
  if (json == null || !json.contains('character_book')) return;
  try {
    for (final book in LorebookCodec.parse(json, fileName: stem)) {
      if (book.entries.isEmpty) continue;
      backup.lorebooks.add(book);
    }
  } catch (_) {
    // A card whose book will not read is still a perfectly good card.
  }
}

void _addLorebooks(ForeignBackup backup, String text, String stem) {
  if (text.trim().isEmpty) return;
  try {
    backup.lorebooks.addAll(LorebookCodec.parse(text, fileName: stem));
  } on FormatException catch (error) {
    backup.note('Skipped $stem — ${error.message}');
  } catch (_) {
    backup.skip('unreadable lorebooks');
  }
}

void _addScenarios(ForeignBackup backup, String text, String stem) {
  try {
    backup.scenarios.addAll(ScenarioCodec.parse(text, fileName: stem));
  } on FormatException catch (error) {
    backup.note('Skipped $stem — ${error.message}');
  } catch (_) {
    backup.skip('unreadable scenarios');
  }
}

void _addPreset(ForeignBackup backup, Map<String, dynamic> json, String stem) {
  try {
    backup.presets.add(importPreset(json, name: _presetName(json, stem)));
  } on FormatException catch (error) {
    backup.note('Skipped $stem — ${error.message}');
  } catch (_) {
    backup.skip('unreadable presets');
  }
}

/// A preset's own name where it has one, else the file's — SillyTavern names a
/// preset by its file and puts nothing inside.
String? _presetName(Map<String, dynamic> json, String stem) {
  final own = json['name'];
  if (own is String && own.trim().isNotEmpty) return null;
  return stem.trim().isEmpty ? null : stem.trim();
}
/// Turns one Agnai provider into one of ours. Only the parts both apps have: a
/// name, an endpoint and the keys. Agnai's `format` names the wire dialect, which
/// is exactly [ProviderKind].
Provider? _agnaiProvider(Map<String, dynamic> json) {
  final name = json['name']?.toString().trim() ?? '';
  final url = json['url']?.toString().trim() ?? '';
  if (name.isEmpty && url.isEmpty) return null;
  final format = json['format'];
  final dialect =
      (format is Map ? format['value']?.toString() : format?.toString()) ??
          json['provider']?.toString() ??
          '';
  final lower = dialect.toLowerCase();
  final kind = lower.contains('claude') || lower.contains('anthropic')
      ? ProviderKind.anthropic
      : (lower.contains('gemini') || lower.contains('google')
          ? ProviderKind.gemini
          : ProviderKind.openai);
  final keys = <String>{
    ...?(json['keys'] as List?)?.map((k) => k.toString().trim()),
    json['key']?.toString().trim() ?? '',
  }.where((k) => k.isNotEmpty).toList();
  return Provider(
    id: _freshId(),
    name: name.isEmpty ? Uri.tryParse(url)?.host ?? 'Imported' : name,
    kind: kind,
    baseUrl: url,
    apiKeys: keys,
    model: '',
  );
}

/// Folder names that are structure rather than a character's name — so a chat in
/// `chats/Aqua/` binds to Aqua, and one in `group chats/` binds to nobody.
const Set<String> _structuralFolders = <String>{
  'chats',
  'group chats',
  'groups',
  'characters',
  'worlds',
  'openai settings',
  'textgen settings',
  'novelai settings',
  'koboldai settings',
  'user',
  'user avatars',
  'images',
  'gallery',
  'data',
  'default-user',
  'backup',
  'backups',
};

String _basename(String path) {
  final slash = path.replaceAll('\\', '/').lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

String _stem(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
}

String _parentName(String path) {
  final parts = path.replaceAll('\\', '/').split('/')..removeLast();
  if (parts.isEmpty) return '';
  final parent = parts.last.trim();
  return _structuralFolders.contains(parent.toLowerCase()) ? '' : parent;
}

bool _isPictureName(String lower) =>
    lower.endsWith('.png') ||
    lower.endsWith('.jpg') ||
    lower.endsWith('.jpeg') ||
    lower.endsWith('.webp') ||
    lower.endsWith('.gif') ||
    lower.endsWith('.avif');

/// Whether the bytes are a picture or an archive rather than text — the sniff
/// that lets a card be recognised through a name that says nothing.
bool _looksBinary(Uint8List bytes) {
  if (bytes.length < 4) return false;
  bool starts(List<int> magic) {
    for (var i = 0; i < magic.length; i++) {
      if (bytes[i] != magic[i]) return false;
    }
    return true;
  }

  return starts(const [0x89, 0x50, 0x4E, 0x47]) ||
      starts(const [0xFF, 0xD8, 0xFF]) ||
      starts(const [0x47, 0x49, 0x46]) ||
      starts(const [0x52, 0x49, 0x46, 0x46]) ||
      starts(const [0x50, 0x4B]);
}

int _seq = 0;

String _freshId() => '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';
