import 'package:tiktoken_tokenizer_gpt4o_o1/tiktoken_tokenizer_gpt4o_o1.dart';

import 'token_estimator.dart';

/// Which tokenizer counts context tokens app-wide. OpenAI and Custom use a real
/// BPE tokenizer (exact). Anthropic has no offline tokenizer for Claude 3+, so
/// it uses the o200k BPE as a close local proxy (an exact figure is fetched from
/// the count-tokens API in the message Info view when a key is present).
enum TokenizerKind {
  openai('OpenAI (GPT)'),
  anthropic('Anthropic (Claude)'),
  custom('Custom');

  const TokenizerKind(this.label);

  final String label;

  static TokenizerKind byName(String? name) {
    for (final k in values) {
      if (k.name == name) return k;
    }
    return TokenizerKind.openai;
  }
}

/// A BPE encoding bundled by the tokenizer package.
enum BpeEncoding {
  cl100k('cl100k_base', 'GPT-4, GPT-3.5'),
  o200k('o200k_base', 'GPT-4o, o1/o3/o4');

  const BpeEncoding(this.id, this.models);

  /// The tiktoken encoding name.
  final String id;

  /// A short hint of which models use it, for the settings dropdown.
  final String models;

  String get label => '$id ($models)';

  TiktokenEncodingType get type => switch (this) {
        BpeEncoding.cl100k => TiktokenEncodingType.cl100k_base,
        BpeEncoding.o200k => TiktokenEncodingType.o200k_base,
      };

  static BpeEncoding byName(String? name) {
    for (final e in values) {
      if (e.name == name) return e;
    }
    return BpeEncoding.o200k;
  }
}

/// The app-wide tokenizer choice. For [TokenizerKind.custom], [customEncoding]
/// names the BPE to use; the other kinds resolve their encoding automatically.
class TokenizerConfig {
  const TokenizerConfig({
    this.kind = TokenizerKind.openai,
    this.customEncoding = BpeEncoding.o200k,
  });

  final TokenizerKind kind;
  final BpeEncoding customEncoding;

  TokenizerConfig copyWith({TokenizerKind? kind, BpeEncoding? customEncoding}) =>
      TokenizerConfig(
        kind: kind ?? this.kind,
        customEncoding: customEncoding ?? this.customEncoding,
      );

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'customEncoding': customEncoding.name};

  factory TokenizerConfig.fromJson(Map<String, dynamic> json) => TokenizerConfig(
        kind: TokenizerKind.byName(json['kind'] as String?),
        customEncoding: BpeEncoding.byName(json['customEncoding'] as String?),
      );

  @override
  bool operator ==(Object other) =>
      other is TokenizerConfig &&
      other.kind == kind &&
      other.customEncoding == customEncoding;

  @override
  int get hashCode => Object.hash(kind, customEncoding);
}

/// The BPE encoding an OpenAI model uses: o200k for the GPT-4o / o-series / 4.1 /
/// 5 families, cl100k for the older GPT-4 / GPT-3.5 line.
BpeEncoding encodingForOpenAiModel(String model) {
  final m = model.toLowerCase();
  if (m.startsWith('o1') ||
      m.startsWith('o3') ||
      m.startsWith('o4') ||
      m.contains('4o') ||
      m.contains('gpt-4.1') ||
      m.contains('gpt-5') ||
      m.contains('chatgpt')) {
    return BpeEncoding.o200k;
  }
  return BpeEncoding.cl100k;
}

/// The app's [TokenEstimator], backed by a real BPE tokenizer. It reads the
/// current [TokenizerConfig] and active model through live closures, so a single
/// instance handed to the prompt builder always reflects the latest settings —
/// no rebuild needed. Encoders are cached per encoding (the first use builds the
/// vocab). Any failure falls back to the heuristic so counting never crashes a
/// send.
class AppTokenizer implements TokenEstimator {
  AppTokenizer({required this.config, required this.model});

  final TokenizerConfig Function() config;
  final String Function() model;

  static const HeuristicTokenEstimator _fallback = HeuristicTokenEstimator();
  static final Map<BpeEncoding, TiktokenEncoder> _cache = {};

  BpeEncoding activeEncoding() {
    final c = config();
    return switch (c.kind) {
      TokenizerKind.openai => encodingForOpenAiModel(model()),
      TokenizerKind.anthropic => BpeEncoding.o200k,
      TokenizerKind.custom => c.customEncoding,
    };
  }

  /// Whether the current configuration yields approximate counts (Anthropic has
  /// no exact offline tokenizer) — for UI labeling.
  bool get isApproximate => config().kind == TokenizerKind.anthropic;

  TiktokenEncoder _encoder(BpeEncoding e) =>
      _cache.putIfAbsent(e, () => Tiktoken.getEncoder(e.type));

  @override
  int estimate(String text) {
    if (text.isEmpty) return 0;
    try {
      // encodeOrdinary treats any "<|special|>" text as ordinary, so counting
      // arbitrary user/model content never throws.
      return _encoder(activeEncoding()).encodeOrdinary(text).length;
    } catch (_) {
      return _fallback.estimate(text);
    }
  }
}
