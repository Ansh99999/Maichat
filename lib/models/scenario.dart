/// Where a scenario came from. Shown as provenance on its row and used to pick
/// the sensible default when it is exported again.
enum ScenarioFormat {
  manual('MaiChat'),
  agnai('Agnai'),
  characterCard('Character card'),
  plainText('Plain text');

  const ScenarioFormat(this.label);
  final String label;

  static ScenarioFormat fromName(Object? value) {
    for (final f in ScenarioFormat.values) {
      if (f.name == value) return f;
    }
    return ScenarioFormat.manual;
  }
}

/// A reusable opening — where a chat starts, what is happening, and why the two
/// of them are in the room — written once and plugged into any character or any
/// single chat.
///
/// The two apps this one follows disagree about where a scenario lives.
/// SillyTavern keeps it inside the character card and lets one chat override it;
/// Agnai gives it a library entry of its own that either *replaces* a
/// character's scenario or is *added* to it. This is Agnai's shape, because a
/// scenario worth writing is rarely worth writing twice — and
/// [overwriteCharacterScenario] keeps SillyTavern's behaviour available, which is
/// the whole difference between the two.
///
/// Agnai scenarios also carry triggered *events* (`entries`) and named `states`.
/// MaiChat runs no trigger engine, so those ride along untouched in
/// [extensions] — an imported scenario exports again unchanged — and the import
/// says plainly that they will not fire rather than pretending they were read.
class Scenario {
  Scenario({
    required this.id,
    this.name = '',
    this.text = '',
    List<String>? tags,
    this.starred = false,
    this.overwriteCharacterScenario = true,
    this.format = ScenarioFormat.manual,
    Map<String, dynamic>? extensions,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : tags = tags ?? <String>[],
        extensions = extensions ?? <String, dynamic>{},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// What the scenario is called in the library. Never sent to the model — only
  /// [text] is.
  String name;

  /// The prompt itself: the situation the model is told it is in.
  String text;

  List<String> tags;
  bool starred;

  /// Whether this replaces the character's own scenario (the default, and what
  /// picking a scenario usually means) or is appended after it, so a card's
  /// setting and a chosen opening can both be in force.
  bool overwriteCharacterScenario;

  ScenarioFormat format;

  /// Anything the source format carried that has no field here — Agnai's
  /// `entries`, `states` and `instructions` among them. Kept so a round trip
  /// loses nothing.
  Map<String, dynamic> extensions;

  final DateTime createdAt;
  DateTime updatedAt;

  factory Scenario.empty() => Scenario(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: '',
      );

  String get displayName =>
      name.trim().isEmpty ? 'Untitled scenario' : name.trim();

  /// A one-line preview of the prompt, for a collapsed row.
  String get blurb => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Whether this scenario would actually change a prompt.
  bool get isUsable => text.trim().isNotEmpty;

  /// Whether [query] matches this scenario by name, tag, or the prompt itself —
  /// what you remember is usually a phrase from the opening, not its title.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    return name.toLowerCase().contains(q) ||
        text.toLowerCase().contains(q) ||
        tags.any((t) => t.toLowerCase().contains(q));
  }

  /// The scenario text in force when this one is applied over [cardScenario] —
  /// the card's own scenario, or whatever else was already there.
  ///
  /// Replacing is the default; appending keeps the card's setting first and this
  /// opening after it, which is the order both apps write them in. An empty
  /// scenario changes nothing, so the card's own survives.
  String appliedOver(String cardScenario) {
    final mine = text.trim();
    final theirs = cardScenario.trim();
    if (mine.isEmpty) return theirs;
    if (overwriteCharacterScenario || theirs.isEmpty) return mine;
    return '$theirs\n\n$mine';
  }

  Scenario copyWith({
    String? id,
    String? name,
    String? text,
    List<String>? tags,
    bool? starred,
    bool? overwriteCharacterScenario,
    ScenarioFormat? format,
    DateTime? updatedAt,
  }) =>
      Scenario(
        id: id ?? this.id,
        name: name ?? this.name,
        text: text ?? this.text,
        tags: tags ?? List<String>.from(this.tags),
        starred: starred ?? this.starred,
        overwriteCharacterScenario:
            overwriteCharacterScenario ?? this.overwriteCharacterScenario,
        format: format ?? this.format,
        extensions: Map<String, dynamic>.from(extensions),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (text.isNotEmpty) 'text': text,
        if (tags.isNotEmpty) 'tags': tags,
        if (starred) 'starred': true,
        // Written only when it differs from the default, so an ordinary
        // scenario's stored shape stays as small as it reads.
        if (!overwriteCharacterScenario) 'overwriteCharacterScenario': false,
        if (format != ScenarioFormat.manual) 'format': format.name,
        if (extensions.isNotEmpty) 'extensions': extensions,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory Scenario.fromJson(Map<String, dynamic> json) => Scenario(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        text: json['text'] as String? ?? '',
        tags: _strings(json['tags']),
        starred: json['starred'] as bool? ?? false,
        overwriteCharacterScenario:
            json['overwriteCharacterScenario'] as bool? ?? true,
        format: ScenarioFormat.fromName(json['format']),
        extensions: json['extensions'] is Map
            ? Map<String, dynamic>.from(json['extensions'] as Map)
            : null,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );
}

/// Reads a tag list, tolerating the comma-separated string some exporters write
/// and dropping blanks — the same leniency the lorebook reader applies.
List<String> _strings(Object? value) {
  if (value is String) {
    return value
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (value is! List) return <String>[];
  return value
      .map((e) => e?.toString().trim() ?? '')
      .where((s) => s.isNotEmpty)
      .toList();
}
