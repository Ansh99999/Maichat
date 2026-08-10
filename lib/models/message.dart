/// A single turn in a conversation.
class ChatMessage {
  ChatMessage({
    required this.role,
    required this.content,
    this.error = false,
  });

  /// Either `user` or `assistant`.
  final String role;
  final String content;

  /// Set when the turn holds a failure notice rather than model output.
  final bool error;

  bool get isUser => role == 'user';

  ChatMessage copyWith({String? content, bool? error}) => ChatMessage(
        role: role,
        content: content ?? this.content,
        error: error ?? this.error,
      );

  Map<String, dynamic> toJson() => {
        'role': role,
        'content': content,
        if (error) 'error': true,
      };

  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
        role: json['role'] as String? ?? 'assistant',
        content: json['content'] as String? ?? '',
        error: json['error'] as bool? ?? false,
      );

  /// Wire format for the chat completions endpoint.
  Map<String, String> toApi() => {'role': role, 'content': content};
}
