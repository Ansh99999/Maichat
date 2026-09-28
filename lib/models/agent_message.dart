/// The conversation shape an agent runs on: ordinary turns plus the two things a
/// roleplay chat never has — a model asking for a tool, and the tool answering.
///
/// Deliberately *not* [ChatMessage]. That model is saved inside every chat and
/// carries swipes, attachments and the one-`system`-message rule the roleplay
/// wire depends on; an agent's tool traffic has no business in either. The
/// Character Studio keeps its transcript in these, and `AgentClient` turns them
/// into each dialect's own tool-calling shape.
library;

import 'dart:convert';

/// A tool the model may call: a name, a sentence on what it is for, and a JSON
/// Schema for its arguments.
///
/// Keep [parameters] to the subset every dialect accepts — `type`, `properties`,
/// `required`, `items`, `enum`, `description`. Gemini rejects most of the rest
/// (`additionalProperties`, `$ref`, union types), and a schema one host refuses
/// fails the whole request, not just the tool.
class ToolSpec {
  const ToolSpec({
    required this.name,
    required this.description,
    this.parameters = const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  /// Whether the tool takes no arguments at all — Gemini wants `parameters`
  /// left out entirely rather than an empty object.
  bool get takesNothing {
    final properties = parameters['properties'];
    return properties is! Map || properties.isEmpty;
  }
}

/// One call the model asked for.
class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    this.arguments = const <String, dynamic>{},
    this.argumentError,
    this.syntheticId = false,
    this.signature,
  });

  /// The call's id, which its result must quote back. Gemini's older models do
  /// not give one; [syntheticId] marks an id made up here, which is then never
  /// sent back to the host that did not issue it.
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  /// Set when the model's arguments were not a JSON object. The call is still
  /// recorded — the loop answers it with this error, so the model can retry —
  /// rather than being dropped, which would leave it waiting for a reply.
  final String? argumentError;

  final bool syntheticId;

  /// Gemini's `thoughtSignature` for the part that carried this call. Gemini 3
  /// refuses a follow-up turn whose function calls come back without it.
  final String? signature;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'arguments': arguments,
        if (argumentError != null) 'argumentError': argumentError,
        if (syntheticId) 'syntheticId': true,
        if (signature != null) 'signature': signature,
      };

  factory ToolCall.fromJson(Map<String, dynamic> json) => ToolCall(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        arguments: json['arguments'] is Map
            ? Map<String, dynamic>.from(json['arguments'] as Map)
            : const <String, dynamic>{},
        argumentError: json['argumentError'] as String?,
        syntheticId: json['syntheticId'] as bool? ?? false,
        signature: json['signature'] as String?,
      );

  /// Reads a model's raw argument string. An empty string is no arguments (the
  /// shape several hosts use for a tool that takes none); anything that is not
  /// a JSON object comes back as an error naming what arrived.
  static ({Map<String, dynamic> arguments, String? error}) parseArguments(
    String raw,
  ) {
    final text = raw.trim();
    if (text.isEmpty) return (arguments: const <String, dynamic>{}, error: null);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        return (arguments: Map<String, dynamic>.from(decoded), error: null);
      }
      return (
        arguments: const <String, dynamic>{},
        error: 'Arguments must be a JSON object.',
      );
    } catch (_) {
      final shown = text.length <= 200 ? text : '${text.substring(0, 200)}…';
      return (
        arguments: const <String, dynamic>{},
        error: 'Arguments were not valid JSON: $shown',
      );
    }
  }
}

/// Who spoke an [AgentMessage].
enum AgentRole { system, user, assistant, tool }

/// One turn of an agent's conversation.
///
/// An assistant turn may carry [toolCalls] beside (or instead of) its [text]; a
/// [AgentRole.tool] turn is the answer to exactly one of them, naming it by
/// [toolCallId] and [toolName] (Gemini matches results by name).
class AgentMessage {
  AgentMessage({
    required this.role,
    this.text = '',
    this.reasoning = '',
    List<ToolCall>? toolCalls,
    this.toolCallId,
    this.toolName,
    this.isError = false,
  }) : toolCalls = toolCalls ?? const <ToolCall>[];

  factory AgentMessage.system(String text) =>
      AgentMessage(role: AgentRole.system, text: text);

  factory AgentMessage.user(String text) =>
      AgentMessage(role: AgentRole.user, text: text);

  factory AgentMessage.toolResult(
    ToolCall call,
    String text, {
    bool isError = false,
  }) =>
      AgentMessage(
        role: AgentRole.tool,
        text: text,
        toolCallId: call.id,
        toolName: call.name,
        isError: isError,
      );

  final AgentRole role;
  final String text;

  /// The model's thinking, when the host returned it. Shown, never sent back.
  final String reasoning;
  final List<ToolCall> toolCalls;
  final String? toolCallId;
  final String? toolName;

  /// A tool result that reports a failure rather than an answer.
  final bool isError;

  Map<String, dynamic> toJson() => {
        'role': role.name,
        if (text.isNotEmpty) 'text': text,
        if (reasoning.isNotEmpty) 'reasoning': reasoning,
        if (toolCalls.isNotEmpty)
          'toolCalls': [for (final c in toolCalls) c.toJson()],
        if (toolCallId != null) 'toolCallId': toolCallId,
        if (toolName != null) 'toolName': toolName,
        if (isError) 'isError': true,
      };

  factory AgentMessage.fromJson(Map<String, dynamic> json) => AgentMessage(
        role: AgentRole.values.firstWhere(
          (r) => r.name == json['role'],
          orElse: () => AgentRole.user,
        ),
        text: json['text'] as String? ?? '',
        reasoning: json['reasoning'] as String? ?? '',
        toolCalls: [
          if (json['toolCalls'] is List)
            for (final c in json['toolCalls'] as List)
              if (c is Map) ToolCall.fromJson(Map<String, dynamic>.from(c)),
        ],
        toolCallId: json['toolCallId'] as String?,
        toolName: json['toolName'] as String?,
        isError: json['isError'] as bool? ?? false,
      );
}
