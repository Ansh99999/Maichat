/// Per-chat rolling summary ("running memory"). A [ChatSummary] holds both the
/// configuration for how a chat is condensed and the resulting text, stored on
/// the [Conversation] and injected back into the prompt as {{summary}}.
library;

/// How a chat is condensed each interval.
enum SummaryMethod {
  /// Re-condense the whole chat (messages `[0..now]`) into a single segment that
  /// replaces the previous one. More accurate, more expensive per run.
  rolling,

  /// Condense only the newest window (`[lastSummarizedIndex..now]`) and append it
  /// as a new segment; segments pile up over the life of the chat. Cheaper.
  incremental;

  static SummaryMethod byName(String? name) =>
      name == 'incremental' ? SummaryMethod.incremental : SummaryMethod.rolling;
}

/// The default instruction handed to the model when the user has not written a
/// custom summarizer prompt. Kept deliberately plain and third-person.
const String kDefaultSummaryPrompt =
    'You are a summarisation assistant. Condense the conversation below into a '
    'concise, factual summary that preserves the important events, decisions, '
    'relationships and details a participant would need to remember. Write in '
    'the third person as running prose. Do not add commentary, headings, or '
    'anything that is not in the conversation.';

/// One condensed chunk. In [SummaryMethod.rolling] a chat has a single segment;
/// in [SummaryMethod.incremental] they accumulate, oldest first.
class SummarySegment {
  SummarySegment({
    required this.id,
    this.title = '',
    this.content = '',
    this.startIndex = 0,
    this.endIndex = 0,
    DateTime? createdAt,
    this.tokens = 0,
    this.manual = false,
    this.collapsed = false,
  }) : createdAt = createdAt ?? DateTime.now();

  final String id;
  String title;
  String content;

  /// The message range this segment covers, as indices into
  /// `Conversation.messages` (start inclusive, end exclusive). Advisory — indices
  /// shift if earlier turns are deleted, so the stored [content] is the source of
  /// truth, not the range.
  int startIndex;
  int endIndex;
  DateTime createdAt;

  /// Cached token count of [content] under the app tokenizer, for the UI readout.
  int tokens;

  /// Whether the user authored this block by hand (vs. generated). Manual blocks
  /// are never wiped by a re-summarise — they are the user's own memory.
  bool manual;

  /// Whether this block is shown collapsed (body hidden) in the memory editor.
  /// A view preference, not content — persisted so the folded/unfolded layout
  /// the user left the page in comes back the same way.
  bool collapsed;

  SummarySegment copyWith({
    String? title,
    String? content,
    int? startIndex,
    int? endIndex,
    int? tokens,
    bool? manual,
    bool? collapsed,
  }) =>
      SummarySegment(
        id: id,
        title: title ?? this.title,
        content: content ?? this.content,
        startIndex: startIndex ?? this.startIndex,
        endIndex: endIndex ?? this.endIndex,
        createdAt: createdAt,
        tokens: tokens ?? this.tokens,
        manual: manual ?? this.manual,
        collapsed: collapsed ?? this.collapsed,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        if (title.isNotEmpty) 'title': title,
        'content': content,
        'startIndex': startIndex,
        'endIndex': endIndex,
        'createdAt': createdAt.toIso8601String(),
        if (tokens > 0) 'tokens': tokens,
        if (manual) 'manual': true,
        if (collapsed) 'collapsed': true,
      };

  factory SummarySegment.fromJson(Map<String, dynamic> json) => SummarySegment(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: json['title'] as String? ?? '',
        content: json['content'] as String? ?? '',
        startIndex: (json['startIndex'] as num?)?.toInt() ?? 0,
        endIndex: (json['endIndex'] as num?)?.toInt() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        tokens: (json['tokens'] as num?)?.toInt() ?? 0,
        manual: json['manual'] as bool? ?? false,
        collapsed: json['collapsed'] as bool? ?? false,
      );
}
/// A chat's summary configuration and accumulated text. Lives on the
/// [Conversation] (embedded, so it rides native chat export for free and is
/// dropped from ST/Agnai exports by construction). Null on a chat until the user
/// first enables the feature.
class ChatSummary {
  ChatSummary({
    this.enabled = false,
    this.interval = 20,
    this.providerId,
    this.model,
    this.budget,
    this.method = SummaryMethod.rolling,
    this.notify = false,
    this.useCustomPrompt = false,
    this.prompt,
    this.title = '',
    List<SummarySegment>? segments,
    this.lastSummarizedIndex = 0,
  }) : segments = segments ?? <SummarySegment>[];

  /// Whether summarisation is active for this chat.
  bool enabled;

  /// Summarise every N messages.
  int interval;

  /// Provider/model to summarise with; null means "same as the chat's current".
  String? providerId;
  String? model;

  /// Max tokens for the summary request; null falls back to `Preset.summaryBudget`.
  int? budget;

  SummaryMethod method;

  /// Post an in-app notice when a summary is made (otherwise update quietly).
  bool notify;

  /// Whether [prompt] overrides [kDefaultSummaryPrompt].
  bool useCustomPrompt;
  String? prompt;

  /// A display name for this summary (shown in the Library); defaults to the
  /// chat's title when empty.
  String title;

  final List<SummarySegment> segments;

  /// The exclusive message index up to which the chat has been summarised.
  int lastSummarizedIndex;

