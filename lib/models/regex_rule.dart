/// Where a regex rule is allowed to act, mirroring SillyTavern's
/// `regex_placement` enum. MaiChat exposes three of them in the editor; the
/// other two (slash commands, world info) are kept only so imported rules that
/// target them survive a round-trip unchanged.
enum RegexTarget {
  userInput(1),
  aiOutput(2),
  slashCommand(3),
  worldInfo(5),
  reasoning(6);

  const RegexTarget(this.code);

  /// The number SillyTavern stores in a script's `placement` array.
  final int code;

  static RegexTarget? byCode(int code) {
    for (final t in RegexTarget.values) {
      if (t.code == code) return t;
    }
    return null;
  }
}

/// How a rule changes what it touches, mirroring SillyTavern's two "ephemerality"
/// checkboxes. The two flags are independent there, so a rule can be both
/// display-only and prompt-only; MaiChat's editor presents the common trio as a
/// single choice but the engine still reads the two booleans, so an imported rule
/// with both set behaves exactly as SillyTavern would run it.
enum RegexMode {
  /// Rewrites the stored message for good — the default.
  permanent,

  /// Leaves the saved message alone; only changes how it is shown on screen.
  displayOnly,

  /// Leaves the saved message alone; only changes what is sent to the model.
  promptOnly,
}

/// How `{{macros}}` in the *find* pattern are handled before it compiles,
/// mirroring SillyTavern's `substitute_find_regex`.
enum RegexMacroMode {
  none(0),
  raw(1),
  escaped(2);

  const RegexMacroMode(this.code);
  final int code;

  static RegexMacroMode byCode(int? code) {
    switch (code) {
      case 1:
        return RegexMacroMode.raw;
      case 2:
        return RegexMacroMode.escaped;
      default:
        return RegexMacroMode.none;
    }
  }
}

/// One find/replace rule — MaiChat's model of a SillyTavern "regex script".
///
/// The persisted shape uses SillyTavern's own field names so a rule exported
/// here imports there and vice-versa (`services/regex_codec.dart` handles the
/// file wrapping). Fields are mutable so the editor can drive them directly,
/// like [Character] and [Preset].
class RegexRule {
  RegexRule({
    required this.id,
    this.name = '',
    this.find = '',
    this.replace = '',
    List<String>? trimStrings,
    List<int>? placement,
    this.disabled = false,
    this.markdownOnly = false,
    this.promptOnly = false,
    this.runOnEdit = true,
    this.macroMode = RegexMacroMode.none,
    this.minDepth,
    this.maxDepth,
  })  : trimStrings = trimStrings ?? <String>[],
        placement = placement ?? <int>[RegexTarget.aiOutput.code];

  /// A fresh rule with a stable-enough id and sensible defaults (acts on AI
  /// output, rewrites the message).
  factory RegexRule.create({String name = ''}) => RegexRule(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
      );

  final String id;
  String name;

  /// The pattern to look for. Either a bare pattern (`\bfoo\b`) or the delimited
  /// form SillyTavern shares (`/foo/gi`) — see `RegexEngine.compile`.
  String find;

  /// What each match becomes. Supports `{{match}}` / `$0` for the whole match,
  /// `$1`…`$n` for numbered groups and `$<name>` for named groups.
  String replace;

  /// Substrings snipped out of a match before it is substituted in.
  final List<String> trimStrings;

  /// SillyTavern placement codes this rule acts on. Stored as the raw number
  /// list for lossless round-trip; use [targets] for typed access.
  final List<int> placement;

  bool disabled;

  /// SillyTavern's "Only Format Display" — cosmetic changes, chat file untouched.
  bool markdownOnly;

  /// SillyTavern's "Only Format Prompt" — changes the outgoing prompt only.
  bool promptOnly;

  /// Whether the rule re-runs when a message is edited in place.
  bool runOnEdit;

  /// How `{{macros}}` in [find] are treated before compilation.
  RegexMacroMode macroMode;

  /// Depth window (0 = newest message). Null means "no limit" on that side.
  int? minDepth;
  int? maxDepth;

  String get displayName => name.trim().isEmpty ? 'Untitled rule' : name.trim();

