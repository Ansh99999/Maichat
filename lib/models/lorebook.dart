/// Where an activated lorebook entry is placed in the prompt.
///
/// The wire values are SillyTavern's `world_info_position` enum, so a book
/// imported from either ecosystem keeps its placement and an exported one lands
/// back exactly where it started.
///
/// MaiChat has no Author's Note, so [anTop]/[anBottom] are treated as
/// [beforeChar]/[afterChar] when the prompt is assembled — the entry is never
/// silently dropped, it just anchors to the nearest thing that exists here.
enum LorebookPosition {
  beforeChar(0, 'Before character'),
  afterChar(1, 'After character'),
  anTop(2, "Before author's note"),
  anBottom(3, "After author's note"),
  atDepth(4, 'At depth'),
  emTop(5, 'Before examples'),
  emBottom(6, 'After examples');

  const LorebookPosition(this.wire, this.label);

  /// The numeric value SillyTavern stores.
  final int wire;
  final String label;

  static LorebookPosition fromWire(
    Object? value, {
    LorebookPosition fallback = LorebookPosition.beforeChar,
  }) {
    if (value == null) return fallback;
    // The V2 character-card spec spells this as a string, and treats anything
    // that is not `before_char` as after the definitions.
    if (value is String && int.tryParse(value.trim()) == null) {
      return value.trim().toLowerCase() == 'before_char'
          ? LorebookPosition.beforeChar
          : LorebookPosition.afterChar;
    }
    final n = value is num ? value.toInt() : int.tryParse('$value');
    for (final p in LorebookPosition.values) {
      if (p.wire == n) return p;
    }
    return fallback;
  }
}

/// Which role a depth-injected entry speaks as, matching SillyTavern's
/// `extension_prompt_roles`.
enum LoreRole {
  system(0, 'System'),
  user(1, 'User'),
  assistant(2, 'Assistant');

  const LoreRole(this.wire, this.label);
  final int wire;
  final String label;

  /// The role string the rest of the app (and every provider) speaks.
  String get wireName => switch (this) {
        LoreRole.system => 'system',
        LoreRole.user => 'user',
        LoreRole.assistant => 'assistant',
      };

  static LoreRole fromWire(Object? value, {LoreRole fallback = LoreRole.system}) {
    final n = value is num ? value.toInt() : int.tryParse('$value');
    for (final r in LoreRole.values) {
      if (r.wire == n) return r;
    }
    return fallback;
  }
}

/// How an entry's secondary keys gate activation once a primary key has matched
/// (SillyTavern's `world_info_logic`). The wire values are its enum order.
enum SelectiveLogic {
  andAny(0, 'Any secondary key'),
  notAll(1, 'Not all secondary keys'),
  notAny(2, 'No secondary key'),
  andAll(3, 'All secondary keys');

  const SelectiveLogic(this.wire, this.label);
  final int wire;
  final String label;

  static SelectiveLogic fromWire(Object? value) {
    final n = value is num ? value.toInt() : int.tryParse('$value');
    for (final l in SelectiveLogic.values) {
      if (l.wire == n) return l;
    }
    return SelectiveLogic.andAny;
  }
}

/// How many recent messages a book scans for its keywords when it does not say
/// otherwise. SillyTavern's global default is a very shallow 2; Agnai uses 50,
/// which is what a book imported from either ecosystem is given here.
const int kLoreScanDepth = 50;

/// How many tokens of activated lore may enter one prompt, before the chat
/// history is fitted around what is left. Both ecosystems default to 500.
const int kLoreTokenBudget = 500;

/// The cap on how many times activated lore is fed back through the scan to
/// activate further entries. SillyTavern leaves this unlimited; a small cap
/// keeps a book that references itself from looping.
const int kLoreMaxRecursion = 3;

/// The insertion order / discard priority a new or imported entry gets.
const int kLoreDefaultWeight = 100;

