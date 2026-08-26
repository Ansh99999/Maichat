/// What one exchange cost, and how those add up over time.
///
/// The ledger stores hourly rollup buckets rather than one row per request.
/// A row per request would grow without bound inside a preferences entry that is
/// rewritten whole on every save — the mistake this codebase has already paid
/// for twice. Hourly buckets are bounded (24 × days × models), still fine enough
/// to draw an hourly graph, and fold cleanly into daily/weekly/monthly.
///
/// Cost is snapshotted into the bucket when the reply lands, so editing a price
/// later does not silently rewrite history.
library;

/// The token counts for a single exchange, as the host reported them.
class TokenUsage {
  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.reasoningTokens = 0,
    this.cachedTokens = 0,
    this.estimated = false,
  });

  final int inputTokens;
  final int outputTokens;

  /// Thinking tokens, where the host breaks them out. Already counted inside
  /// [outputTokens] by every API the app speaks — kept only for display.
  final int reasoningTokens;

  /// Prompt tokens served from the host's cache, where reported. Also already
  /// inside [inputTokens].
  final int cachedTokens;

  /// True when the host reported nothing and these came from the app's own
  /// tokenizer. The UI must say so rather than presenting a guess as a bill.
  final bool estimated;

  bool get isEmpty => inputTokens == 0 && outputTokens == 0;

  int get totalTokens => inputTokens + outputTokens;

  TokenUsage copyWith({
    int? inputTokens,
    int? outputTokens,
    int? reasoningTokens,
    int? cachedTokens,
    bool? estimated,
  }) =>
      TokenUsage(
        inputTokens: inputTokens ?? this.inputTokens,
        outputTokens: outputTokens ?? this.outputTokens,
        reasoningTokens: reasoningTokens ?? this.reasoningTokens,
        cachedTokens: cachedTokens ?? this.cachedTokens,
        estimated: estimated ?? this.estimated,
      );

  @override
  String toString() => 'TokenUsage(in: $inputTokens, out: $outputTokens'
      '${estimated ? ', estimated' : ''})';
}

/// One hour's worth of traffic for one model on one provider.
class UsageBucket {
  const UsageBucket({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cachedTokens = 0,
    this.costIn = 0,
    this.costOut = 0,
    this.requests = 0,
    this.estimatedRequests = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cachedTokens;

  /// Cost as it was priced at the time, split so the Costs tab can show the
  /// input and output halves separately.
  final double costIn;
  final double costOut;

  final int requests;

  /// How many of [requests] had their tokens estimated rather than reported.
  final int estimatedRequests;

  int get totalTokens => inputTokens + outputTokens;

  double get totalCost => costIn + costOut;

  /// True when any request in this bucket was estimated, which taints the total.
  bool get hasEstimates => estimatedRequests > 0;

  /// This bucket with one more exchange folded in.
  UsageBucket plus(
    TokenUsage usage, {
    double costIn = 0,
    double costOut = 0,
  }) =>
      UsageBucket(
        inputTokens: inputTokens + usage.inputTokens,
        outputTokens: outputTokens + usage.outputTokens,
        cachedTokens: cachedTokens + usage.cachedTokens,
        costIn: this.costIn + costIn,
        costOut: this.costOut + costOut,
        requests: requests + 1,
        estimatedRequests: estimatedRequests + (usage.estimated ? 1 : 0),
      );

  /// Two buckets added together, for rolling hours up into days and totals.
  UsageBucket merge(UsageBucket other) => UsageBucket(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cachedTokens: cachedTokens + other.cachedTokens,
        costIn: costIn + other.costIn,
        costOut: costOut + other.costOut,
        requests: requests + other.requests,
        estimatedRequests: estimatedRequests + other.estimatedRequests,
      );

  /// Compact keys: these are written once per reply, so the shorter the better.
  Map<String, dynamic> toJson() => {
        'i': inputTokens,
        'o': outputTokens,
        if (cachedTokens > 0) 'c': cachedTokens,
        if (costIn != 0) 'ci': costIn,
        if (costOut != 0) 'co': costOut,
        'n': requests,
        if (estimatedRequests > 0) 'e': estimatedRequests,
      };

  factory UsageBucket.fromJson(Map<String, dynamic> json) => UsageBucket(
        inputTokens: (json['i'] as num?)?.toInt() ?? 0,
        outputTokens: (json['o'] as num?)?.toInt() ?? 0,
        cachedTokens: (json['c'] as num?)?.toInt() ?? 0,
        costIn: (json['ci'] as num?)?.toDouble() ?? 0,
        costOut: (json['co'] as num?)?.toDouble() ?? 0,
        requests: (json['n'] as num?)?.toInt() ?? 0,
        estimatedRequests: (json['e'] as num?)?.toInt() ?? 0,
      );
}

/// How finely a usage series is sliced for the graphs.
enum UsageGranularity {
  hourly('Hourly'),
  daily('Daily'),
  weekly('Weekly'),
  monthly('Monthly');

  const UsageGranularity(this.label);

  final String label;
}

/// The storage key for the hour [at] falls in: `2026-08-25T14`, in local time
/// so a user's "today" matches the day they lived through.
String hourKey(DateTime at) {
  final t = at.toLocal();
  final month = t.month.toString().padLeft(2, '0');
  final day = t.day.toString().padLeft(2, '0');
  final hour = t.hour.toString().padLeft(2, '0');
  return '${t.year}-$month-${day}T$hour';
}

/// The hour a stored key names, or null when the key is malformed — a corrupt
/// entry should be skipped, never crash the Costs tab.
DateTime? hourFromKey(String key) {
  final parts = key.split('T');
  if (parts.length != 2) return null;
  final date = parts[0].split('-');
  if (date.length != 3) return null;
  final year = int.tryParse(date[0]);
  final month = int.tryParse(date[1]);
  final day = int.tryParse(date[2]);
  final hour = int.tryParse(parts[1]);
  if (year == null || month == null || day == null || hour == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour < 0 || hour > 23) {
    return null;
  }
  return DateTime(year, month, day, hour);
}
