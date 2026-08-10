import 'message.dart';

/// A named thread of messages, persisted as a whole.
class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.messages,
    required this.updatedAt,
  });

  final String id;
  String title;
  final List<ChatMessage> messages;
  DateTime updatedAt;

  factory Conversation.empty() => Conversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: 'New chat',
        messages: <ChatMessage>[],
        updatedAt: DateTime.now(),
      );

  bool get isEmpty => messages.isEmpty;

  /// Names an untitled thread after its opening user message.
  void retitleFrom(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return;
    title = flat.length <= 40 ? flat : '${flat.substring(0, 40)}...';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'updatedAt': updatedAt.toIso8601String(),
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: json['title'] as String? ?? 'New chat',
        updatedAt:
            DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
                DateTime.now(),
        messages: (json['messages'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList(),
      );
}