  /// The instruction actually sent to the model.
  String get effectivePrompt => useCustomPrompt && (prompt?.trim().isNotEmpty ?? false)
      ? prompt!.trim()
      : kDefaultSummaryPrompt;

  /// All segments joined into the single blob injected as {{summary}}.
  String get combinedText {
    final parts = <String>[];
    for (final s in segments) {
      final body = s.content.trim();
      if (body.isEmpty) continue;
      parts.add(s.title.trim().isEmpty ? body : '## ${s.title.trim()}\n$body');
    }
    return parts.join('\n\n');
  }

  bool get hasText => combinedText.isNotEmpty;

  int get totalTokens {
    var sum = 0;
    for (final s in segments) {
      sum += s.tokens;
    }
    return sum;
  }

  /// The highest message index actually covered by a *generated* segment (0 if
  /// none). Unlike [lastSummarizedIndex] — a running high-water mark that a run
  /// advances — this is recomputed from the segments that still exist, so
  /// deleting a block un-covers its range. It is what a manual "Summarise now"
  /// works from, which is why deleting a memory block and re-summarising refills
  /// exactly that gap.
  int coveredIndex(int count) {
    var covered = 0;
    for (final s in segments) {
      if (s.manual) continue;
      if (s.endIndex > covered) covered = s.endIndex;
    }
    return covered.clamp(0, count);
  }

  /// The message ranges a summary run should condense, as `[start, end)` pairs.
  ///
  /// A [force]d run (the manual "Summarise now" button) ignores the interval
  /// threshold and works from [coveredIndex] rather than [lastSummarizedIndex],
  /// so it always picks up whatever is not already in the memory — even a single
  /// new message, or the gap left by a deleted block. An automatic run only
  /// fires once a full [interval] of new messages has accrued.
  List<(int, int)> pendingRanges(int count, {required bool force}) {
    if (interval <= 0 || count <= 0) return const <(int, int)>[];
    if (method == SummaryMethod.rolling) {
      if (!force && count - lastSummarizedIndex < interval) {
        return const <(int, int)>[];
      }
      return <(int, int)>[(0, count)];
    }
    final out = <(int, int)>[];
    var s = (force ? coveredIndex(count) : lastSummarizedIndex).clamp(0, count);
    while (count - s >= interval) {
      out.add((s, s + interval));
      s += interval;
    }
    if (force && s < count) out.add((s, count));
    return out;
  }

  ChatSummary copyWith({
    bool? enabled,
    int? interval,
    Object? providerId = _unset,
    Object? model = _unset,
    Object? budget = _unset,
    SummaryMethod? method,
    bool? notify,
    bool? useCustomPrompt,
    Object? prompt = _unset,
    String? title,
    List<SummarySegment>? segments,
    int? lastSummarizedIndex,
  }) =>
      ChatSummary(
        enabled: enabled ?? this.enabled,
        interval: interval ?? this.interval,
        providerId:
            identical(providerId, _unset) ? this.providerId : providerId as String?,
        model: identical(model, _unset) ? this.model : model as String?,
        budget: identical(budget, _unset) ? this.budget : budget as int?,
        method: method ?? this.method,
        notify: notify ?? this.notify,
        useCustomPrompt: useCustomPrompt ?? this.useCustomPrompt,
        prompt: identical(prompt, _unset) ? this.prompt : prompt as String?,
        title: title ?? this.title,
        segments: segments ??
            this.segments.map((s) => s.copyWith()).toList(),
        lastSummarizedIndex: lastSummarizedIndex ?? this.lastSummarizedIndex,
      );

  static const Object _unset = Object();

  /// A deep clone — used by `Conversation.copyAs` on fork/renumber.
  ChatSummary clone() => copyWith();

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'interval': interval,
        if (providerId != null) 'providerId': providerId,
        if (model != null) 'model': model,
        if (budget != null) 'budget': budget,
        'method': method.name,
        if (notify) 'notify': true,
        if (useCustomPrompt) 'useCustomPrompt': true,
        if (prompt != null && prompt!.isNotEmpty) 'prompt': prompt,
        if (title.isNotEmpty) 'title': title,
        'segments': segments.map((s) => s.toJson()).toList(),
        'lastSummarizedIndex': lastSummarizedIndex,
      };

  factory ChatSummary.fromJson(Map<String, dynamic> json) => ChatSummary(
        enabled: json['enabled'] as bool? ?? false,
        interval: (json['interval'] as num?)?.toInt() ?? 20,
        providerId: (json['providerId'] as String?)?.trim().isEmpty ?? true
            ? null
            : (json['providerId'] as String).trim(),
        model: (json['model'] as String?)?.trim().isEmpty ?? true
            ? null
            : (json['model'] as String).trim(),
        budget: (json['budget'] as num?)?.toInt(),
        method: SummaryMethod.byName(json['method'] as String?),
        notify: json['notify'] as bool? ?? false,
        useCustomPrompt: json['useCustomPrompt'] as bool? ?? false,
        prompt: json['prompt'] as String?,
        title: json['title'] as String? ?? '',
        segments: (json['segments'] as List?)
                ?.whereType<Map<String, dynamic>>()
                .map(SummarySegment.fromJson)
                .toList() ??
            <SummarySegment>[],
        lastSummarizedIndex: (json['lastSummarizedIndex'] as num?)?.toInt() ?? 0,
      );
}

