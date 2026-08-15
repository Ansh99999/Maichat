import 'dart:math';

import '../models/character.dart';
import '../models/lorebook.dart';
import '../models/message.dart';
import 'token_estimator.dart';

/// A block of activated lore that goes *into* the chat history rather than in
/// front of it, at [depth] messages from the end, speaking as [role].
class LoreInjection {
  const LoreInjection({
    required this.text,
    required this.depth,
    required this.role,
  });

  final String text;
  final int depth;
  final LoreRole role;
}

/// One entry that made it into the prompt, for the "Info" view and for tests to
/// assert against without re-deriving the algorithm.
class ActivatedLore {
  const ActivatedLore({
    required this.book,
    required this.entry,
    required this.tokens,
    required this.constant,
    required this.triggeredBy,
  });

  /// The book the entry came from.
  final String book;

  /// The entry's name, or its first keyword when it was never named.
  final String entry;
  final int tokens;

  /// Whether it activated because it is always-on rather than by a keyword.
  final bool constant;

  /// The keyword that matched, empty for a constant entry.
  final String triggeredBy;
}

/// Everything the active lorebooks contribute to one request, already placed in
/// the four slots the prompt has room for.
class WorldInfo {
  const WorldInfo({
    this.before = '',
    this.after = '',
    this.exampleTop = '',
    this.exampleBottom = '',
    this.injections = const <LoreInjection>[],
    this.activated = const <ActivatedLore>[],
    this.tokens = 0,
  });

  /// Lore placed ahead of the character definitions.
  final String before;

  /// Lore placed after the character definitions.
  final String after;

  /// Lore wrapped around the example dialogue.
  final String exampleTop;
  final String exampleBottom;

  /// Lore injected between chat turns.
  final List<LoreInjection> injections;

  final List<ActivatedLore> activated;

  /// What all of the above costs, measured the same way the prompt budget is.
  final int tokens;

  static const WorldInfo none = WorldInfo();

  bool get isEmpty =>
      before.isEmpty &&
      after.isEmpty &&
      exampleTop.isEmpty &&
      exampleBottom.isEmpty &&
      injections.isEmpty;
}

/// Decides which lorebook entries this request should carry, following the
/// algorithm SillyTavern's world info and Agnai's memory books share:
///
///  1. Pool the entries of every active book.
///  2. Scan the last N messages for each entry's keywords, newest first, and
///     activate the entries that match (plus the always-on "constant" ones).
///  3. Feed what activated back through the scan, if the book asks for it, so
///     one fact can pull in another.
///  4. Where entries compete for a slot, let the inclusion groups pick one.
///  5. Fit the winners into a token budget, dropping the lowest **priority**
///     first, then order what is left by **weight** so the heaviest entry sits
///     closest to the reply.
///  6. Place each entry in the slot its `position` asks for.
///
/// Deliberately not implemented, and inert rather than half-done: `sticky`,
/// `cooldown` and `delay` (they need per-chat bookkeeping that does not exist
/// here yet), minimum activations, and vector-based activation.
class WorldInfoScanner {
  WorldInfoScanner({TokenEstimator? tokens, Random? random})
      : _tokens = tokens ?? const HeuristicTokenEstimator(),
        _random = random ?? Random();

  final TokenEstimator _tokens;
  final Random _random;

  /// Sits between messages in the scan buffer. It is a non-word character, so a
  /// key at the very start of a message still counts as being on a word
  /// boundary, and a multi-word key cannot match across two messages.
  static const String _joint = '\n';

