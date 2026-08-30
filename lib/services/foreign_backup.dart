/// Reads a backup that another app wrote — SillyTavern, Agnai, Chub/Venus — and
/// turns it into the things this app holds.
///
/// There is no single interchange format for "everything an account owns", so
/// this does the only thing that generalises: it walks whatever arrives and
/// routes each piece through the codec that already understands it. A character
/// card goes to [CharacterCodec], a world-info file to [LorebookCodec], a
/// `.jsonl` transcript to [ChatCodec], a preset to [importPreset], a scenario to
/// [ScenarioCodec]. Adding a format to one of those codecs therefore improves
/// the importer for free.
///
/// Three shapes arrive in practice:
///
///  * **An Agnai backup** — `backup.json` in a zip (with an `assets/` folder) or
///    the same document on its own. Its `messages` are keyed by chat id, and its
///    characters/books/scenarios are the shapes the codecs already read.
///  * **A SillyTavern data folder** — a zip of `characters/`, `chats/<name>/`,
///    `worlds/`, `OpenAI Settings/`. The folder a chat sits in names its
///    character, which is the only place that binding exists.
///  * **A bag of files** — what a Chub/Venus export or a hand-made zip is: cards
///    and lorebooks, no structure to speak of.
///
/// MaiChat's own backups do *not* come through here — they restore the store
/// itself (see `backup_codec.dart`), which is exact where this is best-effort.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models/character.dart';
import '../models/lorebook.dart';
import '../models/preset.dart';
import '../models/provider.dart';
import '../models/scenario.dart';
import 'backup_codec.dart';
import 'character_codec.dart';
import 'chat_codec.dart';
import 'lorebook_codec.dart';
import 'preset_io.dart';
import 'scenario_codec.dart';

/// Which app the file appears to have come from — shown in the import summary,
/// and nothing else depends on it.
enum ForeignSource {
  agnai('Agnai'),
  sillyTavern('SillyTavern'),
  chub('Chub / Venus'),
  archive('An archive of files'),
  file('A single file');

  const ForeignSource(this.label);
  final String label;
}

/// A picture that came with the backup and belongs in the gallery.
class ForeignPicture {
  const ForeignPicture({
    required this.bytes,
    this.title = '',
    this.characterName = '',
  });

  final Uint8List bytes;
  final String title;

  /// Whose gallery it belongs in, by name — ids from another app mean nothing
  /// here, so the binding is done by name on the way in.
  final String characterName;
}
/// Everything recognised in a foreign backup, ready to be added.
class ForeignBackup {
  ForeignBackup({required this.source});

  final ForeignSource source;
  final List<Character> characters = <Character>[];
  final List<ImportedChat> chats = <ImportedChat>[];
  final List<Lorebook> lorebooks = <Lorebook>[];
  final List<Scenario> scenarios = <Scenario>[];
  final List<Preset> presets = <Preset>[];
  final List<Provider> providers = <Provider>[];
  final List<ForeignPicture> pictures = <ForeignPicture>[];

  /// What was in the file and could not be used, one line each — shown after an
  /// import so a missing thing is explained rather than silently absent.
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
    for (final note in other.notes) {
      if (!notes.contains(note)) notes.add(note);
    }
  }
}

/// File names inside a SillyTavern data folder that hold no user content worth
/// importing (and, in the case of `secrets.json`, nothing that should travel).
const Set<String> _skippedNames = <String>{
  'settings.json',
  'secrets.json',
  'stats.json',
  'config.yaml',
  'thumbnails.json',
};

/// Reads whatever [bytes] is. Throws [FormatException] with a sentence worth
/// showing when nothing in it is recognisable.
ForeignBackup readForeignBackup(Uint8List bytes, {String fileName = ''}) {
  if (bytes.isEmpty) throw const FormatException('That file is empty.');
  if (looksLikeZip(bytes)) return _fromZip(bytes);

  final text = utf8.decode(bytes, allowMalformed: true);
  Object? json;
  try {
    json = jsonDecode(text.trim());
  } catch (_) {
    json = null;
  }
  // An Agnai account/guest export on its own.
  if (json is Map<String, dynamic> && _looksAgnaiBackup(json)) {
    final backup = ForeignBackup(source: ForeignSource.agnai);
    _readAgnai(backup, json, const <String, Uint8List>{});
    return _orThrow(backup);
  }
  final backup = ForeignBackup(source: ForeignSource.file);
  _readOne(
    backup,
    bytes,
    fileName.isEmpty ? 'file' : fileName,
    lenient: true,
  );
  return _orThrow(backup);
}

