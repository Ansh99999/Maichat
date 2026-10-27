/// Portable chat-tool definitions and the durable record of one logical run.
///
/// The model deliberately uses [AgentMessage] rather than `ChatMessage`: a
/// tool run is protocol traffic (an assistant asking to call a tool, then the
/// tool answering), not a visible chat turn. Keeping it separate also avoids
/// the model/chat model import cycle.
library;

import 'dart:convert';

import 'agent_message.dart';
import 'message_image.dart';

/// The shape handed to an AI provider: one callable operation and its JSON
/// Schema.
class ChatToolDefinition {
  const ChatToolDefinition({
    required this.name,
    required this.description,
    this.parameters = const <String, dynamic>{
      'type': 'object',
      'properties': <String, dynamic>{},
    },
    this.action = const <String, dynamic>{},
    this.enabled = true,
    this.hidden = false,
    this.followUp = true,
    this.builtin = false,
    this.tags = const <String>[],
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final Map<String, dynamic> action;
  final bool enabled;
  final bool hidden;
  final bool followUp;
  final bool builtin;

  /// User-facing labels for organising the Tools list. They are local UI
  /// metadata and never enter [spec], which is the shape sent to providers.
  final List<String> tags;

  ToolSpec get spec =>
      ToolSpec(name: name, description: description, parameters: parameters);

  ChatToolDefinition copyWith({
    String? name,
    String? description,
    Map<String, dynamic>? parameters,
    Map<String, dynamic>? action,
    bool? enabled,
    bool? hidden,
    bool? followUp,
    bool? builtin,
    List<String>? tags,
  }) => ChatToolDefinition(
    name: name ?? this.name,
    description: description ?? this.description,
    parameters: parameters ?? this.parameters,
    action: action ?? this.action,
    enabled: enabled ?? this.enabled,
    hidden: hidden ?? this.hidden,
    followUp: followUp ?? this.followUp,
    builtin: builtin ?? this.builtin,
    tags: tags ?? this.tags,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    if (!_isDefaultSchema(parameters)) 'parameters': parameters,
    if (action.isNotEmpty) 'action': action,
    if (!enabled) 'enabled': false,
    if (hidden) 'hidden': true,
    if (!followUp) 'followUp': false,
    if (builtin) 'builtin': true,
    if (tags.isNotEmpty) 'tags': tags,
  };

  factory ChatToolDefinition.fromJson(Map<String, dynamic> json) =>
      ChatToolDefinition(
        name: json['name']?.toString() ?? '',
        description: json['description']?.toString() ?? '',
        parameters: _jsonMap(json['parameters'], const <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        }),
        action: _jsonMap(json['action']),
        enabled: json['enabled'] is! bool || json['enabled'] as bool,
        hidden: json['hidden'] as bool? ?? false,
        followUp: json['followUp'] is! bool || json['followUp'] as bool,
        builtin: json['builtin'] as bool? ?? false,
        tags: normalizeToolTags(json['tags']),
      );

  static bool _isDefaultSchema(Map<String, dynamic> schema) {
    final properties = schema['properties'];
    return schema.length == 2 &&
        schema['type'] == 'object' &&
        properties is Map &&
        properties.isEmpty;
  }
}

/// Global defaults for tool calling. Per-chat configuration can override the
/// switches but should not need its own model shape.
class ChatToolConfig {
  const ChatToolConfig({
    this.enabled = false,
    this.disabledTools = const <String>[],
    this.customTools = const <ChatToolDefinition>[],
    this.maxRounds = 5,
    this.maxCalls = 20,
    this.trackerPlacement = 'message',
    this.hideToolCallsInChat = false,
    this.followUpOverrides = const {},
    this.tagOverrides = const {},
  });

  final bool enabled;
  final List<String> disabledTools;
  final List<ChatToolDefinition> customTools;
  final int maxRounds;
  final int maxCalls;
  final String trackerPlacement;

  /// When set, tool calls and results are not shown in the chat transcript at
  /// all. Tool calling itself keeps working; only the in-chat UI is hidden.
  final bool hideToolCallsInChat;

  /// Per-scope runtime choices for built-in operations, whose definitions stay read-only.
  final Map<String, bool> followUpOverrides;

  /// User tags for built-ins. Their executable definitions stay read-only;
  /// this map carries the editable metadata for the current scope.
  final Map<String, List<String>> tagOverrides;

