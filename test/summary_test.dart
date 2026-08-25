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

    test('collapsed round-trips, is omitted when false, and copyWith keeps it',
        () {
      final open = SummarySegment(id: 'o', content: 'x');
      expect(open.toJson().containsKey('collapsed'), isFalse);
      final folded = SummarySegment(id: 'f', content: 'y', collapsed: true);
      expect(folded.toJson()['collapsed'], isTrue);
      expect(SummarySegment.fromJson(folded.toJson()).collapsed, isTrue);
      // copyWith without touching `collapsed` keeps it.
      expect(folded.copyWith(content: 'z').collapsed, isTrue);
    });

    group('coverage and pending ranges (the manual "Summarise now" path)', () {
      ChatSummary incremental({
        int interval = 10,
        int lastSummarizedIndex = 0,
        List<SummarySegment>? segments,
      }) =>
          ChatSummary(
            enabled: true,
            method: SummaryMethod.incremental,
            interval: interval,
            lastSummarizedIndex: lastSummarizedIndex,
            segments: segments,
          );

      test('coveredIndex tracks the generated segments, not the high-water mark',
          () {
        final cfg = incremental(
          lastSummarizedIndex: 60,
          segments: [
            SummarySegment(id: 'a', startIndex: 0, endIndex: 50),
            SummarySegment(id: 'b', startIndex: 50, endIndex: 60),
          ],
        );
        expect(cfg.coveredIndex(60), 60);
        // Delete the 51–60 block: coverage falls back to the earlier segment,
        // even though lastSummarizedIndex still reads 60.
        cfg.segments.removeWhere((s) => s.id == 'b');
        expect(cfg.coveredIndex(60), 50);
        // Manual (hand-written) blocks never count towards coverage.
        cfg.segments.add(SummarySegment(
            id: 'm', startIndex: 0, endIndex: 999, manual: true));
        expect(cfg.coveredIndex(60), 50);
      });

      test('a forced run re-covers the gap left by a deleted block', () {
        final cfg = incremental(
          lastSummarizedIndex: 60,
          segments: [
            SummarySegment(id: 'a', startIndex: 0, endIndex: 50),
          ],
        );
        // Nothing is pending automatically (60 - 60 < interval)…
        expect(cfg.pendingRanges(60, force: false), isEmpty);
        // …but forcing works from coverage (50) and refills 50–60.
        expect(cfg.pendingRanges(60, force: true), [(50, 60)]);
      });

      test('a forced run summarises a single new message, ignoring the interval',
          () {
        final cfg = incremental(
          lastSummarizedIndex: 60,
          segments: [
            SummarySegment(id: 'a', startIndex: 0, endIndex: 60),
          ],
        );
        // 61 messages now; one past the covered 60.
        expect(cfg.pendingRanges(61, force: false), isEmpty);
        expect(cfg.pendingRanges(61, force: true), [(60, 61)]);
      });

      test('nothing pending when the memory already covers every message', () {
        final cfg = incremental(
          lastSummarizedIndex: 60,
          segments: [
            SummarySegment(id: 'a', startIndex: 0, endIndex: 60),
          ],
        );
        expect(cfg.pendingRanges(60, force: true), isEmpty);
      });

      test('rolling always re-condenses the whole chat when forced', () {
        final cfg = ChatSummary(
          enabled: true,
          interval: 10,
          lastSummarizedIndex: 40,
          segments: [SummarySegment(id: 'a', startIndex: 0, endIndex: 40)],
        );
        expect(cfg.pendingRanges(42, force: false), isEmpty);
        expect(cfg.pendingRanges(42, force: true), [(0, 42)]);
      });
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

    test('pinned round-trips and copyAs carries it', () {
      final c = rich()..pinned = true;
      expect(Conversation.fromJson(c.toJson()).pinned, isTrue);
      expect(c.copyAs(id: 'c3').pinned, isTrue);
      // Default is false and omitted from JSON.
      expect(rich().toJson().containsKey('pinned'), isFalse);
    });
  });
}
