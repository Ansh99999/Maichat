/// One of a character's scenarios, and which of their greetings it belongs to.
///
/// SillyTavern gives a card exactly one scenario, and Agnai gives the library a
/// scenario that replaces or extends it. Neither lets a card say "*this* opening
/// happens in the rain and *that* one happens at the funeral" — but a card with
/// six alternate greetings usually has six different situations behind them, and
/// writing one scenario that covers all six is how a good card gets vague.
///
/// So a scenario here carries the greetings it applies to. [greetings] holds
/// indexes into the character's own greeting list ([Character.greetings]: the
/// first message, then the alternates, blanks dropped) and an **empty list means
/// every greeting** — which is the shape a card imported from either ecosystem
/// arrives in, and why nothing about an existing card changes.
///
/// [text] is always the prose that will be sent, even when this scenario came out
/// of the library: a character stores plain text, so a later library edit cannot
/// silently rewrite a card the user thought they had finished. [scenarioId]
/// records where it came from, for provenance and for re-syncing on purpose.
class CharacterScenario {
  CharacterScenario({
    required this.id,
    this.name = '',
    this.text = '',
    this.scenarioId,
    List<int>? greetings,
  }) : greetings = greetings ?? <int>[];

  final String id;

  /// What the user calls this scenario in the editor. Never sent to the model.
  String name;

  /// The situation itself — this is what reaches the prompt.
  String text;

  /// The library scenario this was taken from, or null when it was written here.
  String? scenarioId;

  /// Greeting indexes this scenario belongs to. Empty means all of them.
  List<int> greetings;

  factory CharacterScenario.empty() => CharacterScenario(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
      );

  bool get appliesToAll => greetings.isEmpty;

  bool appliesTo(int greetingIndex) =>
      greetings.isEmpty || greetings.contains(greetingIndex);

  /// Whether this scenario would actually change a prompt.
  bool get isUsable => text.trim().isNotEmpty;

  String get displayName =>
      name.trim().isEmpty ? 'Untitled scenario' : name.trim();

  /// A one-line preview for a collapsed row.
  String get blurb => text.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// How this reads on the row that says where it applies.
  String describeScope(int greetingCount) {
    if (appliesToAll) return 'Every greeting';
    final named = greetings.where((i) => i >= 0 && i < greetingCount).toList()
      ..sort();
    if (named.isEmpty) return 'No greeting';
    if (named.length == greetingCount) return 'Every greeting';
    return named.map(greetingLabel).join(', ');
  }

  /// What greeting [index] is called wherever a greeting is named: the opening
  /// line has no number, the rest are counted from one.
  static String greetingLabel(int index) =>
      index == 0 ? 'First message' : 'Greeting ${index + 1}';

  CharacterScenario clone() => CharacterScenario(
        id: id,
        name: name,
        text: text,
        scenarioId: scenarioId,
        greetings: List<int>.from(greetings),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        if (name.trim().isNotEmpty) 'name': name,
        if (text.isNotEmpty) 'text': text,
        if (scenarioId != null) 'scenarioId': scenarioId,
        if (greetings.isNotEmpty) 'greetings': greetings,
      };

  factory CharacterScenario.fromJson(Map<String, dynamic> json) =>
      CharacterScenario(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        text: json['text'] as String? ?? '',
        scenarioId: (json['scenarioId'] as String?)?.trim().isEmpty ?? true
            ? null
            : (json['scenarioId'] as String).trim(),
        greetings: _ints(json['greetings']),
      );

  static List<int> _ints(Object? value) {
    if (value is! List) return <int>[];
    final out = <int>[];
    for (final entry in value) {
      final n = entry is num ? entry.toInt() : int.tryParse('$entry');
      if (n != null && n >= 0 && !out.contains(n)) out.add(n);
    }
    return out;
  }

  /// The scenario in force out of [list] when the chat opened on greeting
  /// [greetingIndex], or empty when none of them applies.
  ///
  /// **The** ranking, in one place: a scenario that names this greeting
  /// explicitly beats one that covers every greeting, and among equals the first
  /// in the list wins (the editor's order is the author's order). A chat with no
  /// greeting turn at all — an imported log, a thread the user started blank —
  /// has no index, so only the "every greeting" scenarios can apply.
  static String resolve(List<CharacterScenario> list, int? greetingIndex) {
    CharacterScenario? general;
    for (final scenario in list) {
      if (!scenario.isUsable) continue;
      if (scenario.appliesToAll) {
        general ??= scenario;
        continue;
      }
      if (greetingIndex != null && scenario.appliesTo(greetingIndex)) {
        return scenario.text.trim();
      }
    }
    return general?.text.trim() ?? '';
  }
}