  ChatToolConfig copyWith({
    bool? enabled,
    List<String>? disabledTools,
    List<ChatToolDefinition>? customTools,
    int? maxRounds,
    int? maxCalls,
    String? trackerPlacement,
    bool? hideToolCallsInChat,
    Map<String, bool>? followUpOverrides,
    Map<String, List<String>>? tagOverrides,
  }) => ChatToolConfig(
    enabled: enabled ?? this.enabled,
    disabledTools: disabledTools ?? this.disabledTools,
    customTools: customTools ?? this.customTools,
    maxRounds: maxRounds ?? this.maxRounds,
    maxCalls: maxCalls ?? this.maxCalls,
    trackerPlacement: trackerPlacement ?? this.trackerPlacement,
    hideToolCallsInChat: hideToolCallsInChat ?? this.hideToolCallsInChat,
    followUpOverrides: followUpOverrides ?? this.followUpOverrides,
    tagOverrides: tagOverrides ?? this.tagOverrides,
  );

  Map<String, dynamic> toJson() => {
    if (enabled) 'enabled': true,
    if (disabledTools.isNotEmpty) 'disabledTools': disabledTools,
    if (customTools.isNotEmpty)
      'customTools': [for (final t in customTools) t.toJson()],
    if (maxRounds != 5) 'maxRounds': maxRounds,
    if (maxCalls != 20) 'maxCalls': maxCalls,
    if (trackerPlacement != 'message') 'trackerPlacement': trackerPlacement,
    if (hideToolCallsInChat) 'hideToolCallsInChat': true,
    if (followUpOverrides.isNotEmpty) 'followUpOverrides': followUpOverrides,
    if (tagOverrides.isNotEmpty) 'tagOverrides': tagOverrides,
  };

  factory ChatToolConfig.fromJson(Map<String, dynamic> json) => ChatToolConfig(
    enabled: json['enabled'] as bool? ?? false,
    disabledTools: [
      if (json['disabledTools'] is List)
        for (final value in json['disabledTools'] as List)
          if (value is String) value,
    ],
    customTools: [
      if (json['customTools'] is List)
        for (final value in json['customTools'] as List)
          if (value is Map)
            ChatToolDefinition.fromJson(Map<String, dynamic>.from(value)),
    ],
    maxRounds: _clamp((json['maxRounds'] as num?)?.toInt() ?? 5, 1, 10),
    maxCalls: _clamp((json['maxCalls'] as num?)?.toInt() ?? 20, 1, 50),
    trackerPlacement: json['trackerPlacement']?.toString() ?? 'message',
    hideToolCallsInChat: json['hideToolCallsInChat'] as bool? ?? false,
    followUpOverrides: {
      if (json['followUpOverrides'] is Map)
        for (final entry in (json['followUpOverrides'] as Map).entries)
          if (entry.key is String && entry.value is bool)
            entry.key as String: entry.value as bool,
    },
    tagOverrides: {
      if (json['tagOverrides'] is Map)
        for (final entry in (json['tagOverrides'] as Map).entries)
          if (entry.key is String && entry.value is List)
            entry.key as String: normalizeToolTags(entry.value),
    },
  );
}

/// One state change made by a run. `before` is the precondition used when
/// projecting history; `after` is the value that should replace it.
class ChatToolEffect {
  const ChatToolEffect({required this.key, this.before, this.after});

  final String key;
  final Object? before;
  final Object? after;

  Map<String, dynamic> toJson() => {
    'key': key,
    if (before != null) 'before': before,
    if (after != null) 'after': after,
  };

  factory ChatToolEffect.fromJson(Map<String, dynamic> json) => ChatToolEffect(
    key: json['key']?.toString() ?? '',
    before: json.containsKey('before') ? json['before'] : null,
    after: json.containsKey('after') ? json['after'] : null,
  );
}

/// A bounded logical tool run. [history] holds the complete assistant/tool
/// exchanges needed by follow-up requests, not the final visible chat reply.
class ChatToolRun {
  const ChatToolRun({
    required this.id,
    this.providerId = '',
    this.model = '',
    this.wire = '',
    this.endpoint = '',
    this.contextAnchor = '',
    this.history = const <AgentMessage>[],
    this.effects = const <ChatToolEffect>[],
    this.images = const <MessageImage>[],
    this.status = 'running',
  });

  final String id;
  final String providerId;
  final String model;
  final String wire;
  final String endpoint;
  final String contextAnchor;
  final List<AgentMessage> history;
  final List<ChatToolEffect> effects;
  final List<MessageImage> images;
  final String status;

