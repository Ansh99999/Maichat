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

      test('coveredIndex tracks the blocks that declare a range', () {
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
        // A hand-written note that declares nothing anchors nothing.
        cfg.segments
            .add(SummarySegment(id: 'note', content: 'a fact', manual: true));
        expect(cfg.coveredIndex(60), 50);
        // One that declares a range does count — that is how a summary pasted in
        // from another app tells the memory what it already covers. Clamped to
        // the messages that exist.
        cfg.segments.add(SummarySegment(
            id: 'm', startIndex: 0, endIndex: 999, manual: true));
        expect(cfg.coveredIndex(60), 60);
      });

      test('the baseline is a floor under coverage', () {
        final cfg = incremental(interval: 30)..baseIndex = 2000;
        expect(cfg.coveredIndex(2000), 2000);
        // A stale block below the line does not drag coverage back down.
        cfg.segments.add(SummarySegment(id: 'old', endIndex: 40));
        expect(cfg.coveredIndex(2000), 2000);
        // A generated block above it wins.
        cfg.segments.add(SummarySegment(id: 'new', endIndex: 2030));
        expect(cfg.coveredIndex(2035), 2030);
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

      test('rolling ignores the baseline — it means the whole chat', () {
        final cfg = ChatSummary(enabled: true, interval: 10)..baseIndex = 2000;
        expect(cfg.pendingRanges(2010, force: true), [(0, 2010)]);
        expect(cfg.pendingRanges(2010, force: false), [(0, 2010)]);
      });
    });

    group('the start line (a chat that arrived with a history)', () {
      ChatSummary imported({int interval = 30, int? baseIndex}) => ChatSummary(
            enabled: true,
            method: SummaryMethod.incremental,
            interval: interval,
            baseIndex: baseIndex,
          );

      test('a summary that already covers the chat has nothing to do', () {
        // The reported bug: 2000 imported messages, a pasted summary covering
        // them, "continue from where it left off" — and 67 windows came back.
        final cfg = imported(baseIndex: 2000);
        expect(cfg.pendingRanges(2000, force: false), isEmpty);
        expect(cfg.pendingRanges(2000, force: true), isEmpty);
      });

      test('it counts forward from the line, not from the first message', () {
        final cfg = imported(baseIndex: 2000);
        expect(cfg.pendingRanges(2035, force: false), [(2000, 2030)]);
        expect(cfg.pendingRanges(2035, force: true), [(2000, 2030), (2030, 2035)]);
      });

      test('a declared manual range moves the line on its own', () {
        final cfg = imported()
          ..segments.add(SummarySegment(
              id: 'pasted', content: 'the story so far', manual: true,
              startIndex: 0, endIndex: 1350));
        // Forced runs work from coverage, which the declaration now sets.
        expect(cfg.pendingRanges(1380, force: true), [(1350, 1380)]);
      });

      test('an automatic run never emits more than one window', () {
        final cfg = imported(baseIndex: 0);
        // Before the fix this walked 0→1980 in 66 windows, in one burst.
        expect(cfg.pendingRanges(2000, force: false), [(0, 30)]);
        // A forced run still offers the whole backlog; the button says so.
        expect(cfg.pendingRanges(2000, force: true).length, 67);
      });

      test('progress past the line wins, and a stale line never rewinds it', () {
        final cfg = imported(baseIndex: 2000)..lastSummarizedIndex = 2060;
        expect(cfg.pendingRanges(2090, force: false), [(2060, 2090)]);
        // …and a line ahead of stale progress still holds.
        final behind = imported(baseIndex: 2000)..lastSummarizedIndex = 40;
        expect(behind.pendingRanges(2030, force: false), [(2000, 2030)]);
      });

      test('fromStart overrides the line without erasing it', () {
        final cfg = imported(baseIndex: 2000);
        final ranges = cfg.pendingRanges(2000, force: true, fromStart: true);
        expect(ranges.first, (0, 30));
        expect(ranges.length, 67);
        expect(cfg.baseIndex, 2000, reason: 'the rebuild must not wipe the mark');
      });

      test('unanchored says whether a line may be stamped', () {
        expect(imported().unanchored, isTrue);
        expect(imported(baseIndex: 0).unanchored, isFalse,
            reason: '0 is a decision, not an absence');
        expect((imported()..lastSummarizedIndex = 30).unanchored, isFalse);
        // A note with no declared range still leaves the summary unanchored.
        final noted = imported()
          ..segments.add(SummarySegment(id: 'n', content: 'x', manual: true));
        expect(noted.unanchored, isTrue);
        final declared = imported()
          ..segments.add(SummarySegment(id: 'd', endIndex: 12, manual: true));
        expect(declared.unanchored, isFalse);
      });

      test('the line round-trips, and 0 stays distinct from unset', () {
        expect(imported().toJson().containsKey('baseIndex'), isFalse);
        expect(ChatSummary.fromJson(imported().toJson()).baseIndex, isNull);
        expect(imported(baseIndex: 0).toJson()['baseIndex'], 0);
        expect(ChatSummary.fromJson(imported(baseIndex: 0).toJson()).baseIndex, 0);
        expect(
            ChatSummary.fromJson(imported(baseIndex: 2000).toJson()).baseIndex,
            2000);
      });

      test('copyWith and clone carry the line, and can clear it', () {
        final cfg = imported(baseIndex: 2000);
        expect(cfg.copyWith(interval: 10).baseIndex, 2000);
        expect(cfg.clone().baseIndex, 2000);
        expect(cfg.copyWith(baseIndex: 40).baseIndex, 40);
        expect(cfg.copyWith(baseIndex: null).baseIndex, isNull);
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
