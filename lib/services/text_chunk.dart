/// Splits text into overlapping chunks for embedding, roughly the way
/// SillyTavern's Data Bank does: aim for [size] characters, prefer to break at a
/// sentence or paragraph boundary near the end of the window, and let adjacent
/// chunks share [overlapPercent] of their length so a fact split across a
/// boundary is still recallable from either side.
///
/// Character-based (not token-based) on purpose: it needs no tokenizer, is
/// deterministic, and "about N characters" is precise enough for retrieval.
List<String> chunkText(
  String text, {
  int size = 400,
  int overlapPercent = 0,
}) {
  final clean = text.trim();
  if (clean.isEmpty) return const <String>[];
  if (size <= 0 || clean.length <= size) return <String>[clean];

  final overlap = (size * overlapPercent / 100).round().clamp(0, size ~/ 2);
  final step = (size - overlap).clamp(1, size);

  final chunks = <String>[];
  var start = 0;
  while (start < clean.length) {
    var end = (start + size).clamp(0, clean.length);
    // If we're not at the very end, back off to the nearest boundary so a chunk
    // doesn't stop mid-sentence. Look only inside the back part of the window.
    if (end < clean.length) {
      final boundary = _lastBoundary(clean, start + step ~/ 2, end);
      if (boundary > start) end = boundary;
    }
    final piece = clean.substring(start, end).trim();
    if (piece.isNotEmpty) chunks.add(piece);
    if (end >= clean.length) break;
    // Advance from the boundary we actually used, minus the overlap.
    final next = (end - overlap).clamp(start + 1, clean.length);
    start = next;
  }
  return chunks;
}

/// The index just past the last sentence/paragraph terminator in `[from, to)`,
/// or `to` when there is none — so a chunk ends after a full stop rather than in
/// the middle of a word.
int _lastBoundary(String text, int from, int to) {
  const terminators = {'.', '!', '?', '\n'};
  for (var i = to - 1; i > from; i--) {
    if (terminators.contains(text[i])) {
      // Include the terminator and any following whitespace.
      var end = i + 1;
      while (end < to && (text[end] == ' ' || text[end] == '\n')) {
        end++;
      }
      return end;
    }
  }
  return to;
}
