import 'package:flutter/foundation.dart';

/// How long a wrap marker may be. Markers are punctuation, not prose — a couple
/// of characters each side ("<", "((", "```") covers every real use, and a cap
/// keeps a pasted paragraph from becoming a delimiter that matches half a
/// message.
const int kMaxWrapMarkerLength = 8;

/// How many rules a user may keep. Every rule is tried at every character of
/// every message, so the list is deliberately short.
const int kMaxTextWrapRules = 24;

/// A user-defined "text wrapping" rule: text between [start] and [end] takes
/// [color], and the markers themselves are shown or hidden per [hideMarkers].
///
/// This is the general form of what the built-in styles already do — asterisks
/// italicise and vanish, quotes tint and stay — exposed so any pair of symbols
/// can be given the same treatment.
@immutable
class TextWrapRule {
  const TextWrapRule({
    required this.start,
    required this.end,
    this.color,
    this.hideMarkers = true,
    this.enabled = true,
  });

  /// The opening marker, e.g. `<`.
  final String start;

  /// The closing marker, e.g. `>`. May equal [start] (`|like this|`).
  final String end;

  /// ARGB tint for the wrapped run; null leaves it the colour of its
  /// surroundings (useful for a rule that only hides its markers).
  final int? color;

  /// Whether the markers are swallowed once matched (as `*` is) or kept in the
  /// rendered text (as `"` is).
  final bool hideMarkers;

  final bool enabled;

  /// Both markers present and short enough to use. An empty marker would match
  /// at every position without ever advancing the scanner, so it is rejected
  /// here once rather than guarded at each use.
  bool get isValid =>
      start.isNotEmpty &&
      end.isNotEmpty &&
      start.length <= kMaxWrapMarkerLength &&
      end.length <= kMaxWrapMarkerLength;

  /// Whether a renderer should apply this rule.
  bool get isActive => enabled && isValid;

  /// "< text >" — how the rule reads in the settings list.
  String get sample => '$start text $end';

  TextWrapRule copyWith({
    String? start,
    String? end,
    Object? color = _unset,
    bool? hideMarkers,
    bool? enabled,
  }) =>
      TextWrapRule(
        start: start ?? this.start,
        end: end ?? this.end,
        color: identical(color, _unset) ? this.color : color as int?,
        hideMarkers: hideMarkers ?? this.hideMarkers,
        enabled: enabled ?? this.enabled,
      );

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => {
        'start': start,
        'end': end,
        if (color != null) 'color': color,
        'hideMarkers': hideMarkers,
        'enabled': enabled,
      };

  /// Reads a stored rule, or null when the markers are missing or unusable — a
  /// hand-edited or truncated config should drop the bad rule, not the app.
  static TextWrapRule? fromJson(Map<String, dynamic> json) {
    final rule = TextWrapRule(
      start: json['start'] as String? ?? '',
      end: json['end'] as String? ?? '',
      color: (json['color'] as num?)?.toInt(),
      hideMarkers: json['hideMarkers'] as bool? ?? true,
      enabled: json['enabled'] as bool? ?? true,
    );
    return rule.isValid ? rule : null;
  }

  @override
  bool operator ==(Object other) =>
      other is TextWrapRule &&
      other.start == start &&
      other.end == end &&
      other.color == color &&
      other.hideMarkers == hideMarkers &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(start, end, color, hideMarkers, enabled);
}

/// The rules worth handing a renderer: the ones actually in force.
List<TextWrapRule> activeWrapRules(List<TextWrapRule> rules) =>
    [for (final r in rules) if (r.isActive) r];

/// Letters and digits, in any script — the "inside a word" test the matcher
/// leans on.
final _wordChar = RegExp(r'[\p{L}\p{N}]', unicode: true);

bool _isWordChar(String ch) => _wordChar.hasMatch(ch);

/// Where [rule] matches in [s] starting at [i], as
/// `(contentStart, contentEnd, resumeAt)`, or null when it does not apply there
/// — including when the rule is switched off or unusable.
///
/// A symmetric pair (`'…'`, `|…|`) is ambiguous in ordinary prose: an apostrophe
/// belongs to "isn't" far more often than it opens a quotation. So a symmetric
/// marker only opens where it isn't hanging off the end of a word, only closes
/// where it isn't hanging off the start of one, and never spans a line break;
/// a closer that fails those tests is skipped rather than ending the search, so
/// `'he isn't here'` still wraps the whole phrase. An asymmetric pair like `<…>`
/// says what it means and gets none of this treatment.
(int, int, int)? matchWrap(String s, int i, TextWrapRule rule) {
  if (!rule.isActive || !s.startsWith(rule.start, i)) return null;
  final symmetric = rule.start == rule.end;
  if (symmetric && i > 0 && _isWordChar(s[i - 1])) return null;
  final from = i + rule.start.length;
  var search = from;
  while (true) {
    final end = s.indexOf(rule.end, search);
    // Nothing left to close with, or nothing between the markers.
    if (end < from + 1) return null;
    final resume = end + rule.end.length;
    if (symmetric) {
      if (s.substring(from, end).contains('\n')) return null;
      if (resume < s.length && _isWordChar(s[resume])) {
        search = resume; // Closes a word, so it isn't a closer. Keep looking.
        continue;
      }
    }
    return (from, end, resume);
  }
}

/// Reads a stored rule list, skipping entries that aren't usable and honouring
/// [kMaxTextWrapRules].
List<TextWrapRule> textWrapRulesFromJson(Object? value) {
  if (value is! List) return const [];
  final out = <TextWrapRule>[];
  for (final e in value) {
    if (e is! Map) continue;
    final rule = TextWrapRule.fromJson(e.cast<String, dynamic>());
    if (rule != null) out.add(rule);
    if (out.length == kMaxTextWrapRules) break;
  }
  return List.unmodifiable(out);
}
