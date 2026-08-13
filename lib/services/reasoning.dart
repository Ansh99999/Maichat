/// Separating a model's thinking from its answer.
///
/// Two kinds of reasoning reach the app:
///
///  * **Native** — the provider returns it in its own field (Anthropic
///    `thinking_delta`, Gemini `thought` parts, `reasoning_content` on the
///    DeepSeek-style OpenAI gateways). [ChatClient] hands that over already
///    separated.
///  * **Inline tags** — the model simply writes its thinking into the reply
///    wrapped in a pair of tags (`<think>` … `</think>` is the de-facto
///    standard). That is what [splitReasoning] pulls apart, so the tags never
///    show up as message text.
library;

/// The tag pair that wraps inline thinking, as configured on a preset. Both
/// halves must be set for parsing to happen at all — a lone tag would carve up
/// the reply at the wrong place.
class ReasoningTags {
  const ReasoningTags({this.start = '', this.end = ''});

  final String start;
  final String end;

  /// The pair most local/open reasoning models emit, and the app's default.
  static const ReasoningTags standard =
      ReasoningTags(start: '<think>', end: '</think>');

  bool get isEnabled => start.isNotEmpty && end.isNotEmpty;
}

/// The result of pulling inline thinking out of a raw reply.
class ReasoningSplit {
  const ReasoningSplit({
    required this.text,
    required this.reasoning,
    this.open = false,
    this.found = false,
  });

  /// The reply with every thinking block (and its tags) removed.
  final String text;

  /// The thinking, blocks joined by a blank line.
  final String reasoning;

  /// Whether a block is still open — the start tag arrived but its end has not.
  /// While true the model is (as far as we can tell) still thinking.
  final bool open;

  /// Whether any thinking was found at all.
  final bool found;
}

/// Splits [raw] into the visible reply and the thinking wrapped in [tags].
///
/// Called on the whole accumulated reply after every delta rather than fed
/// chunk-by-chunk: a tag routinely straddles two SSE chunks, and re-reading the
/// buffer is both simpler and impossible to desynchronize. Replies are a few KB,
/// so the repeated scan costs nothing next to re-rendering the markdown.
///
/// Handles the three shapes seen in the wild:
///
///  * `<think>…</think>answer` — the normal case, including several blocks.
///  * `<think>…` still streaming — everything after the tag is thinking, and
///    [ReasoningSplit.open] is set so the UI can say "Thinking…".
///  * `…</think>answer` with no opening tag — some chat templates pre-fill the
///    opening tag, so the model only ever emits the closing one. Everything
///    before it is thinking.
///
/// A partial tag at the very end of [raw] ("Hello &lt;thi") is held back from
/// the visible text, so a tag is never briefly rendered as message content.
ReasoningSplit splitReasoning(String raw, ReasoningTags tags) {
  if (!tags.isEnabled || raw.isEmpty) {
    return ReasoningSplit(text: raw, reasoning: '');
  }
  final start = tags.start;
  final end = tags.end;

  // The pre-filled-opening-tag case: a closing tag with no opening one anywhere
  // means the thinking began at the top of the reply.
  if (!raw.contains(start)) {
    final at = raw.indexOf(end);
    if (at >= 0) {
      return ReasoningSplit(
        text: raw.substring(at + end.length).trimLeft(),
        reasoning: raw.substring(0, at).trim(),
        found: true,
      );
    }
    return ReasoningSplit(text: _withoutPartial(raw, start), reasoning: '');
  }

  final visible = StringBuffer();
  final blocks = <String>[];
  var open = false;
  var i = 0;
  while (i < raw.length) {
    final s = raw.indexOf(start, i);
    if (s < 0) {
      visible.write(raw.substring(i));
      break;
    }
    visible.write(raw.substring(i, s));
    final from = s + start.length;
    final e = raw.indexOf(end, from);
    if (e < 0) {
      // Still thinking: everything after the opening tag is reasoning so far.
      blocks.add(_withoutPartial(raw.substring(from), end));
      open = true;
      break;
    }
    blocks.add(raw.substring(from, e));
    i = e + end.length;
  }

  final text = open
      ? visible.toString()
      : _withoutPartial(visible.toString(), start);
  return ReasoningSplit(
    text: text.trimLeft(),
    reasoning: blocks.map((b) => b.trim()).where((b) => b.isNotEmpty).join('\n\n'),
    open: open,
    found: true,
  );
}

/// [text] with a trailing partial [tag] removed — "Hello &lt;thi" for a tag of
/// `<think>` gives "Hello ". Keeps a tag that is still arriving from flashing
/// into the message body for one frame.
String _withoutPartial(String text, String tag) {
  final max = tag.length - 1 < text.length ? tag.length - 1 : text.length;
  for (var k = max; k > 0; k--) {
    if (text.endsWith(tag.substring(0, k))) {
      return text.substring(0, text.length - k);
    }
  }
  return text;
}

/// "Thought for 12 seconds" — how long the model spent thinking, phrased for the
/// disclosure header. Sub-second thinking still reads as one second rather than
/// "0 seconds", and anything past a minute switches to minutes.
String describeThinkingTime(int? milliseconds) {
  if (milliseconds == null) return 'Thinking process';
  final seconds = (milliseconds / 1000).round().clamp(1, 1 << 30);
  if (seconds < 60) {
    return 'Thought for $seconds second${seconds == 1 ? '' : 's'}';
  }
  final minutes = seconds ~/ 60;
  final rest = seconds % 60;
  final m = '$minutes minute${minutes == 1 ? '' : 's'}';
  if (rest == 0) return 'Thought for $m';
  return 'Thought for $m $rest second${rest == 1 ? '' : 's'}';
}