ForeignBackup _orThrow(ForeignBackup backup) {
  if (backup.isEmpty) {
    throw const FormatException(
      'Nothing in that file looked like characters, chats, lorebooks, '
      'scenarios or presets.',
    );
  }
  return backup;
}
bool _looksAgnaiBackup(Map<String, dynamic> json) =>
    json['kind'] == 'agnai-user-backup' ||
    (json['characters'] is List &&
        (json['chats'] is List || json['presets'] is List));

ForeignBackup _fromZip(Uint8List bytes) {
  Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (error) {
    throw FormatException('That archive could not be opened ($error).');
  }

  // Agnai first: it has a manifest, so there is no guessing to do.
  final assets = <String, Uint8List>{};
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final name = _basename(file.name);
    if (file.name.contains('assets/') && name.isNotEmpty) {
      final data = file.readBytes();
      if (data != null && data.isNotEmpty) assets[name] = data;
    }
  }
  for (final file in archive.files) {
    if (!file.isFile || !file.name.endsWith('.json')) continue;
    if (file.name.split('/').length > 2) continue;
    final data = file.readBytes();
    if (data == null) continue;
    Object? json;
    try {
      json = jsonDecode(utf8.decode(data, allowMalformed: true));
    } catch (_) {
      continue;
    }
    if (json is Map<String, dynamic> && _looksAgnaiBackup(json)) {
      final backup = ForeignBackup(source: ForeignSource.agnai);
      _readAgnai(backup, json, assets);
      return _orThrow(backup);
    }
  }

  final backup = ForeignBackup(source: _sniffArchive(archive));
  for (final file in archive.files) {
    if (!file.isFile) continue;
    final path = file.name;
    final name = _basename(path);
    if (name.isEmpty || name.startsWith('.')) continue;
    if (_skippedNames.contains(name.toLowerCase())) {
      backup.notes.add('Skipped $name (app settings, not content).');
      continue;
    }
    // Directories whose contents this app has no home for.
    if (_ignoredFolder(path)) continue;
    final data = file.readBytes();
    if (data == null || data.isEmpty) continue;
    _readOne(backup, data, path);
  }
  return _orThrow(backup);
}

/// SillyTavern folders that hold nothing importable: wallpapers, UI themes,
/// its own vector cache, user avatars for personas we cannot place.
bool _ignoredFolder(String path) {
  final lower = path.toLowerCase();
  for (final folder in const [
    'backgrounds/',
    'themes/',
    'vectors/',
    'user/workflows/',
    'context/',
    'instruct/',
    'sysprompt/',
    'quickreplies/',
    'assets/',
    'extensions/',
  ]) {
    if (lower.contains(folder)) return true;
  }
  return false;
}

ForeignSource _sniffArchive(Archive archive) {
  var sillyTavern = false;
  var chub = false;
  for (final file in archive.files) {
    final lower = file.name.toLowerCase();
    if (lower.contains('worlds/') ||
        lower.contains('chats/') ||
        lower.contains('openai settings/') ||
        lower.contains('group chats/')) {
      sillyTavern = true;
    }
    if (lower.contains('chub_meta') || lower.endsWith('/chub.json')) {
      chub = true;
    }
  }
  if (sillyTavern) return ForeignSource.sillyTavern;
  if (chub) return ForeignSource.chub;
  return ForeignSource.archive;
}

String _basename(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? path : path.substring(slash + 1);
}

String _stem(String path) {
  final name = _basename(path);
  final dot = name.lastIndexOf('.');
  return dot <= 0 ? name : name.substring(0, dot);
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
  'images',
  'gallery',
  'data',
  'default-user',
  'backup',
  'backups',
};

void _note(ForeignBackup backup, String message) {
  // A large archive can have hundreds of unusable files; a wall of notes helps
  // nobody, so the tail is counted instead of listed.
  if (backup.notes.length < 8) {
    backup.notes.add(message);
  } else if (backup.notes.length == 8) {
    backup.notes.add('…and more that could not be read.');
  }
}

