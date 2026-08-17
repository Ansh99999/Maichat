import 'dart:convert';

import '../models/character.dart';
import '../models/conversation.dart';
import '../models/message.dart';

/// Reads and writes whole conversations in the shapes the apps around this one
/// actually use, so a chat can be carried in or out without being retyped.
///
/// Import understands, in the order it sniffs for them:
///
///  * **SillyTavern / TavernAI `.jsonl`** — one JSON object per line, an
///    optional header line first (`user_name` / `character_name` /
///    `chat_metadata`), then turns keyed `mes` + `is_user`, with `swipes` /
///    `swipe_id` for alternatives. Chub's variant, where `mes` and each swipe is
///    an object with a `message` inside, is flattened the way SillyTavern's own
///    importer flattens it.
///  * **Agnai** — the JSON its "Export Chat" writes: `name` / `greeting` /
///    `scenario` / `sampleChat` and `messages` keyed `msg`, where a turn is the
///    user's when it carries a `userId`, and `retries` holds the other swipes.
///  * **MaiChat native** — everything above plus what only this app has
///    (per-swipe thinking, the thread's preset override, its lorebooks).
///  * **text-generation-webui** (`data_visible` pairs), **Character.AI** as CAI
///    Tools exports it (`histories.histories[].msgs[]`, several chats per file),
///  * **RisuAI** (`type: risuChat`), **KoboldAI Lite** (`savedsettings` plus
///    `{{[INPUT]}}` / `{{[OUTPUT]}}` markers), and a plain
///    `[{"role": …, "content": …}]` array, which is what most other tools and
///    every API log look like.
///
/// Export writes four shapes; three of them are read by SillyTavern *and* Agnai,
/// which is the point — see [ChatExportFormat].
class ChatCodec {
  const ChatCodec._();

  /// Where this app's own extras ride inside a foreign format, namespaced so
  /// neither ecosystem trips over them.
  static const String extensionKey = 'maichat';

  /// Bumped when the native shape changes in a way a reader must know about.
  static const int version = 1;

  /// The name written for the user's turns when nothing better is known. Both
  /// ecosystems put a display name on every turn; MaiChat labels the user from
  /// the persona instead, so this is only ever a fallback.
  static const String defaultUserName = 'You';