/// One keyed fact inside a [Lorebook] — a SillyTavern world-info entry and an
/// Agnai memory-book entry are the same thing under two names, and this is a
/// superset of both.
///
/// The editor exposes the five fields that decide behaviour in practice (name,
/// keywords, priority, weight, content, plus the on/off switch), exactly as
/// Agnai does. Everything else is carried so a book imported from SillyTavern
/// behaves the way its author intended and survives a round trip unchanged.
class LorebookEntry {
  LorebookEntry({
    required this.uid,
    this.name = '',
    this.content = '',
    List<String>? keys,
    List<String>? secondaryKeys,
    this.enabled = true,
    this.constant = false,
    this.selective = true,
    this.selectiveLogic = SelectiveLogic.andAny,
    this.priority = kLoreDefaultWeight,
    this.weight = kLoreDefaultWeight,
    this.position = LorebookPosition.beforeChar,
    this.depth = 4,
    this.role = LoreRole.system,
    this.probability = 100,
    this.useProbability = true,
    this.caseSensitive,
    this.matchWholeWords,
    this.scanDepth,
    this.excludeRecursion = false,
    this.preventRecursion = false,
    this.delayUntilRecursion = 0,
    this.group = '',
    this.groupOverride = false,
    this.groupWeight = kLoreDefaultWeight,
    this.useGroupScoring,
    this.sticky,
    this.cooldown,
    this.delay,
    this.automationId = '',
    Map<String, dynamic>? extensions,
  })  : keys = keys ?? <String>[],
        secondaryKeys = secondaryKeys ?? <String>[],
        extensions = extensions ?? <String, dynamic>{};

  /// Identity within its book. SillyTavern keys its `entries` object by this
  /// number, so it has to survive import and export.
  int uid;

  /// What the entry is called in the editor. SillyTavern stores it as `comment`
  /// and never sends it to the model; only [content] is injected.
  String name;

  /// The text injected into the prompt when this entry activates.
  String content;

  /// Words that trigger the entry. A key wrapped in slashes (`/pattern/i`) is
  /// treated as a regular expression, and `*` / `?` act as wildcards otherwise.
  List<String> keys;

  /// Extra keys that must also be satisfied — see [selective]/[selectiveLogic].
  List<String> secondaryKeys;

  bool enabled;

  /// A "blue" entry: always injected, without scanning for keywords.
  bool constant;

  /// Whether [secondaryKeys] are honoured at all.
  bool selective;
  SelectiveLogic selectiveLogic;

  /// Which entries survive when the token budget runs out: the lowest priority
  /// is discarded first (Agnai's meaning of the word).
  int priority;

  /// Where the entry sits among the others once chosen. The highest weight ends
  /// up closest to the reply, which is SillyTavern's `insertion_order` read the
  /// same way round.
  int weight;

  LorebookPosition position;

  /// For [LorebookPosition.atDepth]: how many messages follow the injection.
  int depth;

  /// For [LorebookPosition.atDepth]: whose turn the injection appears to be.
  LoreRole role;

  /// Percentage chance of activating once triggered (100 = always).
  int probability;
  bool useProbability;

  /// Per-entry overrides of the book-wide matching rules; null inherits.
  bool? caseSensitive;
  bool? matchWholeWords;
  int? scanDepth;

  /// Recursion controls: [excludeRecursion] keeps the entry from being
  /// activated *by* other lore, [preventRecursion] keeps its own text out of
  /// the recursive scan, and [delayUntilRecursion] holds it back until pass N.
  bool excludeRecursion;
  bool preventRecursion;
  int delayUntilRecursion;

  /// Inclusion group: among entries sharing a group name, only one is used —
  /// the [groupOverride] winner, else a [groupWeight]-weighted random pick.
  String group;
  bool groupOverride;
  int groupWeight;
  bool? useGroupScoring;

