/// One generated alternative for a turn — the unit the swipe control selects
/// between.
///
/// A turn normally has exactly one. Regenerating adds another instead of
/// throwing the old text away, and a character's alternate greetings seed
/// several up front, so the opening turn can be flipped through.
class MessageVariant {
  const MessageVariant({
    required this.content,
    this.reasoning = '',
    this.thinkingMs,
    this.error = false,
  });

  final String content;

  /// The model's thinking for this variant, tags stripped.
  final String reasoning;

  /// How long the model spent thinking, in milliseconds, or null while it is
  /// still thinking (or if it never did).
  final int? thinkingMs;

  /// Set when this variant holds a failure notice rather than model output.
  final bool error;

  MessageVariant copyWith({
    String? content,
    String? reasoning,
    int? thinkingMs,
    bool? error,
  }) =>
      MessageVariant(
        content: content ?? this.content,
        reasoning: reasoning ?? this.reasoning,
        thinkingMs: thinkingMs ?? this.thinkingMs,
        error: error ?? this.error,
      );

  Map<String, dynamic> toJson() => {
        'content': content,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (thinkingMs != null) 'thinkingMs': thinkingMs,
        if (error) 'error': true,
      };

  factory MessageVariant.fromJson(Map<String, dynamic> json) => MessageVariant(
        content: json['content'] as String? ?? '',
        reasoning: json['reasoning'] as String? ?? '',
        thinkingMs: (json['thinkingMs'] as num?)?.toInt(),
        error: json['error'] as bool? ?? false,
      );

  @override
  bool operator ==(Object other) =>
      other is MessageVariant &&
      other.content == content &&
      other.reasoning == reasoning &&
      other.thinkingMs == thinkingMs &&
      other.error == error;

  @override
  int get hashCode => Object.hash(content, reasoning, thinkingMs, error);
}

/// A single turn in a conversation.
///
/// The turn owns a list of [swipes] — its alternative texts — of which
/// [swipeIndex] is the live one; [content], [reasoning], [thinkingMs] and
/// [error] all read through to it, so everything that consumes a message (the
/// wire format included) sees the selected variant and nothing has to know
/// swipes exist. A turn built the plain way (`content:`) holds exactly one.
class ChatMessage {
  ChatMessage({
    required this.role,
    String content = '',
    bool error = false,
    String reasoning = '',
    int? thinkingMs,
    List<MessageVariant>? swipes,
    int swipeIndex = 0,
  })  : swipes = List<MessageVariant>.unmodifiable(
          swipes == null || swipes.isEmpty
              ? <MessageVariant>[
                  MessageVariant(
                    content: content,
                    reasoning: reasoning,
                    thinkingMs: thinkingMs,
                    error: error,
                  ),
                ]
              : swipes,
        ),
        swipeIndex = swipes == null || swipes.isEmpty
            ? 0
            : swipeIndex.clamp(0, swipes.length - 1);

  /// Either `user` or `assistant`.
  final String role;

  /// Every alternative this turn holds, oldest first. Never empty.
  final List<MessageVariant> swipes;

  /// Which of [swipes] is live.
  final int swipeIndex;

  /// The live variant — what the chat shows and the model receives.
  MessageVariant get active => swipes[swipeIndex];

  String get content => active.content;
  String get reasoning => active.reasoning;
  int? get thinkingMs => active.thinkingMs;
  bool get error => active.error;

  bool get isUser => role == 'user';

  bool get hasReasoning => reasoning.trim().isNotEmpty;

  /// How many alternatives this turn holds.
  int get swipeCount => swipes.length;

  /// Whether there is more than one alternative — the only case where the swipe
  /// control is worth drawing.
  bool get hasSwipes => swipes.length > 1;

  /// Edits the live variant, leaving the others untouched.
  ChatMessage copyWith({
    String? content,
    bool? error,
    String? reasoning,
    int? thinkingMs,
  }) {
    final next = active.copyWith(
      content: content,
      error: error,
      reasoning: reasoning,
      thinkingMs: thinkingMs,
    );
    return ChatMessage(
      role: role,
      swipes: <MessageVariant>[...swipes]..[swipeIndex] = next,
      swipeIndex: swipeIndex,
    );
  }

  /// Selects the variant at [index] — the ‹ › control. Out-of-range indices and
  /// the current one are no-ops.
  ChatMessage withSwipe(int index) =>
      index == swipeIndex || index < 0 || index >= swipes.length
          ? this
          : ChatMessage(
              role: role,
              swipes: swipes.toList(),
              swipeIndex: index,
            );

  /// Appends [variant] and selects it — the regenerate path, which keeps the
  /// reply it replaced as a swipe.
  ChatMessage addSwipe(MessageVariant variant) => ChatMessage(
        role: role,
        swipes: <MessageVariant>[...swipes, variant],
        swipeIndex: swipes.length,
      );

  /// Drops the variant at [index], selecting the one before it. A turn always
  /// keeps at least one variant, so this is a no-op on a single-swipe turn —
  /// used when a regeneration is aborted before producing anything.
  ChatMessage removeSwipe(int index) {
    if (swipes.length <= 1 || index < 0 || index >= swipes.length) return this;
    final rest = <MessageVariant>[...swipes]..removeAt(index);
    final selected = swipeIndex > index
        ? swipeIndex - 1
        : (swipeIndex == index ? index - 1 : swipeIndex);
    return ChatMessage(
      role: role,
      swipes: rest,
      swipeIndex: selected.clamp(0, rest.length - 1),
    );
  }

  /// The live variant is written flat (so an older reader, and anything that
  /// only cares about the current text, still finds it), with the alternatives
  /// alongside it only when there are any.
  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (error) 'error': true,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (thinkingMs != null) 'thinkingMs': thinkingMs,
        if (hasSwipes) 'swipes': swipes.map((s) => s.toJson()).toList(),
        if (hasSwipes) 'swipeIndex': swipeIndex,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final raw = json['swipes'];
    final swipes = raw is List
        ? raw
            .whereType<Map<String, dynamic>>()
            .map(MessageVariant.fromJson)
            .toList()
        : const <MessageVariant>[];
    return ChatMessage(
      role: json['role'] as String? ?? 'assistant',
      content: json['content'] as String? ?? '',
      error: json['error'] as bool? ?? false,
      reasoning: json['reasoning'] as String? ?? '',
      thinkingMs: (json['thinkingMs'] as num?)?.toInt(),
      swipes: swipes.isEmpty ? null : swipes,
      swipeIndex: (json['swipeIndex'] as num?)?.toInt() ?? 0,
    );
  }

  /// Wire format for the chat completions endpoint. Thinking is deliberately
  /// absent: it is a display artefact of one turn, not part of the transcript.
  Map<String, String> toApi() => {'role': role, 'content': content};
}

/// Collapses runs of consecutive same-role messages into one, joined by blank
/// lines.
///
/// Hosts disagree about same-role runs: Anthropic rejects them outright, and
/// several OpenAI-compatible gateways honour only the first `system` message and
/// drop the rest — which silently reduces a preset that frames the prompt with
/// many small blocks to whichever fragment happened to come first. Adjacent
/// blocks of one role are contiguous document text by design, so joining them is
/// what the preset author meant.
List<ChatMessage> mergeSameRole(List<ChatMessage> input) {
  final out = <ChatMessage>[];
  for (final message in input) {
    if (out.isNotEmpty && out.last.role == message.role) {
      out[out.length - 1] = ChatMessage(
        role: message.role,
        content: '${out.last.content}\n\n${message.content}',
      );
    } else {
      out.add(message);
    }
  }
  return out;
}
