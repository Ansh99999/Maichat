import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/summary.dart';

void main() {
  group('ChatSummary', () {
    ChatSummary sample() => ChatSummary(
          enabled: true,
          interval: 15,
          providerId: 'p1',
          model: 'gpt-x',
          budget: 800,
          method: SummaryMethod.incremental,
          notify: true,
          useCustomPrompt: true,
          prompt: 'Condense tersely.',
          title: 'Memory',
          segments: [
            SummarySegment(
                id: 'a', title: 'One', content: 'First part.', tokens: 3),
            SummarySegment(
                id: 'b', title: 'Two', content: 'Second part.', tokens: 4),
          ],
          lastSummarizedIndex: 20,
        );

    test('round-trips through JSON', () {
      final json = sample().toJson();
      final back = ChatSummary.fromJson(json);
      expect(back.enabled, isTrue);
      expect(back.interval, 15);
      expect(back.providerId, 'p1');
      expect(back.model, 'gpt-x');
      expect(back.budget, 800);
      expect(back.method, SummaryMethod.incremental);
      expect(back.notify, isTrue);
      expect(back.useCustomPrompt, isTrue);
      expect(back.prompt, 'Condense tersely.');
      expect(back.title, 'Memory');
      expect(back.lastSummarizedIndex, 20);
      expect(back.segments.map((s) => s.content).toList(),
          ['First part.', 'Second part.']);
    });

    test('combinedText joins titled segments and totalTokens sums them', () {
      final s = sample();
      expect(s.combinedText, '## One\nFirst part.\n\n## Two\nSecond part.');
      expect(s.totalTokens, 7);
    });

    test('effectivePrompt falls back to the default when custom is off', () {
      final s = sample().copyWith(useCustomPrompt: false);
      expect(s.effectivePrompt, kDefaultSummaryPrompt);
      final custom = sample();
      expect(custom.effectivePrompt, 'Condense tersely.');
    });

    test('clone is a deep copy', () {
      final original = sample();
      final clone = original.clone();
      clone.segments.first.content = 'changed';
      expect(original.segments.first.content, 'First part.');
    });

    test('manual segments round-trip and copyWith preserves the flag', () {
      final seg = SummarySegment(
          id: 'm1', title: 'Mine', content: 'hand written', manual: true);
      final back = SummarySegment.fromJson(seg.toJson());
      expect(back.manual, isTrue);
      // copyWith without touching `manual` keeps it.
      expect(seg.copyWith(content: 'edited').manual, isTrue);
      // A generated segment stays non-manual through JSON.
      final gen = SummarySegment(id: 'g', content: 'auto');
      expect(SummarySegment.fromJson(gen.toJson()).manual, isFalse);
    });
  });

  group('Conversation carries summary and lorebook overrides', () {
    Conversation rich() => Conversation(
          id: 'c1',
          title: 'Thread',
          updatedAt: DateTime.parse('2026-08-16T12:00:00.000Z'),
          messages: [ChatMessage(role: 'user', content: 'hi')],
          lorebookIds: ['lore-1'],
          lorebookOverrides: {
            'lore-1': Lorebook.empty()..name = 'Local copy',
          },
          summary: ChatSummary(
            enabled: true,
            title: 'S',
            segments: [SummarySegment(id: 'x', content: 'body')],
          ),
        );

    test('toJson/fromJson preserve both', () {
      final back = Conversation.fromJson(rich().toJson());
      expect(back.summary, isNotNull);
      expect(back.summary!.segments.single.content, 'body');
      expect(back.lorebookOverrides['lore-1']?.name, 'Local copy');
    });

    test('copyAs deep-copies both without sharing', () {
      final source = rich();
      final copy = source.copyAs(id: 'c2');
      expect(copy.id, 'c2');
      expect(copy.summary!.segments.single.content, 'body');
      expect(copy.lorebookOverrides['lore-1']?.name, 'Local copy');
      // Mutating the copy must not touch the source.
      copy.summary!.segments.first.content = 'edited';
      copy.lorebookOverrides['lore-1']!.name = 'Renamed';
      expect(source.summary!.segments.single.content, 'body');
      expect(source.lorebookOverrides['lore-1']?.name, 'Local copy');
    });
  });
}
