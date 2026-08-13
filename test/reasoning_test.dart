import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/services/reasoning.dart';

void main() {
  const tags = ReasoningTags(start: '<think>', end: '</think>');

  group('splitReasoning', () {
    test('lifts a whole block out of the reply', () {
      final split = splitReasoning('<think>weighing it up</think>Hello!', tags);
      expect(split.reasoning, 'weighing it up');
      expect(split.text, 'Hello!');
      expect(split.found, isTrue);
      expect(split.open, isFalse);
    });

    test('reports an unterminated block as still open', () {
      final split = splitReasoning('<think>still going', tags);
      expect(split.reasoning, 'still going');
      expect(split.text, isEmpty);
      expect(split.open, isTrue);
    });

    test('holds back a tag that has only partly arrived', () {
      // The tag straddles two SSE chunks; the fragment must not render as text.
      expect(splitReasoning('Hello <thi', tags).text, 'Hello ');
      expect(splitReasoning('Hello <think', tags).text, 'Hello ');
      expect(splitReasoning('Hello <', tags).text, 'Hello ');
    });

    test('treats a closing tag with no opening one as thinking from the top',
        () {
      // Several chat templates pre-fill the opening tag, so the model only ever
      // emits the closing one.
      final split = splitReasoning('reasoned it out</think>The answer.', tags);
      expect(split.reasoning, 'reasoned it out');
      expect(split.text, 'The answer.');
      expect(split.found, isTrue);
    });

    test('joins several blocks and keeps the text between them', () {
      final split = splitReasoning(
        '<think>one</think>First. <think>two</think>Second.',
        tags,
      );
      expect(split.reasoning, 'one\n\ntwo');
      expect(split.text, 'First. Second.');
    });

    test('leaves a reply without tags alone', () {
      final split = splitReasoning('Just an answer.', tags);
      expect(split.text, 'Just an answer.');
      expect(split.reasoning, isEmpty);
      expect(split.found, isFalse);
    });

    test('does nothing when either tag is unset', () {
      const half = ReasoningTags(start: '<think>');
      final split = splitReasoning('<think>hidden</think>Hi', half);
      expect(split.text, '<think>hidden</think>Hi');
      expect(split.reasoning, isEmpty);
      expect(split.found, isFalse);
    });

    test('works with a custom tag pair', () {
      const custom = ReasoningTags(start: '[REASON]', end: '[/REASON]');
      final split = splitReasoning('[REASON]hmm[/REASON]Done', custom);
      expect(split.reasoning, 'hmm');
      expect(split.text, 'Done');
    });

    test('strips the blank line a closing tag usually leaves behind', () {
      final split = splitReasoning('<think>x</think>\n\nHello', tags);
      expect(split.text, 'Hello');
    });

    test('re-reading a growing buffer converges on the same result', () {
      // How AppState uses it: the whole reply is re-split after every delta.
      const chunks = ['<thi', 'nk>we', 'ighing', '</thi', 'nk>', 'Hi ', 'there'];
      final raw = StringBuffer();
      final seen = <String>[];
      for (final chunk in chunks) {
        raw.write(chunk);
        final split = splitReasoning(raw.toString(), tags);
        seen.add(split.text);
      }
      // No intermediate state ever showed a tag fragment as message text.
      expect(seen.any((t) => t.contains('<') || t.contains('think')), isFalse);
      expect(seen.last, 'Hi there');
      expect(splitReasoning(raw.toString(), tags).reasoning, 'weighing');
    });
  });

  group('describeThinkingTime', () {
    test('reads as seconds, singular where it should', () {
      expect(describeThinkingTime(12400), 'Thought for 12 seconds');
      expect(describeThinkingTime(1000), 'Thought for 1 second');
    });

    test('rounds sub-second thinking up rather than saying zero', () {
      expect(describeThinkingTime(120), 'Thought for 1 second');
    });

    test('switches to minutes past a minute', () {
      expect(describeThinkingTime(60000), 'Thought for 1 minute');
      expect(describeThinkingTime(125000), 'Thought for 2 minutes 5 seconds');
    });

    test('falls back to a plain label when the duration is unknown', () {
      expect(describeThinkingTime(null), 'Thinking process');
    });
  });
}
