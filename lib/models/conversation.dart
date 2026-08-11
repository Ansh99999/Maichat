import 'message.dart';

/// A named thread of messages, persisted as a whole.
class Conversation {
  Conversation({
    required this.id,
    required this.title,
    required this.messages,
    required this.updatedAt,
    this.characterId,
    this.characterName,
    this.systemPrompt = '',
    this.presetId,
    Map<String, String>? variables,
  }) : variables = variables ?? <String, String>{};

  final String id;
  String title;
  final List<ChatMessage> messages;
  DateTime updatedAt;

  /// Set when this thread was started from a saved character. [characterName]
  /// is denormalised so the chat still reads right if the character is later
  /// edited or deleted, and [systemPrompt] is the composed persona injected
  /// (invisibly) ahead of the history on every turn.
  String? characterId;
  String? characterName;
  String systemPrompt;

  /// The generation preset this thread runs under (by [Preset.id]); null falls
  /// back to the app's default preset.
  String? presetId;

  /// Per-chat macro variables ({{setvar}}/{{getvar}}), SillyTavern's local scope.
  final Map<String, String> variables;

  factory Conversation.empty() => Conversation(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        title: 'New chat',
        messages: <ChatMessage>[],
        updatedAt: DateTime.now(),
      );

  bool get isEmpty => messages.isEmpty;

  /// Whether this thread is bound to a saved character.
  bool get hasCharacter => characterId != null;

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
        if (characterId != null) 'characterId': characterId,
        if (characterName != null) 'characterName': characterName,
        if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
        if (presetId != null) 'presetId': presetId,
        if (variables.isNotEmpty) 'variables': variables,
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory Conversation.fromJson(Map<String, dynamic> json) => Conversation(
        id: json['id'] as String? ??
            DateTime.now().microsecondsSinceEpoch.toString(),
        title: json['title'] as String? ?? 'New chat',
        updatedAt:
            DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
                DateTime.now(),
        characterId: json['characterId'] as String?,
        characterName: json['characterName'] as String?,
        systemPrompt: json['systemPrompt'] as String? ?? '',
        presetId: json['presetId'] as String?,
        variables: (json['variables'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        ),
        messages: (json['messages'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList(),
      );
}
