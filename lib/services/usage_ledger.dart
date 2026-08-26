/// The record of what has been sent and what it cost.
///
/// Keyed provider → model → hour, so the Costs tab can answer "what has this
/// provider cost me", "which model is expensive" and "when do I use it" without
/// storing a row per request. See `models/usage.dart` for why the buckets are
/// hourly.
library;

import 'dart:convert';

import '../models/model_pricing.dart';
import '../models/usage.dart';

/// The in-memory ledger, owned by AppState and persisted as one JSON string.
class UsageLedger {
  UsageLedger([Map<String, Map<String, Map<String, UsageBucket>>>? buckets])
      : _buckets = buckets ?? {};

  /// provider id → model → hour key → bucket.
  final Map<String, Map<String, Map<String, UsageBucket>>> _buckets;

  /// Hourly buckets are kept this long; older ones fold into a single daily
  /// bucket (stored at hour 00) so a long history stays small without losing the
  /// day-level shape.
  static const Duration hourlyWindow = Duration(days: 14);

  /// Daily buckets older than this are dropped. Two years is long enough that
  /// nobody will notice the edge and short enough to bound the file.
  static const Duration dailyWindow = Duration(days: 730);

  bool get isEmpty => _buckets.isEmpty;

  /// Every provider id with recorded usage.
  Iterable<String> get providerIds => _buckets.keys;

  /// Records one exchange, pricing it with [price] as it stands right now.
  ///
  /// The cost is worked out here and stored, rather than derived later from the
  /// current price: a bill that changed retroactively when the user corrected a
  /// rate would be a strange thing to show.
  void record({
    required String providerId,
    required String model,
    required TokenUsage usage,
    ModelPrice? price,
    DateTime? at,
  }) {
    if (usage.isEmpty) return;
    final id = providerId.trim();
    if (id.isEmpty) return;
    final key = model.trim().isEmpty ? '(unnamed)' : model.trim();
    final hour = hourKey(at ?? DateTime.now());

    final cost = price?.costOf(usage.inputTokens, usage.outputTokens);
    final models = _buckets.putIfAbsent(id, () => {});
    final hours = models.putIfAbsent(key, () => {});
    hours[hour] = (hours[hour] ?? const UsageBucket()).plus(
      usage,
      costIn: cost?.input ?? 0,
      costOut: cost?.output ?? 0,
    );
  }

  /// Everything recorded for [providerId], optionally narrowed to one [model]
  /// and to buckets at or after [since].
  UsageBucket totals(String providerId, {String? model, DateTime? since}) {
    var total = const UsageBucket();
    final models = _buckets[providerId];
    if (models == null) return total;
    for (final entry in models.entries) {
      if (model != null && entry.key != model) continue;
      for (final bucket in entry.value.entries) {
        if (since != null) {
          final at = hourFromKey(bucket.key);
          if (at == null || at.isBefore(since)) continue;
        }
        total = total.merge(bucket.value);
      }
    }
    return total;
  }

  /// Per-model totals for [providerId], most expensive first — and where nothing
  /// is priced, largest by tokens, so the list is still ordered by "biggest".
  List<({String model, UsageBucket bucket})> byModel(
    String providerId, {
    DateTime? since,
  }) {
    final models = _buckets[providerId];
    if (models == null) return const [];
    final rows = <({String model, UsageBucket bucket})>[];
    for (final entry in models.entries) {
      var total = const UsageBucket();
      for (final bucket in entry.value.entries) {
        if (since != null) {
          final at = hourFromKey(bucket.key);
          if (at == null || at.isBefore(since)) continue;
        }
        total = total.merge(bucket.value);
      }
      if (total.requests > 0) rows.add((model: entry.key, bucket: total));
    }
    rows.sort((a, b) {
      final byCost = b.bucket.totalCost.compareTo(a.bucket.totalCost);
      if (byCost != 0) return byCost;
      return b.bucket.totalTokens.compareTo(a.bucket.totalTokens);
    });
    return rows;
  }

  /// A time series for the graphs: [count] slices of [granularity] ending with
  /// the one happening now, oldest first. Empty slices are present and zeroed, so
  /// a chart shows the gaps rather than closing them up.
  List<({DateTime start, UsageBucket bucket})> series(
    String providerId, {
    UsageGranularity granularity = UsageGranularity.daily,
    int count = 14,
    String? model,
    DateTime? now,
  }) {
    final anchor = now ?? DateTime.now();
    final slices = <DateTime>[
      for (var i = count - 1; i >= 0; i--) _sliceStart(anchor, granularity, i),
    ];
    final out = <({DateTime start, UsageBucket bucket})>[
      for (final start in slices) (start: start, bucket: const UsageBucket()),
    ];

    final models = _buckets[providerId];
    if (models == null) return out;
    for (final entry in models.entries) {
      if (model != null && entry.key != model) continue;
      for (final bucket in entry.value.entries) {
        final at = hourFromKey(bucket.key);
        if (at == null) continue;
        final index = _sliceIndex(slices, at, granularity);
        if (index == null) continue;
        out[index] =
            (start: out[index].start, bucket: out[index].bucket.merge(bucket.value));
      }
    }
    return out;
  }