  /// The typed set of targets this rule acts on.
  Set<RegexTarget> get targets =>
      placement.map(RegexTarget.byCode).whereType<RegexTarget>().toSet();

  bool actsOn(RegexTarget target) => placement.contains(target.code);

  /// Turns a target on or off, keeping [placement] tidy and de-duplicated.
  void setTarget(RegexTarget target, bool on) {
    if (on) {
      if (!placement.contains(target.code)) placement.add(target.code);
    } else {
      placement.removeWhere((c) => c == target.code);
    }
  }

  RegexMode get mode {
    if (markdownOnly) return RegexMode.displayOnly;
    if (promptOnly) return RegexMode.promptOnly;
    return RegexMode.permanent;
  }

  set mode(RegexMode value) {
    markdownOnly = value == RegexMode.displayOnly;
    promptOnly = value == RegexMode.promptOnly;
  }

  /// A one-line description of what the rule touches, for the list row.
  String get blurb {
    final where = <String>[
      if (actsOn(RegexTarget.userInput)) 'your messages',
      if (actsOn(RegexTarget.aiOutput)) 'AI replies',
      if (actsOn(RegexTarget.reasoning)) 'reasoning',
    ];
    final scope = switch (mode) {
      RegexMode.permanent => 'edits',
      RegexMode.displayOnly => 'restyles',
      RegexMode.promptOnly => 'cleans the prompt of',
    };
    if (where.isEmpty) return 'Not applied anywhere yet';
    return '$scope ${_join(where)}';
  }

  static String _join(List<String> parts) {
    if (parts.length == 1) return parts.first;
    if (parts.length == 2) return '${parts[0]} and ${parts[1]}';
    return '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
  }

  RegexRule duplicate({String? newName}) => RegexRule(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: newName ?? '$displayName (copy)',
        find: find,
        replace: replace,
        trimStrings: List<String>.from(trimStrings),
        placement: List<int>.from(placement),
        disabled: disabled,
        markdownOnly: markdownOnly,
        promptOnly: promptOnly,
        runOnEdit: runOnEdit,
        macroMode: macroMode,
        minDepth: minDepth,
        maxDepth: maxDepth,
      );

  RegexRule copy() => duplicate(newName: name);

  /// SillyTavern-compatible JSON. Field names match its `RegexScriptData` shape
  /// so a rule saved here imports there unchanged.
  Map<String, dynamic> toJson() => {
        'id': id,
        'scriptName': name,
        'findRegex': find,
        'replaceString': replace,
        'trimStrings': trimStrings,
        'placement': placement,
        'disabled': disabled,
        'markdownOnly': markdownOnly,
        'promptOnly': promptOnly,
        'runOnEdit': runOnEdit,
        'substituteRegex': macroMode.code,
        if (minDepth != null) 'minDepth': minDepth,
        if (maxDepth != null) 'maxDepth': maxDepth,
      };

  factory RegexRule.fromJson(Map<String, dynamic> json) {
    List<int> codes(Object? value) => value is List
        ? value
            .map((e) => (e is num) ? e.toInt() : int.tryParse('$e'))
            .whereType<int>()
            .toList()
        : <int>[];

    List<String> strings(Object? value) => value is List
        ? value.map((e) => e.toString()).toList()
        : <String>[];

    return RegexRule(
      id: json['id']?.toString() ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      // Accept either our/ST's `scriptName` or a plain `name`.
      name: (json['scriptName'] ?? json['name'])?.toString() ?? '',
      find: (json['findRegex'] ?? json['find'])?.toString() ?? '',
      replace: (json['replaceString'] ?? json['replace'])?.toString() ?? '',
      trimStrings: strings(json['trimStrings']),
      placement: codes(json['placement']),
      disabled: json['disabled'] as bool? ?? false,
      markdownOnly: json['markdownOnly'] as bool? ?? false,
      promptOnly: json['promptOnly'] as bool? ?? false,
      runOnEdit: json['runOnEdit'] as bool? ?? true,
      macroMode: RegexMacroMode.byCode((json['substituteRegex'] as num?)?.toInt()),
      minDepth: (json['minDepth'] as num?)?.toInt(),
      maxDepth: (json['maxDepth'] as num?)?.toInt(),
    );
  }
}
