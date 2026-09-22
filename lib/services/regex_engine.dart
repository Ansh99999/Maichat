import '../models/character.dart';
import '../models/regex_rule.dart';

/// A compiled pattern plus whether it carried the global (`g`) flag — Dart has
/// no global flag on [RegExp] itself, so the caller decides between replacing
/// the first match and replacing all.
class _Compiled {
  const _Compiled(this.regex, this.global);
  final RegExp regex;
  final bool global;
}

/// Runs MaiChat's regex find/replace rules — the port of SillyTavern's Regex
/// extension engine (`public/scripts/extensions/regex/engine.js`).
///
/// Everything here is pure string work: no state beyond a small LRU cache of
/// compiled patterns, so a rule that fires on every message never recompiles.
/// The three ephemerality modes are gated exactly as SillyTavern gates them, so
/// a rule imported from there behaves the same.
class RegexEngine {
  RegexEngine._();

  /// Compiled-pattern cache, newest-used last. Bounded so a runaway set of
  /// distinct patterns cannot grow it without limit.
  static final Map<String, _Compiled> _cache = <String, _Compiled>{};
  static const int _maxCache = 256;

  static final RegExp _matchToken =
      RegExp(r'\{\{match\}\}', caseSensitive: false);
  static final RegExp _groupRef = RegExp(r'\$(\d+)|\$<([^>]+)>');
  static final RegExp _userMacro = RegExp(r'\{\{user\}\}', caseSensitive: false);
  static final RegExp _charMacro = RegExp(r'\{\{char\}\}', caseSensitive: false);

  /// Empties the cache. Only needed by tests — patterns never change identity in
  /// normal use, and eviction handles growth.
  static void clearCache() => _cache.clear();

  /// Compiles a find pattern in either the bare form (`\bfoo\b`) or the
  /// delimited form SillyTavern shares (`/foo/gi`). Returns null for an empty or
  /// invalid pattern, so a typo skips the rule rather than throwing mid-send.
  static _Compiled? _compilePattern(String input) {
    if (input.isEmpty) return null;
    final cached = _cache[input];
    if (cached != null) {
      // LRU touch: re-insert to move to the end.
      _cache.remove(input);
      _cache[input] = cached;
      return cached;
    }

    final compiled = _build(input);
    if (compiled == null) return null;

    if (_cache.length >= _maxCache) {
      _cache.remove(_cache.keys.first);
    }
    _cache[input] = compiled;
    return compiled;
  }

  static _Compiled? _build(String input) {
    String body = input;
    String flags = '';
    // Delimited form: /body/flags — the shape used when sharing rules.
    var delimited = false;
    if (input.length >= 2 && input.startsWith('/')) {
      final lastSlash = input.lastIndexOf('/');
      if (lastSlash > 0) {
        final maybeFlags = input.substring(lastSlash + 1);
        if (RegExp(r'^[a-z]*$', caseSensitive: false).hasMatch(maybeFlags)) {
          body = input.substring(1, lastSlash);
          flags = maybeFlags.toLowerCase();
          delimited = true;
        }
      }
    }
    if (body.isEmpty) return null;

    try {
      final regex = RegExp(
        body,
        caseSensitive: !flags.contains('i'),
        multiLine: flags.contains('m'),
        dotAll: flags.contains('s'),
        unicode: flags.contains('u'),
      );
      // A bare pattern replaces *every* match — that is what "find and replace"
      // means to someone who has not memorised regex flags, and it is the single
      // biggest "why did only the first one change" surprise. The delimited
      // /pattern/flags form is honoured exactly as written (no `g` = first only),
      // so rules shared to and from SillyTavern keep their meaning.
      final global = delimited ? flags.contains('g') : true;
      return _Compiled(regex, global);
    } catch (_) {
      // An invalid pattern (or a JS flag Dart has no equivalent for that made
      // the body unparseable) simply does not apply.
      return null;
    }
  }

