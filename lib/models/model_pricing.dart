/// How a model's price is quoted, and what one costs.
///
/// Two shapes cover every host the app talks to: a flat charge per request
/// (what image and some hosted endpoints do) and a rate per million tokens
/// (what every text LLM does). Prices live on the provider rather than in an
/// app-wide table because the same model id costs different amounts at
/// different hosts — `llama-3.1-70b` on one gateway is not the other's price.
library;

import '../services/model_context.dart';

/// Whether a price is charged per call or per million tokens.
enum PriceMode {
  perRequest('Per request'),
  perMillionTokens('Per 1M tokens');

  const PriceMode(this.label);

  final String label;

  static PriceMode byName(String? name) {
    for (final mode in values) {
      if (mode.name == name) return mode;
    }
    return PriceMode.perMillionTokens;
  }
}

/// One priced model. [input] and [output] are rates per million tokens under
/// [PriceMode.perMillionTokens]; under [PriceMode.perRequest] only [input] is
/// used, as the flat per-call charge.
class ModelPrice {
  const ModelPrice({
    required this.model,
    this.mode = PriceMode.perMillionTokens,
    this.input = 0,
    this.output = 0,
  });

  /// The model id this price applies to, matched by [priceFor].
  final String model;

  final PriceMode mode;

  /// Input (prompt) rate, or the flat per-request charge.
  final double input;

  /// Output (completion) rate. Unused for [PriceMode.perRequest].
  final double output;

  /// A price with nothing filled in is not worth charging against — the UI
  /// shows "—" rather than a confident $0.00.
  bool get isSet => input > 0 || output > 0;

  ModelPrice copyWith({
    String? model,
    PriceMode? mode,
    double? input,
    double? output,
  }) =>
      ModelPrice(
        model: model ?? this.model,
        mode: mode ?? this.mode,
        input: input ?? this.input,
        output: output ?? this.output,
      );

  /// What [inputTokens]/[outputTokens] cost under this price. Returns a pair so
  /// the two halves can be shown separately, which the Costs tab does.
  ({double input, double output}) costOf(int inputTokens, int outputTokens) =>
      switch (mode) {
        PriceMode.perRequest => (input: input, output: 0),
        PriceMode.perMillionTokens => (
            input: inputTokens / 1000000 * input,
            output: outputTokens / 1000000 * output,
          ),
      };

  Map<String, dynamic> toJson() => {
        'model': model,
        'mode': mode.name,
        'input': input,
        'output': output,
      };

  factory ModelPrice.fromJson(Map<String, dynamic> json) => ModelPrice(
        model: json['model'] as String? ?? '',
        mode: PriceMode.byName(json['mode'] as String?),
        input: (json['input'] as num?)?.toDouble() ?? 0,
        output: (json['output'] as num?)?.toDouble() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is ModelPrice &&
      other.model == model &&
      other.mode == mode &&
      other.input == input &&
      other.output == output;

  @override
  int get hashCode => Object.hash(model, mode, input, output);
}

/// The price in [prices] that applies to [model], or null when none does.
///
/// Matching follows the same rule as the context-window table so the two cannot
/// disagree: exact match on the normalised id first, then the longest substring
/// match, so `gpt-4o-mini-2024-07-18` resolves through a `gpt-4o-mini` entry and
/// never through `gpt-4`. A null result means "unpriced" — callers must show
/// that as unknown rather than as free.
ModelPrice? priceFor(List<ModelPrice> prices, String model) {
  final id = normaliseModelId(model);
  if (id.isEmpty) return null;

  ModelPrice? best;
  var bestLength = -1;
  for (final price in prices) {
    final key = normaliseModelId(price.model);
    if (key.isEmpty) continue;
    if (key == id) return price;
    if (!id.contains(key)) continue;
    if (key.length > bestLength) {
      best = price;
      bestLength = key.length;
    }
  }
  return best;
}