  /// Timed effects, in messages. Parsed and preserved for round-tripping;
  /// acting on them needs per-chat bookkeeping that does not exist yet, so they
  /// do not currently change what activates.
  int? sticky;
  int? cooldown;
  int? delay;

  /// SillyTavern fires this to its Quick Replies extension on activation. Kept
  /// so a book survives a round trip; MaiChat has nothing to fire it at.
  String automationId;

  /// Anything the source format carried that has no field here.
  Map<String, dynamic> extensions;

  /// What to show for an entry the author never named.
  String get displayName =>
      name.trim().isEmpty ? 'Untitled entry' : name.trim();

  /// A one-line preview of the injected text, for a collapsed row.
  String get blurb => content.replaceAll(RegExp(r'\s+'), ' ').trim();

  /// Whether this entry could ever activate: it has text, it is switched on,
  /// and it either fires unconditionally or has something to match on.
  bool get isUsable =>
      enabled &&
      content.trim().isNotEmpty &&
      (constant || keys.any((k) => k.trim().isNotEmpty));

  /// The fields the editor leaves blank on a brand-new entry, so the entry card
  /// can open itself rather than hiding an empty form behind a chevron.
  List<String> get missingFields => [
        if (name.trim().isEmpty) 'name',
        if (!constant && !keys.any((k) => k.trim().isNotEmpty)) 'keywords',
        if (content.trim().isEmpty) 'content',
      ];

  LorebookEntry copy() => LorebookEntry.fromJson(toJson());

  Map<String, dynamic> toJson() => {
        'uid': uid,
        if (name.isNotEmpty) 'name': name,
        if (content.isNotEmpty) 'content': content,
        if (keys.isNotEmpty) 'keys': keys,
        if (secondaryKeys.isNotEmpty) 'secondaryKeys': secondaryKeys,
        if (!enabled) 'enabled': false,
        if (constant) 'constant': true,
        if (!selective) 'selective': false,
        if (selectiveLogic != SelectiveLogic.andAny)
          'selectiveLogic': selectiveLogic.wire,
        'priority': priority,
        'weight': weight,
        if (position != LorebookPosition.beforeChar) 'position': position.wire,
        if (depth != 4) 'depth': depth,
        if (role != LoreRole.system) 'role': role.wire,
        if (probability != 100) 'probability': probability,
        if (!useProbability) 'useProbability': false,
        if (caseSensitive != null) 'caseSensitive': caseSensitive,
        if (matchWholeWords != null) 'matchWholeWords': matchWholeWords,
        if (scanDepth != null) 'scanDepth': scanDepth,
        if (excludeRecursion) 'excludeRecursion': true,
        if (preventRecursion) 'preventRecursion': true,
        if (delayUntilRecursion != 0) 'delayUntilRecursion': delayUntilRecursion,
        if (group.isNotEmpty) 'group': group,
        if (groupOverride) 'groupOverride': true,
        if (groupWeight != kLoreDefaultWeight) 'groupWeight': groupWeight,
        if (useGroupScoring != null) 'useGroupScoring': useGroupScoring,
        if (sticky != null) 'sticky': sticky,
        if (cooldown != null) 'cooldown': cooldown,
        if (delay != null) 'delay': delay,
        if (automationId.isNotEmpty) 'automationId': automationId,
        if (extensions.isNotEmpty) 'extensions': extensions,
      };