  /// Runs a single [rule] over [input], returning the transformed string.
  /// Disabled rules and unparseable patterns pass the text through untouched.
  static String runRule(
    RegexRule rule,
    String input, {
    String userName = 'User',
    String charName = '',
  }) {
    if (rule.disabled || rule.find.isEmpty || input.isEmpty) return input;

    final findString = _substituteFind(rule, userName, charName);
    final compiled = _compilePattern(findString);
    if (compiled == null) return input;

    String expand(Match match) {
      // {{match}} is an alias for the whole match ($0).
      final template = rule.replace.replaceAll(_matchToken, r'$0');
      return _resolveMacros(
        template.replaceAllMapped(_groupRef, (ref) {
          final numeric = ref.group(1);
          final named = ref.group(2);
          String? value;
          if (numeric != null) {
            final index = int.parse(numeric);
            value = index <= match.groupCount ? match.group(index) : null;
          } else if (named != null && match is RegExpMatch) {
            try {
              value = match.namedGroup(named);
            } catch (_) {
              // A named group that the pattern never declared.
              value = null;
            }
          }
          if (value == null || value.isEmpty) return '';
          return _trim(value, rule.trimStrings, userName, charName);
        }),
        userName,
        charName,
      );
    }

    return compiled.global
        ? input.replaceAllMapped(compiled.regex, expand)
        : input.replaceFirstMapped(compiled.regex, expand);
  }

  /// Runs every rule in [rules] that applies to [target] under the given call
  /// conditions, in order. Mirrors SillyTavern's `getRegexedString` gate:
  ///  - display-only rules fire only when [isDisplay];
  ///  - prompt-only rules fire only when [isPrompt];
  ///  - permanent rules (neither flag) fire only when it is neither a display
  ///    nor a prompt pass — i.e. the point the message is stored.
  static String apply(
    List<RegexRule> rules,
    String input, {
    required RegexTarget target,
    bool isDisplay = false,
    bool isPrompt = false,
    bool isEdit = false,
    int? depth,
    String userName = 'User',
    String charName = '',
  }) {
    if (input.isEmpty || rules.isEmpty) return input;

    var out = input;
    for (final rule in rules) {
      if (rule.disabled) continue;

      final applies = (rule.markdownOnly && isDisplay) ||
          (rule.promptOnly && isPrompt) ||
          (!rule.markdownOnly &&
              !rule.promptOnly &&
              !isDisplay &&
              !isPrompt);
      if (!applies) continue;

      if (isEdit && !rule.runOnEdit) continue;

      if (depth != null) {
        final min = rule.minDepth;
        final max = rule.maxDepth;
        if (min != null && min >= -1 && depth < min) continue;
        if (max != null && max >= 0 && depth > max) continue;
      }

      if (!rule.actsOn(target)) continue;

      out = runRule(rule, out, userName: userName, charName: charName);
    }
    return out;
  }

  /// Whether any enabled rule would act on [target] under these conditions —
  /// lets callers skip building name context and copying strings when there is
  /// nothing to do.
  static bool hasWork(
    List<RegexRule> rules, {
    required RegexTarget target,
    bool isDisplay = false,
    bool isPrompt = false,
  }) {
    for (final rule in rules) {
      if (rule.disabled || !rule.actsOn(target)) continue;
      final applies = (rule.markdownOnly && isDisplay) ||
          (rule.promptOnly && isPrompt) ||
          (!rule.markdownOnly &&
              !rule.promptOnly &&
              !isDisplay &&
              !isPrompt);
      if (applies) return true;
    }
    return false;
  }

  // --- helpers -------------------------------------------------------------

  static String _substituteFind(RegexRule rule, String userName, String charName) {
    switch (rule.macroMode) {
      case RegexMacroMode.none:
        return rule.find;
      case RegexMacroMode.raw:
        return rule.find
            .replaceAll(_userMacro, userName)
            .replaceAll(_charMacro, charName);
      case RegexMacroMode.escaped:
        return rule.find
            .replaceAll(_userMacro, _escapeRegex(userName))
            .replaceAll(_charMacro, _escapeRegex(charName));
    }
  }

  static String _resolveMacros(String text, String userName, String charName) =>
      Character.resolveMacros(text, charName: charName, userName: userName);

  static String _trim(
    String value,
    List<String> trimStrings,
    String userName,
    String charName,
  ) {
    if (trimStrings.isEmpty) return value;
    var out = value;
    for (final trim in trimStrings) {
      if (trim.isEmpty) continue;
      final resolved = _resolveMacros(trim, userName, charName);
      if (resolved.isNotEmpty) out = out.replaceAll(resolved, '');
    }
    return out;
  }

  static final RegExp _regexSpecials = RegExp(r'[.*+?^${}()|[\]\\]');

  static String _escapeRegex(String input) =>
      input.replaceAllMapped(_regexSpecials, (m) => '\\${m[0]}');
}