  WorldInfo scan({
    required List<Lorebook> books,
    required List<ChatMessage> history,
    String charName = '',
    String userName = 'You',
    bool includeNames = true,
    int? budget,
  }) {
    final candidates = <_Candidate>[];
    for (final book in books) {
      for (final entry in book.entries) {
        if (entry.isUsable) candidates.add(_Candidate(book, entry));
      }
    }
    if (candidates.isEmpty) return WorldInfo.none;

    // Newest message first, so the index of a match is its age in turns. Names
    // are part of the searched text (as in both originals), which is why a
    // keyword equal to a character's name matches every one of their turns.
    final lines = <String>[
      for (final m in history.reversed)
        if (m.content.trim().isNotEmpty)
          includeNames
              ? '${_speaker(m, charName, userName)}: ${m.content}'
              : m.content,
    ];

    final tokenBudget = budget ??
        books
            .map((b) => b.tokenBudget ?? kLoreTokenBudget)
            .fold<int>(0, max)
            .clamp(1, 1 << 30)
            .toInt();
    final recursive = books.any((b) => b.recursive);

    final matched = <_Match>[];
    final seen = <_Candidate>{};
    final failedRoll = <_Candidate>{};
    var recursionText = '';

    for (var pass = 0; pass <= kLoreMaxRecursion; pass++) {
      final fresh = <_Match>[];
      for (final candidate in candidates) {
        if (seen.contains(candidate) || failedRoll.contains(candidate)) continue;
        final entry = candidate.entry;
        // Held back until the pass its author asked for.
        if (entry.delayUntilRecursion > pass) continue;

        final hit = _find(candidate, lines, recursionText);
        if (hit == null) continue;
        if (!_rollFor(entry)) {
          failedRoll.add(candidate);
          continue;
        }
        seen.add(candidate);
        fresh.add(_Match(
          candidate: candidate,
          age: hit.age,
          key: hit.key,
          text: _resolve(entry.content, charName, userName),
        ));
      }
      if (fresh.isEmpty) break;
      matched.addAll(fresh);
      if (!recursive) break;
      final feed = fresh
          .where((m) => !m.candidate.entry.preventRecursion)
          .map((m) => m.text)
          .where((t) => t.isNotEmpty);
      if (feed.isEmpty) break;
      recursionText = [recursionText, ...feed]
          .where((t) => t.isNotEmpty)
          .join(_joint);
    }

    if (matched.isEmpty) return WorldInfo.none;
    return _assemble(_pickGroups(matched), tokenBudget);
  }

  /// How a turn is labelled in the scanned text. Both originals include the
  /// speaker's name, which is why a keyword equal to a name always matches.
  static String _speaker(ChatMessage m, String charName, String userName) {
    switch (m.role) {
      case 'user':
        return userName.trim().isEmpty ? 'You' : userName.trim();
      case 'assistant':
        return charName.trim().isEmpty ? 'Assistant' : charName.trim();
      default:
        return 'System';
    }
  }

  static String _resolve(String text, String charName, String userName) =>
      Character.resolveMacros(text, charName: charName, userName: userName);

  /// The newest message an entry's keywords appear in, or null when it does not
  /// activate. A constant entry activates without looking at anything.
  _Hit? _find(_Candidate c, List<String> lines, String recursionText) {
    final e = c.entry;
    if (e.constant) return const _Hit(0, '');

    final depth = e.scanDepth ?? c.book.scanDepth ?? kLoreScanDepth;
    if (depth <= 0) return null;
    final window = lines.take(depth).toList();
    final extra = e.excludeRecursion ? '' : recursionText;
    if (window.isEmpty && extra.isEmpty) return null;

    String? key;
    var age = 0;
    for (var i = 0; i < window.length && key == null; i++) {
      for (final k in e.keys) {
        if (_matchKey(window[i], k, e)) {
          key = k;
          age = i;
          break;
        }
      }
    }
    // Lore pulled in by other lore has no age of its own, so it sorts as the
    // oldest thing that could have triggered the entry.
    if (key == null && extra.isNotEmpty) {
      for (final k in e.keys) {
        if (_matchKey(extra, k, e)) {
          key = k;
          age = window.length;
          break;
        }
      }
    }
    if (key == null) return null;

    final whole = [
      if (window.isNotEmpty) window.join(_joint),
      if (extra.isNotEmpty) extra,
    ].join(_joint);
    if (!_secondaryOk(whole, e)) return null;
    return _Hit(age, key);
  }

  /// Whether the secondary keys are satisfied. They are only consulted when the
  /// entry is `selective` and actually has some — an entry that names secondary
  /// keys but is not selective activates on its primary keys alone.
  bool _secondaryOk(String text, LorebookEntry e) {
    if (!e.selective) return true;
    final keys = e.secondaryKeys.where((k) => k.trim().isNotEmpty).toList();
    if (keys.isEmpty) return true;
    final hits = [for (final k in keys) _matchKey(text, k, e)];
    return switch (e.selectiveLogic) {
      SelectiveLogic.andAny => hits.contains(true),
      SelectiveLogic.notAll => hits.contains(false),
      SelectiveLogic.notAny => !hits.contains(true),
      SelectiveLogic.andAll => !hits.contains(false),
    };
  }