String _parentName(String path) {
  final parts = path.split('/')..removeLast();
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

/// Routes one file. Never throws: a file that cannot be read leaves a note and
/// the rest of the archive still imports.
///
/// [lenient] is set for a file the user picked by hand. Inside an archive the
/// extension is trusted and an unknown one is passed over in silence (a `.yaml`,
/// a lock file, a readme); a file chosen deliberately is worth sniffing, because
/// exports arrive named anything at all and sometimes nothing.
void _readOne(
  ForeignBackup backup,
  Uint8List data,
  String path, {
  bool lenient = false,
}) {
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
      backup.characters.addAll(CharacterCodec.parseCards(data, filename: stem));
    } catch (_) {
      // Not a card. A picture filed under a gallery has a home here; a
      // wallpaper or a UI asset does not.
      if (lower.contains('gallery') || lower.contains('user/images/')) {
        backup.pictures.add(ForeignPicture(
          bytes: data,
          title: stem,
          characterName: _parentName(path),
        ));
      } else {
        _note(backup, 'Skipped ${_basename(path)} — a picture with no '
            'character card in it.');
      }
    }
    return;
  }
  final known = lower.endsWith('.json') || lower.endsWith('.txt');
  if (!known && !lenient) return;

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
    // A `.txt` beside the rest is nearly always a scenario or a note; a JSON
    // file that will not parse is broken and worth saying so.
    if (lower.endsWith('.json')) {
      _note(backup, 'Skipped ${_basename(path)} — not valid JSON.');
      return;
    }
    _addScenarios(backup, text, stem);
    return;
  }
  _readJson(backup, json, path);
}

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

  return starts(const [0x89, 0x50, 0x4E, 0x47]) || // PNG
      starts(const [0xFF, 0xD8, 0xFF]) || // JPEG
      starts(const [0x47, 0x49, 0x46]) || // GIF
      starts(const [0x52, 0x49, 0x46, 0x46]) || // WEBP container
      starts(const [0x50, 0x4B]); // zip (.charx)
}
/// Decides what a parsed JSON document is and hands it to that codec.
///
/// The order is the whole trick: the narrow discriminators first, and `messages`
/// before anything that could also carry a greeting — an Agnai chat export has a
/// `greeting` and a `scenario` on it as well, and reading it as a character
/// would lose the conversation.
void _readJson(ForeignBackup backup, Object json, String path) {
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
      _readJson(backup, item, path);
    }
    return;
  }
  if (json is! Map<String, dynamic>) return;

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
    _addCharacter(backup, json, stem);
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
  _note(backup, 'Skipped ${_basename(path)} — nothing recognisable in it.');
}
void _addChats(
  ForeignBackup backup,
  String text,
  String stem,
  String path,
) {
  try {
    final chats = ChatCodec.parse(text, fileName: stem);
    final owner = _parentName(path);
    for (final chat in chats) {
      // SillyTavern keeps a chat in a folder named after its character, and that
      // folder is the only record of the binding — the transcript itself has
      // only display names on turns.
      if ((chat.conversation.characterName ?? '').trim().isEmpty &&
          owner.isNotEmpty) {
        chat.conversation.characterName = owner;
      }
      backup.chats.add(chat);
    }
  } on FormatException catch (error) {
    _note(backup, 'Skipped ${_basename(path)} — ${error.message}');
  } catch (_) {
    _note(backup, 'Skipped ${_basename(path)} — it could not be read as a chat.');
  }
}

void _addCharacter(
  ForeignBackup backup,
  Map<String, dynamic> json,
  String stem, {
  Map<String, Uint8List> assets = const <String, Uint8List>{},
}) {
  try {
    final character = CharacterCodec.parseJson(jsonEncode(json));
    // Agnai points its avatar at its own asset folder, and the codec rightly
    // drops that — a server path is not a picture. Beside the archive that
    // carried the folder, it is one, so it is picked back up here.
    final raw = json['avatar'];
    if (character.avatar.trim().isEmpty &&
        raw is String &&
        (raw.startsWith('/assets/') || raw.startsWith('assets/'))) {
      character.avatar = raw.trim();
    }
    _resolveAvatar(character, assets);
    backup.characters.add(character);
  } catch (_) {
    _note(backup, 'Skipped $stem — it is not a character card.');
  }
}

/// Turns an asset reference on a card ("/assets/x.png", as Agnai writes it) into
/// the picture itself.
///
/// Only an asset path is touched: a URL is left to resolve on its own, and base64
/// is already the picture. Base64 here only ever exists on the way to a file —
/// `AppState` adopts it into the pictures directory as the character is added.
/// A path the archive did not carry is cleared rather than kept, because a
/// reference to somebody else's server path draws nothing for ever.
void _resolveAvatar(Character character, Map<String, Uint8List> assets) {
  final avatar = character.avatar.trim();
  if (!avatar.startsWith('/assets/') && !avatar.startsWith('assets/')) return;
  final bytes = assets[_basename(avatar)];
  character.avatar = (bytes == null || bytes.isEmpty) ? '' : base64Encode(bytes);
}