  factory LorebookEntry.fromJson(Map<String, dynamic> json) => LorebookEntry(
        uid: _int(json['uid']) ?? 0,
        name: json['name'] as String? ?? '',
        content: json['content'] as String? ?? '',
        keys: _strings(json['keys']),
        secondaryKeys: _strings(json['secondaryKeys']),
        enabled: json['enabled'] as bool? ?? true,
        constant: json['constant'] as bool? ?? false,
        selective: json['selective'] as bool? ?? true,
        selectiveLogic: SelectiveLogic.fromWire(json['selectiveLogic']),
        priority: _int(json['priority']) ?? kLoreDefaultWeight,
        weight: _int(json['weight']) ?? kLoreDefaultWeight,
        position: LorebookPosition.fromWire(json['position']),
        depth: _int(json['depth']) ?? 4,
        role: LoreRole.fromWire(json['role']),
        probability: _int(json['probability']) ?? 100,
        useProbability: json['useProbability'] as bool? ?? true,
        caseSensitive: json['caseSensitive'] as bool?,
        matchWholeWords: json['matchWholeWords'] as bool?,
        scanDepth: _int(json['scanDepth']),
        excludeRecursion: json['excludeRecursion'] as bool? ?? false,
        preventRecursion: json['preventRecursion'] as bool? ?? false,
        delayUntilRecursion: _int(json['delayUntilRecursion']) ?? 0,
        group: json['group'] as String? ?? '',
        groupOverride: json['groupOverride'] as bool? ?? false,
        groupWeight: _int(json['groupWeight']) ?? kLoreDefaultWeight,
        useGroupScoring: json['useGroupScoring'] as bool?,
        sticky: _int(json['sticky']),
        cooldown: _int(json['cooldown']),
        delay: _int(json['delay']),
        automationId: json['automationId'] as String? ?? '',
        extensions: json['extensions'] is Map
            ? Map<String, dynamic>.from(json['extensions'] as Map)
            : null,
      );
}

/// Where a book came from, shown as provenance and used to pick a sensible
/// default when exporting it again.
enum LorebookFormat {
  manual('MaiChat'),
  sillyTavern('SillyTavern'),
  agnai('Agnai'),
  characterCard('Character card');

  const LorebookFormat(this.label);
  final String label;

  static LorebookFormat fromName(Object? value) {
    for (final f in LorebookFormat.values) {
      if (f.name == value) return f;
    }
    return LorebookFormat.manual;
  }
}

