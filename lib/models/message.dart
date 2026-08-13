/// A single turn in a conversation.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.error = false,
    this.reasoning = '',
    this.thinkingMs,
  });

  /// Either `user` or `assistant`.
  final String role;
  final String content;

  /// Set when the turn holds a failure notice rather than model output.
  final bool error;

  /// The model's thinking for this turn, with the tags (if any) stripped —
  /// either returned separately by the provider or lifted out of the reply text.
  /// Shown as a collapsed block above the message; never sent back to the model.
  final String reasoning;

  /// How long the model spent thinking, in milliseconds, or null while it is
  /// still thinking (or if it never did).
  final int? thinkingMs;

  bool get isUser => role == 'user';

  bool get hasReasoning => reasoning.trim().isNotEmpty;

  ChatMessage copyWith({
    String? content,
    bool? error,
    String? reasoning,
    int? thinkingMs,
  }) =>
      ChatMessage(
        role: role,
        content: content ?? this.content,
        error: error ?? this.error,
        reasoning: reasoning ?? this.reasoning,
        thinkingMs: thinkingMs ?? this.thinkingMs,
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (error) 'error': true,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (thinkingMs != null) 'thinkingMs': thinkingMs,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'] as String? ?? 'assistant',
        content: json['content'] as String? ?? '',
        error: json['error'] as bool? ?? false,
        reasoning: json['reasoning'] as String? ?? '',
        thinkingMs: (json['thinkingMs'] as num?)?.toInt(),
      );

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