  bool _rollFor(LorebookEntry e) {
    if (!e.useProbability || e.probability >= 100) return true;
    if (e.probability <= 0) return false;
    return _random.nextInt(100) < e.probability;
  }

  /// Whether [needle] appears in [haystack] under this entry's matching rules.
  static bool _matchKey(String haystack, String needle, LorebookEntry e) {
    final key = needle.trim();
    if (key.isEmpty || haystack.isEmpty) return false;
    final re = _regexFor(
      key,
      caseSensitive: e.caseSensitive ?? false,
      wholeWords: e.matchWholeWords ?? true,
    );
    return re != null && re.hasMatch(haystack);
  }

  /// Compiled keys, cached: a scan asks the same question of every message.
  static final Map<String, RegExp?> _patterns = <String, RegExp?>{};

  /// Turns a key into a pattern.
  ///
  ///  * `/pattern/flags` is used as a regular expression verbatim, and then the
  ///    case and whole-word settings do not apply — the author asked for exactly
  ///    this. This is SillyTavern's behaviour and how shared books are written.
  ///  * Otherwise the key is literal text, except that `*` stands for any run of
  ///    word characters and `?` for one, which is what Agnai's books expect
  ///    (`book*` finds "books" and "booking", but not "ebook").
  ///  * Whole-word matching wraps the key in non-word boundaries. A key of
  ///    several words falls back to a plain substring search, as it does in
  ///    SillyTavern, because the boundaries stop making sense.
  static RegExp? _regexFor(
    String key, {
    required bool caseSensitive,
    required bool wholeWords,
  }) {
    final cacheKey = '$caseSensitive|$wholeWords|$key';
    if (_patterns.containsKey(cacheKey)) return _patterns[cacheKey];
    RegExp? compiled;
    final asRegex = RegExp(r'^/([\s\S]+)/([gimsuy]*)$').firstMatch(key);
    if (asRegex != null) {
      try {
        final flags = asRegex.group(2) ?? '';
        compiled = RegExp(
          asRegex.group(1)!,
          caseSensitive: !flags.contains('i'),
          multiLine: flags.contains('m'),
          dotAll: flags.contains('s'),
          unicode: true,
        );
      } catch (_) {
        compiled = null; // A malformed key matches nothing rather than throwing.
      }
    } else {
      final literal = RegExp.escape(key)
          .replaceAll(r'\*', r'\w*')
          .replaceAll(r'\?', r'\w');
      final oneWord = !key.contains(RegExp(r'\s'));
      final pattern = wholeWords && oneWord
          ? '(?:^|\\W)$literal(?:\$|\\W)'
          : literal;
      try {
        compiled = RegExp(pattern, caseSensitive: caseSensitive, unicode: true);
      } catch (_) {
        compiled = null;
      }
    }
    _patterns[cacheKey] = compiled;
    return compiled;
  }

  /// Keeps one entry per inclusion group: the `groupOverride` member with the
  /// highest weight if there is one, else a random pick weighted by
  /// `groupWeight`. An entry naming several groups is judged by its first, which
  /// is where this stops short of SillyTavern's version.
  List<_Match> _pickGroups(List<_Match> matched) {
    final out = <_Match>[];
    final groups = <String, List<_Match>>{};
    for (final m in matched) {
      final name = m.entry.group
          .split(',')
          .map((g) => g.trim())
          .firstWhere((g) => g.isNotEmpty, orElse: () => '');
      if (name.isEmpty) {
        out.add(m);
      } else {
        groups.putIfAbsent(name, () => <_Match>[]).add(m);
      }
    }
    for (final members in groups.values) {
      if (members.length == 1) {
        out.add(members.first);
        continue;
      }
      final overrides = members.where((m) => m.entry.groupOverride).toList()
        ..sort((a, b) => b.entry.weight.compareTo(a.entry.weight));
      if (overrides.isNotEmpty) {
        out.add(overrides.first);
        continue;
      }
      final total =
          members.fold<int>(0, (sum, m) => sum + max(1, m.entry.groupWeight));
      var roll = _random.nextInt(total);
      for (final m in members) {
        roll -= max(1, m.entry.groupWeight);
        if (roll < 0) {
          out.add(m);
          break;
        }
      }
    }
    return out;
  }

