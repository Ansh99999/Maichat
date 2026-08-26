import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/model_pricing.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/services/usage_ledger.dart';

void main() {
  const price = ModelPrice(model: 'gpt-4o', input: 2.5, output: 10);

  group('recording', () {
    test('an exchange lands in the hour it happened', () {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'gpt-4o',
        usage: const TokenUsage(inputTokens: 1000, outputTokens: 500),
        price: price,
        at: DateTime(2026, 8, 25, 14, 30),
      );
      final totals = ledger.totals('p1');
      expect(totals.inputTokens, 1000);
      expect(totals.outputTokens, 500);
      expect(totals.requests, 1);
    });

    test('cost is worked out from the price at the time', () {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'gpt-4o',
        usage: const TokenUsage(inputTokens: 1000000, outputTokens: 1000000),
        price: price,
        at: DateTime(2026, 8, 25, 14),
      );
      final totals = ledger.totals('p1');
      expect(totals.costIn, closeTo(2.5, 0.0001));
      expect(totals.costOut, closeTo(10, 0.0001));
      expect(totals.totalCost, closeTo(12.5, 0.0001));
    });

    test('an unpriced model records tokens but no cost', () {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'mystery',
        usage: const TokenUsage(inputTokens: 900, outputTokens: 100),
        at: DateTime(2026, 8, 25, 14),
      );
      final totals = ledger.totals('p1');
      expect(totals.totalTokens, 1000);
      expect(totals.totalCost, 0);
    });

    test('an empty usage is not recorded at all', () {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'gpt-4o',
        usage: const TokenUsage(),
        at: DateTime(2026, 8, 25, 14),
      );
      expect(ledger.isEmpty, isTrue);
    });

    test('estimates are counted so a total can admit it is approximate', () {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'local',
        usage: const TokenUsage(
            inputTokens: 100, outputTokens: 50, estimated: true),
        at: DateTime(2026, 8, 25, 14),
      );
      ledger.record(
        providerId: 'p1',
        model: 'local',
        usage: const TokenUsage(inputTokens: 100, outputTokens: 50),
        at: DateTime(2026, 8, 25, 14),
      );
      final totals = ledger.totals('p1');
      expect(totals.requests, 2);
      expect(totals.estimatedRequests, 1);
      expect(totals.hasEstimates, isTrue);
    });
  });

  group('narrowing', () {
    UsageLedger seeded() {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'gpt-4o',
        usage: const TokenUsage(inputTokens: 1000, outputTokens: 1000),
        price: price,
        at: DateTime(2026, 8, 25, 10),
      );
      ledger.record(
        providerId: 'p1',
        model: 'gpt-4o-mini',
        usage: const TokenUsage(inputTokens: 5000, outputTokens: 200),
        at: DateTime(2026, 8, 20, 10),
      );
      ledger.record(
        providerId: 'p2',
        model: 'claude-sonnet-4-5',
        usage: const TokenUsage(inputTokens: 7, outputTokens: 7),
        at: DateTime(2026, 8, 25, 10),
      );
      return ledger;
    }

    test('providers do not bleed into each other', () {
      expect(seeded().totals('p2').totalTokens, 14);
    });

    test('one model can be singled out', () {
      expect(seeded().totals('p1', model: 'gpt-4o').totalTokens, 2000);
    });

    test('a since cutoff drops older buckets', () {
      final totals =
          seeded().totals('p1', since: DateTime(2026, 8, 24));
      expect(totals.totalTokens, 2000);
    });

    test('the priced model outranks the busier one', () {
      final rows = seeded().byModel('p1');
      expect(rows.first.model, 'gpt-4o');
      expect(rows.last.model, 'gpt-4o-mini');
    });
  });

  group('series', () {
    test('returns one slice per step, oldest first, gaps zeroed', () {
      final ledger = UsageLedger();
      final now = DateTime(2026, 8, 25, 12);
      ledger.record(
        providerId: 'p1',
        model: 'm',
        usage: const TokenUsage(inputTokens: 10, outputTokens: 5),
        at: now,
      );
      final series = ledger.series('p1', count: 7, now: now);
      expect(series.length, 7);
      expect(series.last.bucket.totalTokens, 15);
      // Six empty days before today, present rather than omitted.
      expect(series.take(6).every((s) => s.bucket.requests == 0), isTrue);
      for (var i = 1; i < series.length; i++) {
        expect(series[i].start.isAfter(series[i - 1].start), isTrue);
      }
    });

    test('hourly slices split a day the daily view would merge', () {
      final ledger = UsageLedger();
      final now = DateTime(2026, 8, 25, 12);
      ledger.record(
        providerId: 'p1',
        model: 'm',
        usage: const TokenUsage(inputTokens: 10, outputTokens: 0),
        at: DateTime(2026, 8, 25, 9),
      );
      ledger.record(
        providerId: 'p1',
        model: 'm',
        usage: const TokenUsage(inputTokens: 20, outputTokens: 0),
        at: now,
      );
      final hourly = ledger.series(
        'p1',
        granularity: UsageGranularity.hourly,
        count: 6,
        now: now,
      );
      expect(hourly.where((s) => s.bucket.requests > 0).length, 2);
      final daily = ledger.series('p1', count: 3, now: now);
      expect(daily.last.bucket.requests, 2);
    });

    test('a provider with no history still yields a full empty series', () {
      final series = UsageLedger().series('nobody', count: 5);
      expect(series.length, 5);
      expect(series.every((s) => s.bucket.requests == 0), isTrue);
    });
  });

  group('pruning and persistence', () {
    test('hours past the window fold into one bucket a day', () {
      final ledger = UsageLedger();
      final now = DateTime(2026, 8, 25, 12);
      final old = now.subtract(const Duration(days: 30));
      for (final hour in <int>[1, 5, 9]) {
        ledger.record(
          providerId: 'p1',
          model: 'm',
          usage: const TokenUsage(inputTokens: 10, outputTokens: 0),
          at: DateTime(old.year, old.month, old.day, hour),
        );
      }
      expect(ledger.prune(now: now), isTrue);
      // Nothing is lost, it is just no longer sliced by hour.
      final totals = ledger.totals('p1');
      expect(totals.inputTokens, 30);
      expect(totals.requests, 3);
    });

    test('anything past the long window is dropped', () {
      final ledger = UsageLedger();
      final now = DateTime(2026, 8, 25, 12);
      ledger.record(
        providerId: 'p1',
        model: 'm',
        usage: const TokenUsage(inputTokens: 10, outputTokens: 0),
        at: now.subtract(const Duration(days: 900)),
      );
      expect(ledger.prune(now: now), isTrue);
      expect(ledger.isEmpty, isTrue);
    });

    test('recent hours are left alone', () {
      final ledger = UsageLedger();
      final now = DateTime(2026, 8, 25, 12);
      ledger.record(
        providerId: 'p1',
        model: 'm',
        usage: const TokenUsage(inputTokens: 10, outputTokens: 0),
        at: now,
      );
      expect(ledger.prune(now: now), isFalse);
      expect(ledger.totals('p1').requests, 1);
    });

    test('a ledger survives a round trip through storage', () {
      final ledger = UsageLedger();
      ledger.record(
        providerId: 'p1',
        model: 'gpt-4o',
        usage: const TokenUsage(
          inputTokens: 1000,
          outputTokens: 500,
          cachedTokens: 250,
        ),
        price: price,
        at: DateTime(2026, 8, 25, 14),
      );
      final restored = UsageLedger.decode(ledger.encode());
      final totals = restored.totals('p1');
      expect(totals.inputTokens, 1000);
      expect(totals.outputTokens, 500);
      expect(totals.cachedTokens, 250);
      expect(totals.totalCost, closeTo(ledger.totals('p1').totalCost, 1e-9));
    });

    test('a corrupt entry yields an empty ledger, never a throw', () {
      expect(UsageLedger.decode('not json').isEmpty, isTrue);
      expect(UsageLedger.decode('[1,2,3]').isEmpty, isTrue);
      expect(UsageLedger.decode(null).isEmpty, isTrue);
      expect(UsageLedger.decode('').isEmpty, isTrue);
    });

    test('forgetting one provider leaves the others', () {
      final ledger = UsageLedger();
      for (final id in <String>['p1', 'p2']) {
        ledger.record(
          providerId: id,
          model: 'm',
          usage: const TokenUsage(inputTokens: 1, outputTokens: 1),
          at: DateTime(2026, 8, 25, 14),
        );
      }
      expect(ledger.forget('p1'), isTrue);
      expect(ledger.totals('p1').requests, 0);
      expect(ledger.totals('p2').requests, 1);
    });
  });
}
