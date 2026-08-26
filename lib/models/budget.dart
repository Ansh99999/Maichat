/// A spending ceiling the user sets on a provider, and how to judge it.
///
/// A budget answers "stop me before this gets expensive" in whichever unit the
/// user thinks in: money, tokens, or plain request count. It can cover the whole
/// provider or a single model on it, over a rolling window or all time.
///
/// [Budget.block] is the difference between a warning and a wall. A blocking
/// budget refuses the send; a non-blocking one only colours the Costs tab.
/// Blocking is off by default — silently refusing to answer is a surprising
/// thing for a chat app to do unless it was explicitly asked for.
library;

/// What a budget counts.
enum BudgetMetric {
  cost('Cost', 'Money spent'),
  tokens('Tokens', 'Input plus output tokens'),
  requests('Requests', 'Number of replies');

  const BudgetMetric(this.label, this.blurb);

  final String label;
  final String blurb;

  static BudgetMetric byName(String? name) {
    for (final metric in values) {
      if (metric.name == name) return metric;
    }
    return BudgetMetric.cost;
  }
}

/// The window a budget resets over.
enum BudgetPeriod {
  daily('Daily'),
  weekly('Weekly'),
  monthly('Monthly'),
  total('All time');

  const BudgetPeriod(this.label);

  final String label;

  static BudgetPeriod byName(String? name) {
    for (final period in values) {
      if (period.name == name) return period;
    }
    return BudgetPeriod.monthly;
  }
}

/// One ceiling: how much of what, over how long, and whether to enforce it.
class Budget {
  const Budget({
    required this.id,
    this.model = '',
    this.metric = BudgetMetric.cost,
    this.period = BudgetPeriod.monthly,
    this.limit = 0,
    this.block = false,
  });

  final String id;

  /// The model this applies to, or empty for the provider as a whole.
  final String model;

  final BudgetMetric metric;
  final BudgetPeriod period;

  /// The ceiling, in the unit [metric] implies. Zero means "not set yet" and is
  /// never enforced — a limit of nothing would block every send.
  final double limit;

  /// Refuse the send once [limit] is reached, rather than only warning.
  final bool block;

  bool get isSet => limit > 0;

  /// Covers every model on the provider rather than one.
  bool get isProviderWide => model.trim().isEmpty;

  /// How far along [spent] is, clamped to 0..1 for a progress bar. Returns null
  /// when there is no limit to be a fraction of.
  double? fractionOf(double spent) {
    if (!isSet) return null;
    final ratio = spent / limit;
    return ratio.isFinite ? ratio.clamp(0.0, 1.0) : null;
  }

  /// True once [spent] has reached the ceiling.
  bool isExceededBy(double spent) => isSet && spent >= limit;

  Budget copyWith({
    String? model,
    BudgetMetric? metric,
    BudgetPeriod? period,
    double? limit,
    bool? block,
  }) =>
      Budget(
        id: id,
        model: model ?? this.model,
        metric: metric ?? this.metric,
        period: period ?? this.period,
        limit: limit ?? this.limit,
        block: block ?? this.block,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'model': model,
        'metric': metric.name,
        'period': period.name,
        'limit': limit,
        'block': block,
      };

  factory Budget.fromJson(Map<String, dynamic> json) => Budget(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        model: json['model'] as String? ?? '',
        metric: BudgetMetric.byName(json['metric'] as String?),
        period: BudgetPeriod.byName(json['period'] as String?),
        limit: (json['limit'] as num?)?.toDouble() ?? 0,
        block: json['block'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is Budget &&
      other.id == id &&
      other.model == model &&
      other.metric == metric &&
      other.period == period &&
      other.limit == limit &&
      other.block == block;

  @override
  int get hashCode => Object.hash(id, model, metric, period, limit, block);
}