  ChatToolRun copyWith({
    String? id,
    String? providerId,
    String? model,
    String? wire,
    String? endpoint,
    String? contextAnchor,
    List<AgentMessage>? history,
    List<ChatToolEffect>? effects,
    List<MessageImage>? images,
    String? status,
  }) => ChatToolRun(
    id: id ?? this.id,
    providerId: providerId ?? this.providerId,
    model: model ?? this.model,
    wire: wire ?? this.wire,
    endpoint: endpoint ?? this.endpoint,
    contextAnchor: contextAnchor ?? this.contextAnchor,
    history: history ?? this.history,
    effects: effects ?? this.effects,
    images: images ?? this.images,
    status: status ?? this.status,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    if (providerId.isNotEmpty) 'providerId': providerId,
    if (model.isNotEmpty) 'model': model,
    if (wire.isNotEmpty) 'wire': wire,
    if (endpoint.isNotEmpty) 'endpoint': endpoint,
    if (contextAnchor.isNotEmpty) 'contextAnchor': contextAnchor,
    if (history.isNotEmpty) 'history': [for (final m in history) m.toJson()],
    if (effects.isNotEmpty) 'effects': [for (final e in effects) e.toJson()],
    if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
    if (status != 'running') 'status': status,
  };

  factory ChatToolRun.fromJson(Map<String, dynamic> json) => ChatToolRun(
    id: json['id']?.toString() ?? '',
    providerId: json['providerId']?.toString() ?? '',
    model: json['model']?.toString() ?? '',
    wire: json['wire']?.toString() ?? '',
    endpoint: json['endpoint']?.toString() ?? '',
    contextAnchor: json['contextAnchor']?.toString() ?? '',
    history: [
      if (json['history'] is List)
        for (final value in json['history'] as List)
          if (value is Map)
            AgentMessage.fromJson(Map<String, dynamic>.from(value)),
    ],
    effects: [
      if (json['effects'] is List)
        for (final value in json['effects'] as List)
          if (value is Map)
            ChatToolEffect.fromJson(Map<String, dynamic>.from(value)),
    ],
    images: [
      if (json['images'] is List)
        for (final value in json['images'] as List)
          if (value is Map)
            MessageImage.fromJson(Map<String, dynamic>.from(value)),
    ],
    status: json['status']?.toString() ?? 'running',
  );
}

/// The state obtained by replaying recorded effects, plus the runs whose
/// preconditions no longer match and must not be treated as current.
class ChatToolProjection {
  const ChatToolProjection({
    this.values = const <String, dynamic>{},
    this.staleRuns = const <String>{},
  });

  final Map<String, dynamic> values;
  final Set<String> staleRuns;
}

/// Projects recorded effects in order. This is pure: no handlers, no random
/// numbers, and no mutation of the supplied [runs] or [base].
///
/// Preconditions are checked for the whole run before any of its effects are
/// applied. That keeps a run atomic: if its first effect is stale, a later
/// effect in the same run cannot half-apply.
ChatToolProjection projectChatToolRuns(
  Iterable<ChatToolRun> runs, {
  Map<String, dynamic> base = const <String, dynamic>{},
}) {
  final values = _cloneJson(base);
  final stale = <String>{};

  for (final run in runs) {
    final candidate = _cloneJson(values);
    var runIsStale = false;
    for (final effect in run.effects) {
      final current = candidate[effect.key];
      if (!_jsonEqual(current, effect.before)) {
        runIsStale = true;
        break;
      }
      if (effect.after == null) {
        candidate.remove(effect.key);
      } else {
        candidate[effect.key] = _cloneAny(effect.after);
      }
    }

    if (runIsStale) {
      stale.add(run.id);
      continue;
    }

    values
      ..clear()
      ..addAll(candidate);
  }

  return ChatToolProjection(values: values, staleRuns: stale);
}

/// Trims labels, collapses internal whitespace, drops empties and removes
/// case-insensitive duplicates while preserving the first spelling/order.
List<String> normalizeToolTags(Object? value) {
  if (value is! Iterable) return const <String>[];
  final seen = <String>{};
  final result = <String>[];
  for (final raw in value) {
    if (raw is! String) continue;
    final tag = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (tag.isEmpty) continue;
    final key = tag.toLowerCase();
    if (seen.add(key)) result.add(tag);
  }
  return List<String>.unmodifiable(result);
}

Map<String, dynamic> _jsonMap(
  Object? value, [
  Map<String, dynamic> fallback = const <String, dynamic>{},
]) {
  if (value is Map) {
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return Map<String, dynamic>.from(fallback);
}

int _clamp(int value, int min, int max) => value < min
    ? min
    : value > max
    ? max
    : value;

Map<String, dynamic> _cloneJson(Map<String, dynamic> value) {
  final cloned = _cloneAny(value);
  if (cloned is Map<String, dynamic>) return cloned;
  throw const FormatException('Tool state must be a JSON object.');
}

Object? _cloneAny(Object? value) {
  // Encoding and decoding is bounded by the models' persisted JSON size and
  // gives the exact semantics needed here: a deep, type-normalising clone that
  // cannot alias the caller's nested values.
  return jsonDecode(jsonEncode(value));
}

bool _jsonEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) {
    if (!a.isFinite || !b.isFinite) return false;
    return a == b;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_jsonEqual(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a.runtimeType == b.runtimeType && a == b;
}
