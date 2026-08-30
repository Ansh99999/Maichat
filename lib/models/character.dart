import 'dart:convert';
import 'dart:typed_data';

/// Where a [Character] came from, kept so the UI can show provenance and so a
/// re-export can favour a compatible shape.
enum CharacterFormat {
  tavernV1('SillyTavern v1'),
  tavernV2('SillyTavern v2'),
  tavernV3('Character Card v3'),
  agnai('Agnai'),
  manual('Created here');

  const CharacterFormat(this.label);

  final String label;

  static CharacterFormat byName(String? name) {
    for (final f in values) {
      if (f.name == name) return f;
    }
    return CharacterFormat.manual;
  }
}

/// A roleplay character, modelled on the union of the SillyTavern character-card
/// fields and Agnai's character export, so a card from either ecosystem
/// round-trips without losing anything the app understands. Fields are mutable
/// so the edit form can drive them directly.
class Character {
  Character({
    required this.id,
    required this.name,
    this.avatar = '',
    List<String>? avatars,
    this.description = '',
    this.personality = '',
    this.scenario = '',
    this.customScenario = '',
    this.firstMes = '',
    this.alternateGreetings = const <String>[],
    this.mesExample = '',
    this.systemPrompt = '',
    this.postHistoryInstructions = '',
    this.creatorNotes = '',
    this.tags = const <String>[],
    this.creator = '',
    this.characterVersion = '',
    this.format = CharacterFormat.manual,
    this.starred = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : avatars = avatars ?? <String>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;

  /// Either an `http(s)` URL or a base64-encoded image (no `data:` prefix).
  /// Imported PNG cards keep their own picture here as base64.
  String avatar;

  /// Extra pictures this character can wear, added from its gallery — the pool
  /// the in-chat avatar viewer swipes through. [avatar] stays the default (and is
  /// not repeated here), so every existing read of a character's picture is
  /// unaffected by this field; see `AppState.avatarPoolFor`, which is the one
  /// place that joins the two.
  List<String> avatars;

  String description;
  String personality;

  /// The card's own scenario, as its creator wrote it. Kept even when the user
  /// has supplied a [customScenario], so switching back is possible.
  String scenario;

  /// The user's own scenario, replacing [scenario] everywhere the character is
  /// used once it is non-empty. Read it through [activeScenario] and nowhere
  /// else, so "which scenario is in force" is decided in exactly one place —
  /// the prompt, the sheet, the exporter and the definition fallback all agree.
  String customScenario;

  /// The scenario actually in force: the user's when they wrote one, else the
  /// card's.
  String get activeScenario =>
      customScenario.trim().isEmpty ? scenario : customScenario;

  /// Whether the user has replaced the card's scenario with their own.
  bool get hasCustomScenario => customScenario.trim().isNotEmpty;

  /// The opening line the character sends (SillyTavern `first_mes`, Agnai
  /// `greeting`).
  String firstMes;

  /// Extra opening lines to swipe between (SillyTavern `alternate_greetings`).
  List<String> alternateGreetings;

  /// Example dialogue that primes the model's voice (`mes_example` / `sampleChat`).
  String mesExample;
  String systemPrompt;
  String postHistoryInstructions;
  String creatorNotes;
  List<String> tags;
  String creator;
  String characterVersion;
  CharacterFormat format;

  /// Whether the user pinned this character to the top ("starred").
  bool starred;
  final DateTime createdAt;
  DateTime updatedAt;

  factory Character.empty() => Character(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: '',
      );

  /// What to show when a card arrives without a name.
  String get displayName => name.trim().isEmpty ? 'Unnamed character' : name.trim();

  bool get hasAvatar => avatar.trim().isNotEmpty;

  bool get avatarIsUrl =>
      avatar.startsWith('http://') || avatar.startsWith('https://');

  /// The decoded avatar image when [avatar] holds base64 bytes rather than a
  /// URL, or null when it is a URL / empty / unparseable.
  Uint8List? get avatarBytes {
    if (avatar.trim().isEmpty || avatarIsUrl) return null;
    try {
      return base64Decode(avatar.trim());
    } catch (_) {
      return null;
    }
  }

  /// A short, one-line blurb for list rows: creator notes, then description.
  String get blurb {
    for (final candidate in [creatorNotes, description, personality]) {
      final flat = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (flat.isNotEmpty) return flat;
    }
    return '';
  }

  /// The two card macros, compiled once. Built per call previously, which meant
  /// two regex compilations for every message of every history on every send.
  static final RegExp _charMacro = RegExp(r'\{\{char\}\}', caseSensitive: false);
  static final RegExp _userMacro = RegExp(r'\{\{user\}\}', caseSensitive: false);

  /// Replaces the card macros both ecosystems use, case-insensitively, so a
  /// prompt reads naturally once it reaches the model.
  ///
  /// Each replacement is guarded by a plain substring test first, and text with
  /// nothing to replace is returned **as it came in** — the same instance. Every
  /// history message runs through here on every send, so the guards turn four
  /// full passes over the whole transcript into one cheap scan; and handing the
  /// identical string back lets the caches downstream (token counts, parsed
  /// spans) recognise text they have already seen.
  static String resolveMacros(
    String text, {
    required String charName,
    required String userName,
  }) {
    if (text.isEmpty) return text;
    var out = text;
    // Both regexes need a literal "{{" to match, whatever the case of the word.
    if (out.contains('{{')) {
      out = out.replaceAll(_charMacro, charName).replaceAll(_userMacro, userName);
    }
    if (out.contains('<BOT>')) out = out.replaceAll('<BOT>', charName);
    if (out.contains('<USER>')) out = out.replaceAll('<USER>', userName);
    return out;
  }

  /// Builds the system prompt a chat with this character should run under: the
  /// card's own system prompt (if any), then a persona block assembled from the
  /// description/personality/scenario/examples, then any post-history note. All
  /// macros are resolved against [name] and [userName].
  ///
  /// [scenario] replaces the card's own scenario when given — a chat can be
  /// running a scenario of its own, and this snapshot has to say the same thing
  /// the request does.
  String composedSystemPrompt({String userName = 'User', String? scenario}) {
    final parts = <String>[];
    if (systemPrompt.trim().isNotEmpty) parts.add(systemPrompt.trim());

    final persona = StringBuffer()
      ..writeln('You are {{char}}, talking with {{user}}. '
          'Stay in character throughout the conversation.');
    void section(String heading, String value) {
      final v = value.trim();
      if (v.isEmpty) return;
      persona
        ..writeln()
        ..writeln('# $heading')
        ..writeln(v);
    }

    section('Description', description);
    section('Personality', personality);
    section('Scenario', scenario ?? activeScenario);
    section('Example dialogue', mesExample);
    parts.add(persona.toString().trim());

    if (postHistoryInstructions.trim().isNotEmpty) {
      parts.add(postHistoryInstructions.trim());
    }

    return resolveMacros(
      parts.join('\n\n'),
      charName: displayName,
      userName: userName,
    ).trim();
  }

  /// Just the character's definition sections — description, personality,
  /// scenario, example dialogue — with macros resolved. This is the content the
  /// preset's marker blocks (charDescription/charPersonality/scenario/
  /// dialogueExamples) stand in for. Used as a safety net when the active preset
  /// carries none of those markers, so the definition never silently vanishes
  /// from the request even under a trimmed or imported preset. The card's own
  /// system prompt and post-history note are deliberately excluded — the main
  /// and jailbreak blocks carry those.
  ///
  /// [scenario] replaces the card's own when given, so a chat running its own
  /// scenario is not handed the card's by the safety net.
  String definition({String userName = 'User', String? scenario}) {
    final buffer = StringBuffer();
    void section(String heading, String value) {
      final v = value.trim();
      if (v.isEmpty) return;
      if (buffer.isNotEmpty) buffer.writeln();
      buffer
        ..writeln('# $heading')
        ..writeln(v);
    }

    section('Description', description);
    section('Personality', personality);
    section('Scenario', scenario ?? activeScenario);
    section('Example dialogue', mesExample);

    return resolveMacros(
      buffer.toString().trim(),
      charName: displayName,
      userName: userName,
    ).trim();
  }

  /// The opening line with macros resolved, ready to seed a new chat.
  String resolvedGreeting({String userName = 'User'}) => resolveMacros(
        firstMes,
        charName: displayName,
        userName: userName,
      ).trim();

  /// A persona block describing the human's side of the conversation when the
  /// user impersonates this character. Injected into the request so the model
  /// knows who "{{user}}" is — the mirror of [composedSystemPrompt], from the
  /// user's seat. Macros resolve against this character as both {{char}} and
  /// {{user}} (it is the user here). [charName] names the character being
  /// chatted with, so a line like "talking with {{char}}" reads right.
  String userPersona({String charName = 'the character'}) {
    final buffer = StringBuffer()
      ..writeln('The user is roleplaying as $displayName. '
          'Treat their messages as $displayName speaking, and address them as '
          '$displayName.');
    void section(String heading, String value) {
      final v = value.trim();
      if (v.isEmpty) return;
      buffer
        ..writeln()
        ..writeln('# $heading')
        ..writeln(v);
    }

    section('Description', description);
    section('Personality', personality);

    return resolveMacros(
      buffer.toString().trim(),
      charName: charName,
      userName: displayName,
    ).trim();
  }

  Character copyWith({String? id, String? name}) => Character(
        id: id ?? this.id,
        name: name ?? this.name,
        avatar: avatar,
        avatars: List<String>.from(avatars),
        description: description,
        personality: personality,
        scenario: scenario,
        customScenario: customScenario,
        firstMes: firstMes,
        alternateGreetings: List<String>.from(alternateGreetings),
        mesExample: mesExample,
        systemPrompt: systemPrompt,
        postHistoryInstructions: postHistoryInstructions,
        creatorNotes: creatorNotes,
        tags: List<String>.from(tags),
        creator: creator,
        characterVersion: characterVersion,
        format: format,
        starred: starred,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
      );

  /// A deep copy, identity and timestamps included — the starting point for an
  /// edit that must not touch the stored card until (and unless) it is saved.
  /// A [Character] is mutable, so handing the live object to an editor would
  /// otherwise commit every keystroke to the roster.
  Character clone() => copyWith()..updatedAt = updatedAt;

  /// Our own persistence shape (a superset of every import format), so nothing
  /// is lost across app restarts.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'avatar': avatar,
        if (avatars.isNotEmpty) 'avatars': avatars,
        'description': description,
        'personality': personality,
        'scenario': scenario,
        if (customScenario.trim().isNotEmpty) 'customScenario': customScenario,
        'firstMes': firstMes,
        'alternateGreetings': alternateGreetings,
        'mesExample': mesExample,
        'systemPrompt': systemPrompt,
        'postHistoryInstructions': postHistoryInstructions,
        'creatorNotes': creatorNotes,
        'tags': tags,
        'creator': creator,
        'characterVersion': characterVersion,
        'format': format.name,
        'starred': starred,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Character.fromJson(Map<String, dynamic> json) => Character(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        avatar: json['avatar'] as String? ?? '',
        avatars: _stringList(json['avatars']),
        description: json['description'] as String? ?? '',
        personality: json['personality'] as String? ?? '',
        scenario: json['scenario'] as String? ?? '',
        customScenario: json['customScenario'] as String? ?? '',
        firstMes: json['firstMes'] as String? ?? '',
        alternateGreetings: _stringList(json['alternateGreetings']),
        mesExample: json['mesExample'] as String? ?? '',
        systemPrompt: json['systemPrompt'] as String? ?? '',
        postHistoryInstructions: json['postHistoryInstructions'] as String? ?? '',
        creatorNotes: json['creatorNotes'] as String? ?? '',
        tags: _stringList(json['tags']),
        creator: json['creator'] as String? ?? '',
        characterVersion: json['characterVersion'] as String? ?? '',
        format: CharacterFormat.byName(json['format'] as String?),
        starred: json['starred'] as bool? ?? false,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );

  /// Coerces a JSON value into a clean list of non-empty strings, tolerating a
  /// single comma-separated string (some exporters flatten tags that way).
  static List<String> _stringList(Object? value) {
    if (value is List) {
      return value
          .map((e) => e?.toString().trim() ?? '')
          .where((e) => e.isNotEmpty)
          .toList();
    }
    if (value is String) {
      return value
          .split(',')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    }
    return <String>[];
  }
}