  /// Fits the activated entries into [budget] and places them in their slots.
  WorldInfo _assemble(List<_Match> matched, int budget) {
    for (final m in matched) {
      m.tokens = _tokens.estimate(m.text);
    }

    // Who survives: the highest priority is kept, and among equals the heavier
    // entry, then the one triggered most recently. Both originals stop at the
    // first entry that does not fit rather than skipping it and carrying on,
    // which keeps the result predictable.
    final queue = [...matched]..sort((a, b) {
      final byPriority = b.entry.priority.compareTo(a.entry.priority);
      if (byPriority != 0) return byPriority;
      final byWeight = b.entry.weight.compareTo(a.entry.weight);
      if (byWeight != 0) return byWeight;
      return a.age.compareTo(b.age);
    });
    final kept = <_Match>[];
    var used = 0;
    for (final m in queue) {
      if (m.text.trim().isEmpty) continue;
      if (used + m.tokens > budget) break;
      used += m.tokens;
      kept.add(m);
    }
    if (kept.isEmpty) return WorldInfo.none;

    // How they read: lightest first, so the heaviest entry ends up last — the
    // closest to the reply, which is what "weight" means in both originals.
    kept.sort((a, b) {
      final byWeight = a.entry.weight.compareTo(b.entry.weight);
      if (byWeight != 0) return byWeight;
      return b.age.compareTo(a.age);
    });

    final before = <String>[];
    final after = <String>[];
    final exampleTop = <String>[];
    final exampleBottom = <String>[];
    // One injected message per depth-and-role pair, as SillyTavern buckets them.
    final depths = <String, List<String>>{};
    final depthKeys = <String, LoreInjection>{};

    for (final m in kept) {
      switch (m.entry.position) {
        // MaiChat has no Author's Note, so the two notes' slots anchor to the
        // nearest thing that does exist rather than dropping the entry.
        case LorebookPosition.beforeChar:
        case LorebookPosition.anTop:
          before.add(m.text);
        case LorebookPosition.afterChar:
        case LorebookPosition.anBottom:
          after.add(m.text);
        case LorebookPosition.emTop:
          exampleTop.add(m.text);
        case LorebookPosition.emBottom:
          exampleBottom.add(m.text);
        case LorebookPosition.atDepth:
          final key = '${m.entry.depth}|${m.entry.role.wire}';
          depths.putIfAbsent(key, () => <String>[]).add(m.text);
          depthKeys[key] = LoreInjection(
            text: '',
            depth: m.entry.depth,
            role: m.entry.role,
          );
      }
    }

    final injections = <LoreInjection>[
      for (final key in depths.keys)
        LoreInjection(
          text: depths[key]!.join('\n'),
          depth: depthKeys[key]!.depth,
          role: depthKeys[key]!.role,
        ),
    ]..sort((a, b) => a.depth.compareTo(b.depth));

    return WorldInfo(
      before: before.join('\n'),
      after: after.join('\n'),
      exampleTop: exampleTop.join('\n'),
      exampleBottom: exampleBottom.join('\n'),
      injections: injections,
      activated: [
        for (final m in kept)
          ActivatedLore(
            book: m.candidate.book.displayName,
            entry: m.entry.name.trim().isEmpty
                ? (m.entry.keys.isEmpty ? 'Untitled entry' : m.entry.keys.first)
                : m.entry.name.trim(),
            tokens: m.tokens,
            constant: m.entry.constant,
            triggeredBy: m.key,
          ),
      ],
      tokens: used,
    );
  }
}

/// An entry paired with the book it came from, so the book's own scan settings
/// travel with it.
class _Candidate {
  const _Candidate(this.book, this.entry);
  final Lorebook book;
  final LorebookEntry entry;
}

/// Where an entry's keyword was found: [age] messages back (0 is the newest),
/// by the key [key] (empty for an always-on entry).
class _Hit {
  const _Hit(this.age, this.key);
  final int age;
  final String key;
}

/// An activated entry on its way into the prompt.
class _Match {
  _Match({
    required this.candidate,
    required this.age,
    required this.key,
    required this.text,
  });

  final _Candidate candidate;
  final int age;
  final String key;

  /// The injected text with the identity macros already resolved.
  final String text;

  /// Filled in once, when the budget is applied.
  int tokens = 0;

  LorebookEntry get entry => candidate.entry;
}





