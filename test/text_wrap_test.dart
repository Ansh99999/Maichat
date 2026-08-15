import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/text_wrap.dart';

/// [matchWrap] is where a wrapping rule decides whether it applies at all. The
/// symmetric cases carry the weight: a single quote is punctuation in "isn't"
/// far more often than it is a delimiter, and an early version of this happily
/// paired the two apostrophes in "it's … isn't" and painted the sentence
/// between them.
void main() {
  const single = TextWrapRule(start: "'", end: "'");
  const angle = TextWrapRule(start: '<', end: '>');

  /// The wrapped content [rule] finds at the first occurrence of its opener, or
  /// null when it doesn't apply anywhere.
  String? wrapped(String s, TextWrapRule rule) {
    for (var i = 0; i < s.length; i++) {
      final m = matchWrap(s, i, rule);
      if (m != null) return s.substring(m.$1, m.$2);
    }
    return null;
  }

  group('symmetric markers', () {
    test('contractions are not delimiters', () {
      expect(wrapped("it's fine, isn't it? Don't worry.", single), isNull);
      expect(wrapped('the dogs\' bowls were theirs\' somehow', single), isNull);
    });

    test('a quoted phrase still matches', () {
      expect(wrapped("She thought 'this is fine' and left.", single),
          'this is fine');
    });

    test('a closer inside a word is skipped, not the end of the search', () {
      expect(wrapped("'he isn't here' she said", single), "he isn't here");
    });

    test('a run around a contraction still resolves', () {
      expect(wrapped("it's 'a good day', isn't it?", single), 'a good day');
    });

    test('a symmetric run does not cross a line break', () {
      expect(wrapped("'one\ntwo'", single), isNull);
    });

    test('an opener with no closer matches nothing', () {
      expect(wrapped("just one ' here", single), isNull);
    });
  });

  group('asymmetric markers', () {
    test('word edges do not matter — the pair is unambiguous', () {
      expect(wrapped('a<b c>d', angle), 'b c');
    });

    test('the first closer wins', () {
      expect(wrapped('<a> <b>', angle), 'a');
    });

    test('a run may cross a single line break', () {
      expect(wrapped('<one\ntwo>', angle), 'one\ntwo');
    });

    test('empty content is not a match', () {
      expect(wrapped('<> alone', angle), isNull);
    });
  });

  test('an unusable rule never matches', () {
    expect(matchWrap('anything', 0, const TextWrapRule(start: '', end: '>')),
        isNull);
    expect(
        matchWrap('anything', 0,
            const TextWrapRule(start: 'aaaaaaaaaaaa', end: '>')),
        isNull);
  });

  test('resumeAt lands just past the closing marker', () {
    final m = matchWrap('((hi)) there', 0,
        const TextWrapRule(start: '((', end: '))'))!;
    expect(m.$1, 2);
    expect(m.$2, 4);
    expect(m.$3, 6);
  });
}