  /// Parses every chat in [text]. Throws [FormatException] with a sentence fit
  /// for a snackbar when it recognises nothing.
  ///
  /// [fileName] (without its extension) names the thread when the format carries
  /// no name of its own, which is the norm for SillyTavern, where the file name
  /// *is* the chat's name.
  static List<ImportedChat> parse(String text, {String? fileName}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('That file is empty.');
    }
    // A JSONL file's first line parses on its own but the file does not, so
    // whole-document JSON has to be tried first and the line format second.
    Object? json;
    try {
      json = jsonDecode(trimmed);
    } catch (_) {
      json = null;
    }
    if (json == null) return _fromJsonl(trimmed, fileName);
    return _fromJson(json, fileName);
  }

  /// Recognises a parsed JSON document. Every branch is a format's own
  /// discriminator, tested in the order that keeps one from shadowing another:
  /// the narrow keys first, `messages` — which three formats use — last.
  static List<ImportedChat> _fromJson(Object json, String? fileName) {
    if (json is List) {
      // A bundle of chats (what a multi-select export writes), or a bare list
      // of turns — an API log, or this app's own `messages` on their own.
      final maps = json.whereType<Map<String, dynamic>>().toList();
      if (maps.isEmpty) {
        throw const FormatException('That file has no chats in it.');
      }
      if (maps.every((m) => m['messages'] is List)) {
        return maps.expand((m) => _fromJson(m, fileName)).toList();
      }
      return [_fromTurns(maps, fileName)];
    }
    if (json is! Map<String, dynamic>) {
      throw const FormatException('That is not a chat.');
    }
    if (json['savedsettings'] is Map) return [_fromKoboldLite(json, fileName)];
    if (json['histories'] is Map) return _fromCharacterAi(json, fileName);
    if (json['data_visible'] is List) return [_fromOoba(json, fileName)];
    if (json['type'] == 'risuChat') return [_fromRisu(json, fileName)];
    // One SillyTavern turn on its own — a one-line .jsonl parses as a map.
    if (json['mes'] != null || json['is_user'] != null) {
      return [_fromTurns([json], fileName)];
    }
    if (json['chats'] is List) {
      return (json['chats'] as List)
          .whereType<Map<String, dynamic>>()
          .expand((m) => _fromJson(m, fileName))
          .toList();
    }
    if (json['messages'] is List) return [_fromTurns(json, fileName)];
    throw const FormatException('That file is not a chat.');
  }

  /// Reads a list of turns, either on their own or inside an envelope that also
  /// carries the thread's name and (in Agnai's case) its greeting and scenario.
  ///
  /// One reader covers MaiChat, Agnai, SillyTavern-as-JSON and a plain
  /// `role`/`content` log because a turn says for itself which it is: the text
  /// is under `content`, `msg` or `mes`, and the speaker is given by `role`,
  /// by `is_user`, or by which of `userId` / `characterId` is set.
  ///
  /// Two things a foreign format carries have no home here and are dropped: a
  /// chat-level `sampleChat` (MaiChat keeps dialogue examples on the character,
  /// not the thread) and Agnai's message tree — `parent` is ignored, so a
  /// branched chat arrives as the flat list the file lists.
  static ImportedChat _fromTurns(Object source, String? fileName) {
    final envelope =
        source is Map<String, dynamic> ? source : const <String, dynamic>{};
    final turns = (source is List ? source : envelope['messages'] as List)
        .whereType<Map<String, dynamic>>()
        .toList();

    if (envelope[extensionKey] is Map) {
      if (turns.isEmpty) {
        throw const FormatException('That file has no messages in it.');
      }
      return ImportedChat(
        conversation: _reseat(
          Conversation.fromJson(envelope),
          fileName: fileName,
        ),
        format: ChatFormat.native,
      );
    }

    final builder = _ChatBuilder(
      title: _title(envelope, fileName),
      systemPrompt: _stringOr(envelope['scenario'], ''),
    );
    // Agnai keeps the opening line on the chat rather than in the log, so it has
    // to be put back or the character loses their greeting.
    final greeting = _stringOr(envelope['greeting'], '');
    if (greeting.isNotEmpty) builder.addGreeting(greeting);
    for (final turn in turns) {
      builder.add(turn);
    }
    return builder.build(fileName: fileName);
  }
  /// SillyTavern's own file: one JSON object per line, the first of which is a
  /// header rather than a turn. A line that will not parse is skipped instead of
  /// failing the file — a chat truncated mid-write is still worth reading.
  static List<ImportedChat> _fromJsonl(String text, String? fileName) {
    final maps = <Map<String, dynamic>>[];
    for (final line in text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      try {
        final json = jsonDecode(trimmed);
        if (json is Map<String, dynamic>) maps.add(json);
      } catch (_) {
        continue;
      }
    }
    if (maps.isEmpty) {
      throw const FormatException('That file has no chat lines in it.');
    }
    final head = maps.first;
    final hasHeader = head['mes'] == null &&
        head['swipes'] == null &&
        (head.containsKey('user_name') ||
            head.containsKey('character_name') ||
            head.containsKey('chat_metadata') ||
            head.containsKey('create_date'));
    final builder = _ChatBuilder(
      title: _title(hasHeader ? head : const <String, dynamic>{}, fileName),
    );
    if (hasHeader) builder.readHeader(head);
    for (final turn in maps.skip(hasHeader ? 1 : 0)) {
      builder.add(turn);
    }
    return [builder.build(fileName: fileName, format: ChatFormat.sillyTavern)];
  }

  /// text-generation-webui: `data_visible` is a list of `[user, bot]` pairs,
  /// either half of which may be blank.
  static ImportedChat _fromOoba(Map<String, dynamic> json, String? fileName) {
    final builder = _ChatBuilder(title: _title(json, fileName));
    for (final pair in (json['data_visible'] as List).whereType<List>()) {
      final user = pair.isNotEmpty ? _text(pair[0]) : '';
      final bot = pair.length > 1 ? _text(pair[1]) : '';
      if (user.isNotEmpty) builder.addTurn(isUser: true, text: user);
      if (bot.isNotEmpty) builder.addTurn(isUser: false, text: bot);
    }
    return builder.build(fileName: fileName, format: ChatFormat.ooba);
  }
  /// CAI Tools' Character.AI dump: one file holds every history, so this is the
  /// one format that can yield several chats.
  static List<ImportedChat> _fromCharacterAi(
    Map<String, dynamic> json,
    String? fileName,
  ) {
    final histories = (json['histories'] as Map<String, dynamic>)['histories'];
    final out = <ImportedChat>[];
    for (final history in (histories as List? ?? const [])) {
      if (history is! Map<String, dynamic>) continue;
      final builder = _ChatBuilder(title: _title(json, fileName));
      for (final msg in (history['msgs'] as List? ?? const [])) {
        if (msg is! Map<String, dynamic>) continue;
        final src = msg['src'];
        final isUser = src is Map && src['is_human'] == true;
        builder.addTurn(
          isUser: isUser,
          text: _text(msg['text']),
          name: src is Map ? src['name'] as String? : null,
        );
      }
      try {
        out.add(builder.build(fileName: fileName, format: ChatFormat.cai));
      } on FormatException {
        continue; // An empty history is skipped, not fatal.
      }
    }
    if (out.isEmpty) {
      throw const FormatException('That file has no chats in it.');
    }
    return out;
  }

  /// RisuAI: turns live under `data.message`, the text is `data` and the time is
  /// epoch milliseconds.
  static ImportedChat _fromRisu(Map<String, dynamic> json, String? fileName) {
    final data = json['data'];
    final turns = data is Map ? data['message'] : null;
    final builder = _ChatBuilder(
      title: _stringOr(data is Map ? data['name'] : null, '').isNotEmpty
          ? (data as Map)['name'] as String
          : _title(json, fileName),
    );
    for (final turn in (turns as List? ?? const [])) {
      if (turn is! Map<String, dynamic>) continue;
      builder.addTurn(
        isUser: turn['role'] == 'user',
        text: _text(turn['data']),
        name: turn['name'] as String?,
        at: _when(turn['time']),
      );
    }
    return builder.build(fileName: fileName, format: ChatFormat.risu);
  }
  /// KoboldAI Lite: a flat list of actions where the speaker is marked inside
  /// the text by `{{[INPUT]}}` / `{{[OUTPUT]}}`, and the names live in the saved
  /// settings (the opponent field is `name||$||description`).
  static ImportedChat _fromKoboldLite(
    Map<String, dynamic> json,
    String? fileName,
  ) {
    const input = '{{[INPUT]}}';
    const output = '{{[OUTPUT]}}';
    final settings = json['savedsettings'] as Map<String, dynamic>;
    final builder = _ChatBuilder(title: _title(json, fileName))
      ..userName = _stringOr(settings['chatname'], '').trim()
      ..characterName =
          _stringOr(settings['chatopponent'], '').split('||\$||').first.trim();
    void action(Object? raw) {
      final text = _text(raw);
      if (text.isEmpty) return;
      builder.addTurn(
        isUser: text.contains(input),
        text: text.replaceAll(input, '').replaceAll(output, '').trim(),
      );
    }

    action(json['prompt']);
    for (final entry in (json['actions'] as List? ?? const [])) {
      action(entry);
    }
    return builder.build(fileName: fileName, format: ChatFormat.koboldLite);
  }

  /// A fresh copy of [source] under a new id, so importing the same file twice
  /// gives two threads rather than two entries claiming to be one. Uses
  /// [Conversation.copyAs] so every per-chat field (participants, overrides,
  /// background, …) rides along — enumerating them here once dropped a new field
  /// on native re-import.
  static Conversation _reseat(Conversation source, {String? fileName}) {
    final title = source.title.trim();
    final newTitle = title.isEmpty || title == 'New chat'
        ? (fileName?.trim().isNotEmpty == true
            ? fileName!.trim()
            : 'Imported chat')
        : title;
    return source.copyAs(
      id: _freshId(),
      title: newTitle,
      messages: source.messages.toList(),
    );
  }
  /// The thread's name as the file gives it, falling back to the file's own name.
  /// Agnai writes the literal `"Exported"` for every chat it exports, which tells
  /// the reader nothing, so it is treated as absent.
  static String? _title(Map<String, dynamic> json, String? fileName) {
    for (final key in const ['title', 'name', 'chat_name']) {
      final value = _stringOr(json[key], '').trim();
      if (value.isNotEmpty && value != 'Exported' && value != 'unused') {
        return value;
      }
    }
    final file = fileName?.trim() ?? '';
    return file.isEmpty ? null : file;
  }

  /// A turn's text, flattening Chub's variant where the text is an object with
  /// the string inside it.
  static String _text(Object? value) {
    if (value is String) return value;
    if (value is Map) {
      final inner = value['message'];
      if (inner is String) return inner;
    }
    return '';
  }

  static String _stringOr(Object? value, String fallback) =>
      value is String ? value : fallback;

  /// A timestamp however the format spells it: ISO 8601, epoch milliseconds, or
  /// either of those as a string.
  static DateTime? _when(Object? value) {
    if (value is num) {
      final ms = value.toInt();
      if (ms <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(ms);
    }
    if (value is! String || value.trim().isEmpty) return null;
    final epoch = int.tryParse(value.trim());
    if (epoch != null) {
      return epoch <= 0 ? null : DateTime.fromMillisecondsSinceEpoch(epoch);
    }
    return DateTime.tryParse(value.trim());
  }

  static int _idCounter = 0;

  /// Unique even when several chats are imported inside the same microsecond.
  static String _freshId() =>
      '${DateTime.now().microsecondsSinceEpoch}${_idCounter++}';
  // --- writing --------------------------------------------------------------

  /// This app's own shape, and deliberately three formats at once: it is the
  /// whole thread as [Conversation.toJson] writes it, wrapped in the four strings
  /// Agnai's importer insists on, with every turn carrying `msg` and
  /// `userId`/`characterId` beside `role`/`content`.
  ///
  /// SillyTavern recognises any JSON object with a `messages` array as an Agnai
  /// export and reads `msg`; Agnai reads the same keys natively; this app reads
  /// the rest. One file, all three.
  static String exportNative(
    Conversation c, {
    String? characterName,
    String? userName,
  }) {
    final char = _charName(c, characterName);
    final user = _userName(c, userName);
    final stamps = _stamps(c);
    final json = <String, dynamic>{
      'name': c.title,
      'greeting': '',
      'scenario': '',
      'sampleChat': '',
      ...c.toJson(),
      extensionKey: {
        'version': version,
        'characterName': char,
        'userName': user,
      },
    };
    json['messages'] = [
      for (var i = 0; i < c.messages.length; i++)
        _nativeTurn(c.messages[i], char: char, user: user, at: stamps[i]),
    ];
    return _encode(json);
  }

  static Map<String, dynamic> _nativeTurn(
    ChatMessage m, {
    required String char,
    required String user,
    required DateTime at,
  }) {
    final name = _turnSpeaker(m, char: char, user: user);
    final json = m.toJson()
      ..['msg'] = m.content
      ..['name'] = name
      ..['handle'] = name
      ..['createdAt'] = at.toIso8601String();
    if (m.isUser) {
      json['userId'] = 'anon';
    } else {
      json['characterId'] = _speakerCharId(m, primary: char);
    }
    final others = _retries(m);
    if (others.isNotEmpty) json['retries'] = others;
    return json;
  }
  /// SillyTavern's own chat file: a header line, then one turn per line.
  ///
  /// Agnai reads this too — its importer skips the first line and takes `mes` and
  /// `is_user` off the rest — so this is the safest thing to hand to either app.
  /// Swipes survive because SillyTavern copies the file in verbatim.
  static String exportSillyTavern(
    Conversation c, {
    String? characterName,
    String? userName,
  }) {
    final char = _charName(c, characterName);
    final user = _userName(c, userName);
    final stamps = _stamps(c);
    final lines = <String>[
      jsonEncode({
        'user_name': user,
        'character_name': char,
        'create_date': _humanized(c.updatedAt),
        'chat_metadata': {
          if (c.variables.isNotEmpty) 'variables': c.variables,
          extensionKey: {
            'version': version,
            'title': c.title,
            if (c.systemPrompt.isNotEmpty) 'systemPrompt': c.systemPrompt,
          },
        },
      }),
      for (var i = 0; i < c.messages.length; i++)
        jsonEncode(_tavernTurn(
          c.messages[i],
          char: char,
          user: user,
          at: stamps[i],
        )),
    ];
    return lines.join('\n');
  }

  static Map<String, dynamic> _tavernTurn(
    ChatMessage m, {
    required String char,
    required String user,
    required DateTime at,
  }) {
    final stamp = at.toIso8601String();
    // Only a character's turn is swipeable in SillyTavern, so a user turn that
    // somehow holds alternatives is written as its live text alone.
    final swipes = m.hasSwipes && !m.isUser;
    return {
      'name': _turnSpeaker(m, char: char, user: user),
      'is_user': m.isUser,
      'is_system': false,
      'send_date': stamp,
      'mes': m.content,
      'extra': {
        ..._reasoningExtra(m.active),
        extensionKey: {'version': version, 'role': m.role},
      },
      if (swipes) 'swipe_id': m.swipeIndex,
      if (swipes) 'swipes': [for (final s in m.swipes) s.content],
      if (swipes)
        'swipe_info': [
          for (final s in m.swipes)
            {'send_date': stamp, 'extra': _reasoningExtra(s)},
        ],
    };
  }
  /// Agnai's own shape, as its "Export Chat" writes it and its importer
  /// validates it: the four required strings, then turns keyed `msg` where a
  /// `userId` marks the user's side and `characterId: 'imported'` is swapped for
  /// the real character on the way in. Swipes become `retries`.
  ///
  /// SillyTavern reads this file too, as "Agnai's format".
  static String exportAgnai(
    Conversation c, {
    String? characterName,
    String? userName,
  }) {
    final char = _charName(c, characterName);
    final user = _userName(c, userName);
    final stamps = _stamps(c);
    return _encode({
      'name': c.title,
      'greeting': '',
      'scenario': '',
      'sampleChat': '',
      'messages': [
        for (var i = 0; i < c.messages.length; i++)
          _agnaiTurn(
            c.messages[i],
            char: char,
            user: user,
            at: stamps[i],
          ),
      ],
    });
  }

  static Map<String, dynamic> _agnaiTurn(
    ChatMessage m, {
    required String char,
    required String user,
    required DateTime at,
  }) {
    final name = _turnSpeaker(m, char: char, user: user);
    final others = _retries(m);
    return {
      'msg': m.content,
      'name': name,
      'handle': name,
      'createdAt': at.toIso8601String(),
      if (m.isUser) 'userId': 'anon' else 'characterId': _speakerCharId(m, primary: char),
      if (others.isNotEmpty) 'retries': others,
    };
  }

  /// The transcript on its own, laid out the way SillyTavern's `.txt` export
  /// does: `Name: text`, one blank line between turns.
  static String exportText(
    Conversation c, {
    String? characterName,
    String? userName,
  }) {
    final char = _charName(c, characterName);
    final user = _userName(c, userName);
    final buffer = StringBuffer();
    for (final m in c.messages) {
      buffer.write('${m.isUser ? user : char}: ${m.content}\n\n');
    }
    return buffer.toString().trimRight();
  }
  /// The variants Agnai calls retries: every alternative but the live one,
  /// newest first — Agnai pushes the text it replaced onto the front of the list,
  /// so the head of `retries` is the most recent alternative.
  static List<String> _retries(ChatMessage m) {
    if (!m.hasSwipes) return const [];
    final others = <String>[];
    for (var i = m.swipes.length - 1; i >= 0; i--) {
      if (i == m.swipeIndex) continue;
      others.add(m.swipes[i].content);
    }
    return others;
  }

  /// SillyTavern's reasoning fields for one variant, or nothing when it did not
  /// think. `reasoning_type: 'model'` is what SillyTavern records for thinking
  /// the model sent itself, which is the only kind this app stores.
  static Map<String, dynamic> _reasoningExtra(MessageVariant v) => {
        if (v.reasoning.trim().isNotEmpty) ...{
          'reasoning': v.reasoning,
          'reasoning_type': 'model',
          if (v.thinkingMs != null) 'reasoning_duration': v.thinkingMs,
        },
      };

  /// One timestamp per turn, ascending, ending at the thread's own. MaiChat keeps
  /// a single timestamp for a whole thread, so these are derived rather than
  /// recorded — but both ecosystems order a chat by them, so they have to rise.
  static List<DateTime> _stamps(Conversation c) {
    final count = c.messages.length;
    final end = c.updatedAt;
    return [
      for (var i = 0; i < count; i++)
        end.subtract(Duration(seconds: count - 1 - i)),
    ];
  }

  static String _charName(Conversation c, String? override) {
    for (final name in [override, c.characterName]) {
      final trimmed = name?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return 'Assistant';
  }

  /// The name a turn is attributed to on the wire. In a group chat each turn
  /// carries its own speaker, so that wins; otherwise it is the thread's single
  /// character (or the user). Keeps every export attributable turn-by-turn, the
  /// way SillyTavern's group `.jsonl` and Agnai's multi-character export do.
  static String _turnSpeaker(
    ChatMessage m, {
    required String char,
    required String user,
  }) {
    final speaker = (m.speakerName ?? '').trim();
    if (speaker.isNotEmpty) return speaker;
    return m.isUser ? user : char;
  }

  /// The `characterId` a member's turn is tagged with for Agnai / native import.
  /// The primary character keeps the `imported` marker both ecosystems swap for
  /// the bound character; every other group member gets a stable per-name id, so
  /// a reader that groups by `characterId` sees the distinct participants.
  static String _speakerCharId(ChatMessage m, {required String primary}) {
    final speaker = (m.speakerName ?? '').trim();
    if (speaker.isEmpty || speaker == primary) return 'imported';
    return 'char-${_slug(speaker)}';
  }

  /// A filesystem/id-safe slug of a display name.
  static String _slug(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');

  static String _userName(Conversation c, String? override) {
    for (final name in [override, c.impersonateName]) {
      final trimmed = name?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return defaultUserName;
  }

  /// SillyTavern's `create_date`: `YYYY-MM-DD@HHhMMmSSsMSms`, local time.
  static String _humanized(DateTime at) {
    String p(int v, [int width = 2]) => v.toString().padLeft(width, '0');
    return '${at.year}-${p(at.month)}-${p(at.day)}@${p(at.hour)}h'
        '${p(at.minute)}m${p(at.second)}s${p(at.millisecond, 3)}ms';
  }

  static String _encode(Object json) =>
      const JsonEncoder.withIndent('  ').convert(json);
}

/// Accumulates turns as a format is read, then hands back one [ImportedChat].
class _ChatBuilder {
  _ChatBuilder({this.title, String systemPrompt = ''}) : _system = systemPrompt;

  /// The thread's name. Mutable because SillyTavern's header carries no name of
  /// its own — a file this app wrote hides one in the metadata, and that is only
  /// found once the header is read.
  String? title;
  String _system;
  String? userName;
  String? characterName;
  final Map<String, String> variables = {};
  final List<ChatMessage> _messages = [];
  DateTime? _touched;
  bool _sawTavernKeys = false;
  bool _sawAgnaiKeys = false;

  /// SillyTavern's header line. Its `user_name` and `character_name` have read
  /// `'unused'` since names moved onto every turn, so they are only taken when
  /// they say something; an older file still carries the real ones.
  void readHeader(Map<String, dynamic> head) {
    _sawTavernKeys = true;
    final user = ChatCodec._stringOr(head['user_name'], '').trim();
    final char = ChatCodec._stringOr(head['character_name'], '').trim();
    if (user.isNotEmpty && user != 'unused') userName = user;
    if (char.isNotEmpty && char != 'unused') characterName = char;
    final metadata = head['chat_metadata'];
    if (metadata is! Map) return;
    final vars = metadata['variables'];
    if (vars is Map) {
      vars.forEach((k, v) => variables[k.toString()] = v?.toString() ?? '');
    }
    // Our own extras, if this file left here in the first place.
    final mine = metadata[ChatCodec.extensionKey];
    if (mine is Map) {
      final prompt = ChatCodec._stringOr(mine['systemPrompt'], '');
      if (prompt.isNotEmpty && _system.isEmpty) _system = prompt;
      final saved = ChatCodec._stringOr(mine['title'], '').trim();
      if (saved.isNotEmpty) title = saved;
    }
    final scenario = ChatCodec._stringOr(metadata['scenario'], '').trim();
    if (scenario.isNotEmpty && _system.isEmpty) _system = scenario;
  }

  void addGreeting(String text) =>
      _messages.add(ChatMessage(role: 'assistant', content: text));

  void addTurn({
    required bool isUser,
    required String text,
    String? name,
    List<MessageVariant>? swipes,
    int swipeIndex = 0,
    DateTime? at,
  }) {
    if (text.trim().isEmpty && (swipes == null || swipes.isEmpty)) return;
    final trimmed = name?.trim() ?? '';
    _messages.add(ChatMessage(
      role: isUser ? 'user' : 'assistant',
      content: text,
      swipes: swipes,
      swipeIndex: swipeIndex,
      // The turn's own attributed name is kept so a group log stays
      // attributable turn-by-turn (and re-exports the same way); it is promoted
      // to a real participant in [build] when several speakers appear.
      speakerName: trimmed.isEmpty ? null : trimmed,
    ));
    if (!isUser && trimmed.isNotEmpty) characterName ??= trimmed;
    if (isUser && trimmed.isNotEmpty) userName ??= trimmed;
    if (at != null && (_touched == null || at.isAfter(_touched!))) {
      _touched = at;
    }
  }
  /// One turn in whichever of the JSON dialects it is written in.
  void add(Map<String, dynamic> turn) {
    // SillyTavern's system lines are its own interface notices, not transcript —
    // its own text export drops them, so importing them would invent turns.
    if (turn['is_system'] == true) return;
    if (turn.containsKey('mes')) _sawTavernKeys = true;
    if (turn.containsKey('msg')) _sawAgnaiKeys = true;

    final text = ChatCodec._text(
      turn['content'] ?? turn['msg'] ?? turn['mes'] ?? turn['text'],
    );
    final role = _roleOf(turn);
    if (role == 'system') {
      // A leading system turn is this app's system prompt, which is a property of
      // the thread rather than a message in it.
      if (text.trim().isNotEmpty) {
        _system = _system.isEmpty ? text : '$_system\n\n$text';
      }
      return;
    }
    final variants = _variantsOf(turn, text);
    if (variants.isEmpty) return;
    addTurn(
      isUser: role == 'user',
      text: variants.first.content,
      name: ChatCodec._stringOr(turn['name'], '').trim().isNotEmpty
          ? turn['name'] as String
          : ChatCodec._stringOr(turn['handle'], ''),
      // Even a lone variant is passed as one, so its thinking is not dropped.
      swipes: variants,
      swipeIndex: _indexOf(turn, variants.length),
      at: ChatCodec._when(turn['send_date'] ?? turn['createdAt'] ?? turn['time']),
    );
  }

  /// Who spoke, by whichever marker the format uses.
  String _roleOf(Map<String, dynamic> turn) {
    final isUser = turn['is_user'];
    if (isUser is bool) return isUser ? 'user' : 'assistant';
    final role = ChatCodec._stringOr(turn['role'], '').toLowerCase();
    if (role == 'user' || role == 'human') return 'user';
    if (role == 'system' || role == 'developer') return 'system';
    if (role.isNotEmpty) return 'assistant';
    if (ChatCodec._stringOr(turn['userId'], '').isNotEmpty) return 'user';
    if (ChatCodec._stringOr(turn['characterId'], '').isNotEmpty) {
      return 'assistant';
    }
    return 'assistant';
  }
  /// Every alternative this turn holds, oldest first — SillyTavern's `swipes`,
  /// Agnai's `retries`, or this app's own variant objects.
  List<MessageVariant> _variantsOf(Map<String, dynamic> turn, String text) {
    final extra = turn['extra'] is Map ? turn['extra'] as Map : const {};
    MessageVariant one(String content, Map extras) => MessageVariant(
          content: content,
          reasoning: ChatCodec._stringOr(
            extras['reasoning'] ?? turn['reasoning'],
            '',
          ),
          thinkingMs:
              (extras['reasoning_duration'] ?? turn['thinkingMs']) is num
                  ? ((extras['reasoning_duration'] ?? turn['thinkingMs']) as num)
                      .toInt()
                  : null,
        );

    final raw = turn['swipes'];
    if (raw is List && raw.isNotEmpty) {
      final infos = turn['swipe_info'] is List
          ? turn['swipe_info'] as List
          : const <dynamic>[];
      final live = _indexOf(turn, raw.length);
      final out = <MessageVariant>[];
      for (var i = 0; i < raw.length; i++) {
        final item = raw[i];
        // Our own export writes variant objects; SillyTavern writes strings, and
        // Chub writes an object with the string inside it.
        if (item is Map<String, dynamic> && item['content'] is String) {
          out.add(MessageVariant.fromJson(item));
          continue;
        }
        final info = i < infos.length && infos[i] is Map
            ? (infos[i] as Map)['extra']
            : null;
        out.add(one(
          ChatCodec._text(item),
          info is Map ? info : (i == live ? extra : const {}),
        ));
      }
      if (out.every((v) => v.content.trim().isEmpty)) return const [];
      return out;
    }

    final retries = turn['retries'];
    if (retries is List && retries.isNotEmpty) {
      return [
        for (final r in retries.reversed)
          MessageVariant(content: ChatCodec._text(r)),
        one(text, extra),
      ];
    }
    if (text.trim().isEmpty) return const [];
    return [one(text, extra)];
  }
  /// Which alternative is live. Agnai keeps the live text outside `retries`, and
  /// this reader appends it last, so its index is the final one.
  int _indexOf(Map<String, dynamic> turn, int count) {
    final raw = turn['swipe_id'] ?? turn['swipeIndex'];
    if (raw is num) return raw.toInt().clamp(0, count - 1);
    final retries = turn['retries'];
    if (retries is List && retries.isNotEmpty) return count - 1;
    return 0;
  }

  ImportedChat build({String? fileName, ChatFormat? format}) {
    if (_messages.isEmpty) {
      throw const FormatException('That file has no messages in it.');
    }
    // Group reconstruction: when the transcript names two or more distinct AI
    // speakers (a SillyTavern group `.jsonl`, an Agnai multi-character export),
    // rebuild them as per-chat members so the thread opens as a real group.
    // Such logs carry names but not cards, so each member holds a name and
    // nothing else until the user swaps in a full character.
    final speakerOrder = <String>[];
    for (final m in _messages) {
      if (m.isUser) continue;
      final n = (m.speakerName ?? '').trim();
      if (n.isNotEmpty && !speakerOrder.contains(n)) speakerOrder.add(n);
    }
    final isGroup = speakerOrder.length >= 2;

    var messages = _messages;
    List<String>? participants;
    Map<String, Character>? overrides;
    if (isGroup) {
      final idByName = <String, String>{};
      overrides = <String, Character>{};
      for (final name in speakerOrder) {
        final id = 'import-${ChatCodec._slug(name)}';
        idByName[name] = id;
        overrides[id] = Character(id: id, name: name);
      }
      participants = [for (final n in speakerOrder) idByName[n]!];
      messages = [
        for (final m in _messages)
          (!m.isUser && (m.speakerName ?? '').trim().isNotEmpty)
              ? m.copyWith(speakerId: idByName[m.speakerName!.trim()])
              : m,
      ];
    }

    return ImportedChat(
      conversation: Conversation(
        id: ChatCodec._freshId(),
        title: _name(fileName),
        messages: messages,
        updatedAt: _touched ?? DateTime.now(),
        characterId: isGroup ? participants!.first : null,
        characterName: isGroup ? speakerOrder.first : characterName,
        systemPrompt: _system.trim(),
        variables: variables,
        participantIds: participants,
        characterOverrides: overrides,
        overrideDefinitions: isGroup,
      ),
      format: format ??
          (_sawAgnaiKeys
              ? ChatFormat.agnai
              : _sawTavernKeys
                  ? ChatFormat.sillyTavern
                  : ChatFormat.plain),
      userName: userName,
    );
  }

  String _name(String? fileName) {
    for (final candidate in [
      title,
      characterName == null ? null : '$characterName chat',
      fileName,
    ]) {
      final trimmed = candidate?.trim() ?? '';
      if (trimmed.isNotEmpty) return trimmed;
    }
    return 'Imported chat';
  }
}

/// One chat read out of a file: the thread itself, what it was recognised as,
/// and the name the file gave the user's side (which MaiChat has no home for —
/// it labels the user from the persona instead).
class ImportedChat {
  const ImportedChat({
    required this.conversation,
    required this.format,
    this.userName,
  });

  final Conversation conversation;
  final ChatFormat format;
  final String? userName;

  int get messageCount => conversation.messages.length;
  String? get characterName => conversation.characterName;
}

/// The formats [ChatCodec.parse] recognises, for saying so in the import summary.
enum ChatFormat {
  native('MaiChat'),
  sillyTavern('SillyTavern'),
  agnai('Agnai'),
  ooba('text-generation-webui'),
  cai('Character.AI'),
  risu('RisuAI'),
  koboldLite('KoboldAI Lite'),
  plain('plain messages');

  const ChatFormat(this.label);
  final String label;
}

/// The shapes a chat can be written out as, offered when exporting. Only the
/// last is not machine-readable by both of the other apps.
enum ChatExportFormat {
  native(
    'MaiChat',
    'Everything, swipes and thinking included. SillyTavern and Agnai read this '
        'file too.',
    'json',
  ),
  sillyTavern(
    'SillyTavern / Agnai',
    'A .jsonl chat log with swipes — the safest choice for importing elsewhere.',
    'jsonl',
  ),
  agnai(
    'Agnai',
    'The JSON its own Export Chat writes; swipes become retries.',
    'json',
  ),
  text(
    'Plain text',
    'Just the transcript, the way SillyTavern exports .txt.',
    'txt',
  );

  const ChatExportFormat(this.label, this.blurb, this.extension);

  final String label;
  final String blurb;
  final String extension;

  /// The file contents for [c] in this format. [characterName] and [userName]
  /// override the names on the thread, so a bound character's real name is used.
  String write(
    Conversation c, {
    String? characterName,
    String? userName,
  }) =>
      switch (this) {
        ChatExportFormat.native => ChatCodec.exportNative(
            c,
            characterName: characterName,
            userName: userName,
          ),
        ChatExportFormat.sillyTavern => ChatCodec.exportSillyTavern(
            c,
            characterName: characterName,
            userName: userName,
          ),
        ChatExportFormat.agnai => ChatCodec.exportAgnai(
            c,
            characterName: characterName,
            userName: userName,
          ),
        ChatExportFormat.text => ChatCodec.exportText(
            c,
            characterName: characterName,
            userName: userName,
          ),
      };
}
