import 'message.dart';
import 'preset.dart';

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
    this.impersonateId,
    this.impersonateName,
    this.presetId,
    this.presetOverride,
    Map<String, String>? variables,
    List<String>? lorebookIds,
  })  : variables = variables ?? <String, String>{},
        lorebookIds = lorebookIds ?? <String>[];

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

  /// Set when the user is impersonating a saved character in this thread — the
  /// "active identity" chosen from the send bar. [impersonateName] is
  /// denormalised so a turn still labels right if the character is later edited
  /// or deleted. The persona is injected into every outgoing request.
  String? impersonateId;
  String? impersonateName;

  /// Whether the user is currently speaking as an impersonated character.
  bool get isImpersonating => impersonateId != null;

  /// The generation preset this thread runs under (by [Preset.id]); null falls
  /// back to the app's default preset.
  String? presetId;

  /// A chat-specific preset copy that overrides [presetId] when present — the
  /// "save for this chat only" case from the in-chat preset editor.
  Preset? presetOverride;

  /// Per-chat macro variables ({{setvar}}/{{getvar}}), SillyTavern's local scope.
  final Map<String, String> variables;

  /// The lorebooks switched on for this thread, by [Lorebook.id]. More than one
  /// can be active at a time; their entries are pooled before the prompt is
  /// assembled. Order is the order they were added, which only matters as a
  /// tiebreaker between two entries of equal weight.
  final List<String> lorebookIds;

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
        if (impersonateId != null) 'impersonateId': impersonateId,
        if (impersonateName != null) 'impersonateName': impersonateName,
        if (presetId != null) 'presetId': presetId,
        if (presetOverride != null) 'presetOverride': presetOverride!.toJson(),
        if (variables.isNotEmpty) 'variables': variables,
        if (lorebookIds.isNotEmpty) 'lorebookIds': lorebookIds,
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
        impersonateId: json['impersonateId'] as String?,
        impersonateName: json['impersonateName'] as String?,
        presetId: json['presetId'] as String?,
        presetOverride: json['presetOverride'] is Map<String, dynamic>
            ? Preset.fromJson(json['presetOverride'] as Map<String, dynamic>)
            : null,
        variables: (json['variables'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v?.toString() ?? ''),
        ),
        lorebookIds: (json['lorebookIds'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList(),
        messages: (json['messages'] as List<dynamic>? ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ChatMessage.fromJson)
            .toList(),
      );
}