/// A named collection of keyed facts that are injected into the prompt when the
/// conversation mentions them — SillyTavern calls it a World Info book, Agnai a
/// Memory Book, and this app a Lorebook.
class Lorebook {
  Lorebook({
    required this.id,
    required this.name,
    this.description = '',
    this.thumbnail = '',
    this.color,
    List<String>? tags,
    this.starred = false,
    List<LorebookEntry>? entries,
    this.scanDepth,
    this.tokenBudget,
    this.recursive = false,
    this.format = LorebookFormat.manual,
    Map<String, dynamic>? extensions,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : tags = tags ?? <String>[],
        entries = entries ?? <LorebookEntry>[],
        extensions = extensions ?? <String, dynamic>{},
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String name;
  String description;

  /// A picture for the book: an `http(s)` URL or a `local:<file>` reference into
  /// the shared picture store, the same convention character avatars use.
  String thumbnail;

  /// The book's own accent colour (ARGB), used for its card and its rows. Null
  /// falls back to the app's theme.
  int? color;

  List<String> tags;
  bool starred;
  List<LorebookEntry> entries;

  /// Book-wide overrides of how far back to scan and how many tokens of lore may
  /// enter one prompt; null uses [kLoreScanDepth] / [kLoreTokenBudget].
  int? scanDepth;
  int? tokenBudget;

  /// Whether activated lore is scanned again to activate further entries.
  bool recursive;

  LorebookFormat format;

  /// Book-level data the source format carried that has no field here.
  Map<String, dynamic> extensions;

  final DateTime createdAt;
  DateTime updatedAt;

  factory Lorebook.empty() => Lorebook(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: '',
      );

  String get displayName =>
      name.trim().isEmpty ? 'Untitled lorebook' : name.trim();

  /// A one-line blurb for list rows: the description, else what it contains.
  String get blurb {
    final flat = description.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isNotEmpty) return flat;
    final n = entries.length;
    return n == 1 ? '1 entry' : '$n entries';
  }

  bool get hasThumbnail => thumbnail.trim().isNotEmpty;

  /// The entries that could activate, in the order they were authored.
  List<LorebookEntry> get usableEntries =>
      entries.where((e) => e.isUsable).toList();

  int get enabledCount => entries.where((e) => e.enabled).length;

  /// The lowest unused entry id, so a new entry never collides with one that a
  /// SillyTavern book already keyed.
  int get nextUid {
    final used = entries.map((e) => e.uid).toSet();
    var uid = 0;
    while (used.contains(uid)) {
      uid++;
    }
    return uid;
  }

  /// Adds and returns a blank entry, opened by the editor for filling in.
  LorebookEntry addEntry() {
    final entry = LorebookEntry(uid: nextUid);
    entries.add(entry);
    return entry;
  }

  /// Whether [query] matches this book by name, description, tag, or the name
  /// or text of any entry — so library search finds a fact, not just a book.
  bool matches(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (name.toLowerCase().contains(q)) return true;
    if (description.toLowerCase().contains(q)) return true;
    if (tags.any((t) => t.toLowerCase().contains(q))) return true;
    return entries.any((e) =>
        e.name.toLowerCase().contains(q) ||
        e.content.toLowerCase().contains(q) ||
        e.keys.any((k) => k.toLowerCase().contains(q)));
  }

  Lorebook copyWith({
    String? name,
    String? description,
    String? thumbnail,
    int? color,
    bool clearColor = false,
    List<String>? tags,
    bool? starred,
    List<LorebookEntry>? entries,
    int? scanDepth,
    int? tokenBudget,
    bool? recursive,
    LorebookFormat? format,
    DateTime? updatedAt,
  }) =>
      Lorebook(
        id: id,
        name: name ?? this.name,
        description: description ?? this.description,
        thumbnail: thumbnail ?? this.thumbnail,
        color: clearColor ? null : (color ?? this.color),
        tags: tags ?? List<String>.from(this.tags),
        starred: starred ?? this.starred,
        entries: entries ?? this.entries.map((e) => e.copy()).toList(),
        scanDepth: scanDepth ?? this.scanDepth,
        tokenBudget: tokenBudget ?? this.tokenBudget,
        recursive: recursive ?? this.recursive,
        format: format ?? this.format,
        extensions: Map<String, dynamic>.from(extensions),
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (description.isNotEmpty) 'description': description,
        if (thumbnail.isNotEmpty) 'thumbnail': thumbnail,
        if (color != null) 'color': color,
        if (tags.isNotEmpty) 'tags': tags,
        if (starred) 'starred': true,
        if (scanDepth != null) 'scanDepth': scanDepth,
        if (tokenBudget != null) 'tokenBudget': tokenBudget,
        if (recursive) 'recursive': true,
        if (format != LorebookFormat.manual) 'format': format.name,
        if (extensions.isNotEmpty) 'extensions': extensions,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'entries': entries.map((e) => e.toJson()).toList(),
      };

  factory Lorebook.fromJson(Map<String, dynamic> json) => Lorebook(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        thumbnail: json['thumbnail'] as String? ?? '',
        color: _int(json['color']),
        tags: _strings(json['tags']),
        starred: json['starred'] as bool? ?? false,
        scanDepth: _int(json['scanDepth']),
        tokenBudget: _int(json['tokenBudget']),
        recursive: json['recursive'] as bool? ?? false,
        format: LorebookFormat.fromName(json['format']),
        extensions: json['extensions'] is Map
            ? Map<String, dynamic>.from(json['extensions'] as Map)
            : null,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
        entries: (json['entries'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(LorebookEntry.fromJson)
            .toList(),
      );
}



int? _int(Object? value) {
  if (value == null) return null;
  if (value is bool) return value ? 1 : 0;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

/// Reads a list of keys, tolerating the comma-separated string some exporters
/// write and dropping blanks.
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




