/// Rough token accounting for context-budget decisions.
///
/// A real BPE tokenizer would be exact but heavy to bundle; for budgeting (where
/// we only need a stable, slightly-conservative estimate to decide how much chat
/// history fits) a heuristic is enough. Kept behind an interface so a precise
/// tokenizer can be dropped in later without touching callers.
abstract interface class TokenEstimator {
  int estimate(String text);
}

/// Blends a character-based and a word-based estimate, which together track real
/// GPT/Claude tokenization better than either alone across prose, code and CJK.
/// Leans slightly high so budgeting never overshoots the model's real limit.
class HeuristicTokenEstimator implements TokenEstimator {
  const HeuristicTokenEstimator();

  @override
  int estimate(String text) {
    if (text.isEmpty) return 0;
    final chars = text.runes.length;
    final words = text.trim().isEmpty
        ? 0
        : text.trim().split(RegExp(r'\s+')).length;
    // ~4 chars/token for English prose; ~0.75 tokens/word. Average the two and
    // round up, with a floor of 1 for any non-empty string.
    final byChars = chars / 4.0;
    final byWords = words / 0.75;
    final blended = (byChars + byWords) / 2.0;
    return blended.ceil().clamp(1, 1 << 30);
  }
}