void _addLorebooks(ForeignBackup backup, String text, String stem) {
  try {
    backup.lorebooks.addAll(LorebookCodec.parse(text, fileName: stem));
  } on FormatException catch (error) {
    _note(backup, 'Skipped $stem — ${error.message}');
  } catch (_) {
    _note(backup, 'Skipped $stem — it could not be read as a lorebook.');
  }
}

void _addScenarios(ForeignBackup backup, String text, String stem) {
  try {
    backup.scenarios.addAll(ScenarioCodec.parse(text, fileName: stem));
  } on FormatException catch (error) {
    _note(backup, 'Skipped $stem — ${error.message}');
  } catch (_) {
    _note(backup, 'Skipped $stem — it could not be read as a scenario.');
  }
}

void _addPreset(ForeignBackup backup, Map<String, dynamic> json, String stem) {
  try {
    backup.presets.add(importPreset(json, name: _presetName(json, stem)));
  } on FormatException catch (error) {
    _note(backup, 'Skipped $stem — ${error.message}');
  } catch (_) {
    _note(backup, 'Skipped $stem — it could not be read as a preset.');
  }
}

/// A preset's own name where it has one, else the file's — SillyTavern names a
/// preset by its file and puts nothing inside.
String? _presetName(Map<String, dynamic> json, String stem) {
  final own = json['name'];
  if (own is String && own.trim().isNotEmpty) return null;
  return stem.trim().isEmpty ? null : stem.trim();
}
/// Reads an Agnai account or guest backup: `characters`, `chats` with
/// `messages` keyed by chat id, `books`/`memory`, `scenarios`, `presets`,
/// `gallery`, and the provider list on the user document.
///
/// Agnai's ids mean nothing here, so the one binding that matters — which
/// character a chat belongs to — is carried across by *name*, which is what
/// `AppState` matches on when the import is applied.
void _readAgnai(
  ForeignBackup backup,
  Map<String, dynamic> json,
  Map<String, Uint8List> assets,
) {
  List<Map<String, dynamic>> maps(Object? value) => value is List
      ? value.whereType<Map<String, dynamic>>().toList()
      : const <Map<String, dynamic>>[];

  final namesById = <String, String>{};
  for (final map in maps(json['characters'])) {
    final before = backup.characters.length;
    _addCharacter(backup, map, _agnaiName(map), assets: assets);
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
    final turns = byChat[id] ?? const <Map<String, dynamic>>[];
    final name = (chat['name']?.toString() ?? '').trim();
    final envelope = <String, Object?>{
      if (name.isNotEmpty) 'name': name,
      if (chat['greeting'] != null) 'greeting': chat['greeting'],
      if (chat['scenario'] != null) 'scenario': chat['scenario'],
      'messages': turns,
    };
    final before = backup.chats.length;
    _addChats(backup, jsonEncode(envelope), name.isEmpty ? 'Chat' : name, '');
    final owner = namesById[chat['characterId']?.toString() ?? ''] ?? '';
    if (owner.isNotEmpty) {
      for (final imported in backup.chats.skip(before)) {
        imported.conversation.characterName = owner;
      }
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
    final bytes = assets[_basename(image['image']?.toString() ?? '')];
    if (bytes == null || bytes.isEmpty) continue;
    backup.pictures.add(ForeignPicture(
      bytes: bytes,
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
/// Turns one Agnai provider into one of ours. Only the parts both apps have: a
/// name, an endpoint, the keys and how to rotate them. Agnai's `format` names
/// the wire dialect, which is exactly [ProviderKind].
Provider? _agnaiProvider(Map<String, dynamic> json) {
  final name = json['name']?.toString().trim() ?? '';
  final url = json['url']?.toString().trim() ?? '';
  if (name.isEmpty && url.isEmpty) return null;
  final format = json['format'];
  final dialect = (format is Map ? format['value']?.toString() : format?.toString()) ??
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
    id: '${DateTime.now().microsecondsSinceEpoch}-${_providerSeq++}',
    name: name.isEmpty ? Uri.tryParse(url)?.host ?? 'Imported' : name,
    kind: kind,
    baseUrl: url,
    apiKeys: keys,
    model: '',
  );
}

int _providerSeq = 0;
