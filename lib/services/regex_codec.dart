/// Import/export of regex rules, wire-compatible with SillyTavern's Regex
/// extension. A rule there is a plain JSON object; a shared file is either one
/// such object or an array of them. We read both, plus the `regex_scripts`
/// array a character card or preset can carry in its extensions, and we write
/// the same object shape [RegexRule.toJson] emits — so a rule exported here
/// imports there unchanged.
library;

import 'dart:convert';

import '../models/regex_rule.dart';

/// Parses [text] into rules. Accepts:
///  - a single rule object,
///  - an array of rule objects,
///  - an object wrapping them under `regex_scripts` or `regex` (as a character
///    card's or preset's extensions field does).
/// Returns an empty list rather than throwing on anything unrecognised, so a
/// bad paste never crashes the importer.
List<RegexRule> parseRegexRules(String text) {
  dynamic json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    return <RegexRule>[];
  }
  return _rulesFrom(json);
}

List<RegexRule> _rulesFrom(dynamic json) {
  if (json is List) {
    return json
        .whereType<Map<String, dynamic>>()
        .where(_looksLikeRule)
        .map(RegexRule.fromJson)
        .toList();
  }
  if (json is Map<String, dynamic>) {
    // A wrapper carrying the scripts under a known key.
    for (final key in const ['regex_scripts', 'regex']) {
      final nested = json[key];
      if (nested is List) return _rulesFrom(nested);
    }
    if (_looksLikeRule(json)) return [RegexRule.fromJson(json)];
  }
  return <RegexRule>[];
}

/// A minimal sniff so a random JSON object is not read as an empty rule: it must
/// at least carry a find pattern under either field name.
bool _looksLikeRule(Map<String, dynamic> json) =>
    json.containsKey('findRegex') ||
    json.containsKey('find') ||
    (json.containsKey('scriptName') && json.containsKey('replaceString'));

/// One rule as a SillyTavern-compatible JSON string (pretty-printed, as ST's own
/// export is).
String encodeRegexRule(RegexRule rule) =>
    const JsonEncoder.withIndent('    ').convert(rule.toJson());

/// A set of rules as a JSON array — the "export all" shape ST also accepts.
String encodeRegexRules(List<RegexRule> rules) =>
    const JsonEncoder.withIndent('    ')
        .convert(rules.map((r) => r.toJson()).toList());

/// A filesystem-safe file name for a single exported rule, e.g. `regex-trim.json`.
String regexFileName(RegexRule rule) {
  final safe = rule.displayName
      .replaceAll(RegExp(r'[^a-zA-Z0-9._ -]'), '')
      .trim()
      .replaceAll(RegExp(r'\s+'), '-');
  return 'regex-${safe.isEmpty ? 'rule' : safe}.json';
}