  /// The start of the slice [back] slices before the one containing [anchor].
  static DateTime _sliceStart(
    DateTime anchor,
    UsageGranularity granularity,
    int back,
  ) {
    final t = anchor.toLocal();
    return switch (granularity) {
      UsageGranularity.hourly =>
        DateTime(t.year, t.month, t.day, t.hour).subtract(Duration(hours: back)),
      UsageGranularity.daily =>
        DateTime(t.year, t.month, t.day).subtract(Duration(days: back)),
      // Weeks start on Monday, which is what a "this week" total means to most
      // people and what ISO says.
      UsageGranularity.weekly => DateTime(t.year, t.month, t.day)
          .subtract(Duration(days: t.weekday - 1 + back * 7)),
      UsageGranularity.monthly => DateTime(t.year, t.month - back, 1),
    };
  }

  /// Which slice [at] belongs to, or null when it is outside the window.
  static int? _sliceIndex(
    List<DateTime> slices,
    DateTime at,
    UsageGranularity granularity,
  ) {
    for (var i = slices.length - 1; i >= 0; i--) {
      if (!at.isBefore(slices[i])) {
        // The newest slice has no upper bound; the rest end where the next begins.
        if (i == slices.length - 1) return i;
        return at.isBefore(slices[i + 1]) ? i : null;
      }
    }
    return null;
  }

  /// Folds hours older than [hourlyWindow] into one bucket per day and drops
  /// anything past [dailyWindow]. Returns true when something changed, so the
  /// caller only persists if there is a reason to.
  bool prune({DateTime? now}) {
    final anchor = (now ?? DateTime.now()).toLocal();
    final hourlyCutoff = anchor.subtract(hourlyWindow);
    final dailyCutoff = anchor.subtract(dailyWindow);
    var changed = false;

    for (final models in _buckets.values) {
      for (final hours in models.values) {
        final folded = <String, UsageBucket>{};
        for (final entry in hours.entries) {
          final at = hourFromKey(entry.key);
          if (at == null) {
            // A key that will not parse cannot be placed in time; drop it rather
            // than keep something the graphs would ignore anyway.
            changed = true;
            continue;
          }
          if (at.isBefore(dailyCutoff)) {
            changed = true;
            continue;
          }
          if (at.isBefore(hourlyCutoff)) {
            final dayKey = hourKey(DateTime(at.year, at.month, at.day));
            if (dayKey != entry.key) changed = true;
            folded[dayKey] =
                (folded[dayKey] ?? const UsageBucket()).merge(entry.value);
            continue;
          }
          folded[entry.key] =
              (folded[entry.key] ?? const UsageBucket()).merge(entry.value);
        }
        if (changed) {
          hours
            ..clear()
            ..addAll(folded);
        }
      }
      models.removeWhere((_, hours) => hours.isEmpty);
    }
    _buckets.removeWhere((_, models) => models.isEmpty);
    return changed;
  }

  /// Forgets everything recorded for [providerId].
  bool forget(String providerId) => _buckets.remove(providerId) != null;

  /// Forgets everything, for the storage screen's "clear" action.
  void clear() => _buckets.clear();

  String encode() => jsonEncode(<String, dynamic>{
        for (final provider in _buckets.entries)
          provider.key: <String, dynamic>{
            for (final model in provider.value.entries)
              model.key: <String, dynamic>{
                for (final hour in model.value.entries)
                  hour.key: hour.value.toJson(),
              },
          },
      });

  /// Reads a stored ledger. Anything malformed is skipped rather than thrown:
  /// a corrupt usage entry must not be able to stop the app from starting, and
  /// losing a cost history is a far smaller failure than losing the session.
  factory UsageLedger.decode(String? source) {
    if (source == null || source.trim().isEmpty) return UsageLedger();
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic>) return UsageLedger();
      final buckets = <String, Map<String, Map<String, UsageBucket>>>{};
      for (final provider in json.entries) {
        final models = provider.value;
        if (models is! Map<String, dynamic>) continue;
        final byModel = <String, Map<String, UsageBucket>>{};
        for (final model in models.entries) {
          final hours = model.value;
          if (hours is! Map<String, dynamic>) continue;
          final byHour = <String, UsageBucket>{};
          for (final hour in hours.entries) {
            final bucket = hour.value;
            if (bucket is! Map<String, dynamic>) continue;
            byHour[hour.key] = UsageBucket.fromJson(bucket);
          }
          if (byHour.isNotEmpty) byModel[model.key] = byHour;
        }
        if (byModel.isNotEmpty) buckets[provider.key] = byModel;
      }
      return UsageLedger(buckets);
    } catch (_) {
      return UsageLedger();
    }
  }
}
