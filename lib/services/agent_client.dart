import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/agent_message.dart';
import '../models/provider.dart';
import '../models/usage.dart';
import 'chat_client.dart';

/// Sampling for one agent turn. Smaller than [GenParams] on purpose: an agent
/// is asked to follow instructions and call tools, not to be creative, and the
/// knobs a roleplay preset carries (penalties, stop strings, thinking budgets)
/// are exactly the ones that break tool calling on one host or another.
class AgentParams {
  const AgentParams({this.temperature, this.maxTokens, this.stream = true});

  final double? temperature;

  /// The reply's ceiling. Anthropic requires one, so it falls back to
  /// [kAgentDefaultMaxTokens] there when unset.
  final int? maxTokens;
  final bool stream;
}

/// What Anthropic is sent when no ceiling was set. Big enough for a model to
/// write a whole description into a tool call in one go.
const int kAgentDefaultMaxTokens = 8192;

/// One piece of an agent turn as it arrives.
///
/// Text and thinking stream in as they are written. Tool calls do not: a call
/// is only yielded once its arguments are complete, so a consumer never sees
/// half a JSON object.
class AgentDelta {
  const AgentDelta({
    this.text = '',
    this.reasoning = '',
    this.toolCalls = const <ToolCall>[],
    this.usage,
  });

  final String text;
  final String reasoning;
  final List<ToolCall> toolCalls;
  final TokenUsage? usage;

  bool get isEmpty =>
      text.isEmpty && reasoning.isEmpty && toolCalls.isEmpty && usage == null;
}

/// Talks tool-calling to a provider, in whichever of the four dialects it
/// speaks.
///
/// Kept apart from [ChatClient.streamChat] so the roleplay send path — and the
/// one-`system`-message rule the gateways need there — is untouched by any of
/// this. It borrows the same URLs, headers and failure wording, so a Studio
/// error reads exactly like a chat error.
///
/// One instance holds one live request, like [ChatClient]; the Studio gives
/// every agent (and every sub-agent) its own, so they can run side by side.
class AgentClient {
  AgentClient({http.Client Function()? clientFactory})
      : _clientFactory = clientFactory ?? http.Client.new;

  final http.Client Function() _clientFactory;
  http.Client? _active;

  /// Aborts the in-flight request, if any.
  void cancel() {
    _active?.close();
    _active = null;
  }

  /// Streams one assistant turn for [messages], offering [tools].
  Stream<AgentDelta> stream({
    required Provider provider,
    required List<AgentMessage> messages,
    List<ToolSpec> tools = const <ToolSpec>[],
    AgentParams params = const AgentParams(),
  }) async* {
    if (provider.model.trim().isEmpty) {
      throw ChatApiException('Pick a model for the Studio first.');
    }
    final uri = ChatClient.requestUri(provider, stream: params.stream);
    final client = _clientFactory();
    _active = client;
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(
          ChatClient.requestHeaders(provider, stream: params.stream),
        )
        ..body = jsonEncode(body(provider, messages, tools, params));
      final response = await client.send(request);
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw ChatApiException(ChatClient.describeFailure(
          response.statusCode,
          text,
        ));
      }
      if (!params.stream) {
        final whole = parseWhole(provider.wire, await response.stream.bytesToString());
        if (!whole.isEmpty) yield whole;
        return;
      }
      final reader = _StreamReader(provider.wire);
      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        final delta = reader.read(payload);
        if (delta != null && !delta.isEmpty) yield delta;
        if (reader.done) break;
      }
      final tail = reader.finish();
      if (!tail.isEmpty) yield tail;
    } on ChatApiException {
      rethrow;
    } catch (e) {
      throw ChatApiException(ChatClient.describeTransport(e));
    } finally {
      client.close();
      if (_active == client) _active = null;
    }
  }

  // --- request --------------------------------------------------------------

  /// The request body for [provider]'s dialect. Public so tests can pin the
  /// exact shape of each one.
  static Map<String, dynamic> body(
    Provider provider,
    List<AgentMessage> messages,
    List<ToolSpec> tools,
    AgentParams params,
  ) {
    final model = provider.model.trim();
    final system = messages
        .where((m) => m.role == AgentRole.system)
        .map((m) => m.text)
        .join('\n\n')
        .trim();
    final turns =
        messages.where((m) => m.role != AgentRole.system).toList(growable: false);
    switch (provider.wire) {
      case WireFormat.openaiChat:
        return {
          'model': model,
          'stream': params.stream,
          if (params.stream && provider.kind.usageReporting)
            'stream_options': <String, dynamic>{'include_usage': true},
          'messages': [
            if (system.isNotEmpty) {'role': 'system', 'content': system},
            for (final m in turns) _openAiChatTurn(m),
          ],
          if (tools.isNotEmpty)
            'tools': [
              for (final t in tools)
                {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.parameters,
                  },
                },
            ],
          if (params.temperature != null) 'temperature': params.temperature,
          if ((params.maxTokens ?? 0) > 0) 'max_tokens': params.maxTokens,
        };
      case WireFormat.openaiResponses:
        return {
          'model': model,
          'stream': params.stream,
          if (system.isNotEmpty) 'instructions': system,
          'input': [for (final m in turns) ..._responsesItems(m)],
          if (tools.isNotEmpty)
            'tools': [
              for (final t in tools)
                {
                  'type': 'function',
                  'name': t.name,
                  'description': t.description,
                  'parameters': t.parameters,
                },
            ],
          if (params.temperature != null) 'temperature': params.temperature,
          if ((params.maxTokens ?? 0) > 0) 'max_output_tokens': params.maxTokens,
        };
      case WireFormat.anthropic:
        return {
          'model': model,
          'max_tokens': (params.maxTokens ?? 0) > 0
              ? params.maxTokens
              : kAgentDefaultMaxTokens,
          'stream': params.stream,
          if (system.isNotEmpty) 'system': system,
          'messages': _anthropicTurns(turns),
          if (tools.isNotEmpty)
            'tools': [
              for (final t in tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.parameters,
                },
            ],
          if (params.temperature != null)
            'temperature': params.temperature!.clamp(0.0, 1.0),
        };
      case WireFormat.gemini:
        final gen = <String, dynamic>{
          if (params.temperature != null) 'temperature': params.temperature,
          if ((params.maxTokens ?? 0) > 0) 'maxOutputTokens': params.maxTokens,
        };
        return {
          'contents': _geminiContents(turns),
          if (system.isNotEmpty)
            'systemInstruction': {
              'parts': [
                {'text': system},
              ],
            },
          if (tools.isNotEmpty)
            'tools': [
              {
                'functionDeclarations': [
                  for (final t in tools)
                    {
                      'name': t.name,
                      'description': t.description,
                      if (!t.takesNothing) 'parameters': t.parameters,
                    },
                ],
              },
            ],
          if (gen.isNotEmpty) 'generationConfig': gen,
        };
    }
  }

  static Map<String, dynamic> _openAiChatTurn(AgentMessage m) {
    switch (m.role) {
      case AgentRole.tool:
        return {
          'role': 'tool',
          'tool_call_id': m.toolCallId,
          'content': m.text,
        };
      case AgentRole.assistant:
        return {
          'role': 'assistant',
          // A turn that only calls tools has no content; OpenAI wants null
          // there, and several gateways reject an empty string beside calls.
          'content': m.text.isEmpty && m.toolCalls.isNotEmpty ? null : m.text,
          if (m.toolCalls.isNotEmpty)
            'tool_calls': [
              for (final c in m.toolCalls)
                {
                  'id': c.id,
                  'type': 'function',
                  'function': {
                    'name': c.name,
                    'arguments': jsonEncode(c.arguments),
                  },
                },
            ],
        };
      case AgentRole.user:
      case AgentRole.system:
        return {'role': 'user', 'content': m.text};
    }
  }

  static List<Map<String, dynamic>> _responsesItems(AgentMessage m) {
    switch (m.role) {
      case AgentRole.tool:
        return [
          {
            'type': 'function_call_output',
            'call_id': m.toolCallId,
            'output': m.text,
          },
        ];
      case AgentRole.assistant:
        return [
          if (m.text.isNotEmpty)
            {
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': m.text},
              ],
            },
          // Sent without the item `id` the host gave it: an id makes the API
          // insist on the matching reasoning item too, which is not kept.
          for (final c in m.toolCalls)
            {
              'type': 'function_call',
              'call_id': c.id,
              'name': c.name,
              'arguments': jsonEncode(c.arguments),
            },
        ];
      case AgentRole.user:
      case AgentRole.system:
        return [
          {
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': m.text},
            ],
          },
        ];
    }
  }

  /// Anthropic's turns. Every tool result for one assistant turn has to arrive
  /// in the single user turn that follows it, and first in it; a user message
  /// typed after them joins that same turn as a text block.
  static List<Map<String, dynamic>> _anthropicTurns(List<AgentMessage> turns) {
    final out = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? userBlocks;
    void flushUser() {
      if (userBlocks != null && userBlocks!.isNotEmpty) {
        out.add({'role': 'user', 'content': userBlocks});
      }
      userBlocks = null;
    }

    for (final m in turns) {
      switch (m.role) {
        case AgentRole.assistant:
          flushUser();
          out.add({
            'role': 'assistant',
            'content': [
              if (m.text.isNotEmpty) {'type': 'text', 'text': m.text},
              for (final c in m.toolCalls)
                {
                  'type': 'tool_use',
                  'id': c.id,
                  'name': c.name,
                  'input': c.arguments,
                },
            ],
          });
        case AgentRole.tool:
          (userBlocks ??= <Map<String, dynamic>>[]).add({
            'type': 'tool_result',
            'tool_use_id': m.toolCallId,
            'content': m.text,
            if (m.isError) 'is_error': true,
          });
        case AgentRole.user:
        case AgentRole.system:
          (userBlocks ??= <Map<String, dynamic>>[])
              .add({'type': 'text', 'text': m.text});
      }
    }
    flushUser();
    return out;
  }

  /// Gemini's contents. Results go back as `functionResponse` parts in one user
  /// turn, matched by name (and by id when the model gave one), and each call is
  /// echoed with its `thoughtSignature`.
  static List<Map<String, dynamic>> _geminiContents(List<AgentMessage> turns) {
    final out = <Map<String, dynamic>>[];
    List<Map<String, dynamic>>? userParts;
    // Which calls had a real id, so a made-up one is never sent back.
    final synthetic = <String>{};
    void flushUser() {
      if (userParts != null && userParts!.isNotEmpty) {
        out.add({'role': 'user', 'parts': userParts});
      }
      userParts = null;
    }

    for (final m in turns) {
      switch (m.role) {
        case AgentRole.assistant:
          flushUser();
          final parts = <Map<String, dynamic>>[
            if (m.text.isNotEmpty) {'text': m.text},
            for (final c in m.toolCalls)
              {
                'functionCall': {
                  'name': c.name,
                  'args': c.arguments,
                  if (!c.syntheticId) 'id': c.id,
                },
                if (c.signature != null) 'thoughtSignature': c.signature,
              },
          ];
          for (final c in m.toolCalls) {
            if (c.syntheticId) synthetic.add(c.id);
          }
          // Gemini refuses a turn with no parts at all.
          if (parts.isEmpty) parts.add({'text': ''});
          out.add({'role': 'model', 'parts': parts});
        case AgentRole.tool:
          (userParts ??= <Map<String, dynamic>>[]).add({
            'functionResponse': {
              'name': m.toolName,
              if (m.toolCallId != null && !synthetic.contains(m.toolCallId))
                'id': m.toolCallId,
              // The response has to be an object; the text rides inside it.
              'response': m.isError ? {'error': m.text} : {'result': m.text},
            },
          });
        case AgentRole.user:
        case AgentRole.system:
          (userParts ??= <Map<String, dynamic>>[]).add({'text': m.text});
      }
    }
    flushUser();
    return out;
  }

  // --- whole (non-streamed) replies ------------------------------------------

  /// A whole reply body read into one delta, by dialect.
  static AgentDelta parseWhole(WireFormat wire, String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } catch (_) {
      throw ChatApiException('The host sent a malformed response.');
    }
    if (json is! Map<String, dynamic>) {
      throw ChatApiException('The host sent an unexpected response shape.');
    }
    if (json['error'] != null) {
      throw ChatApiException(ChatClient.describeErrorBody(json));
    }
    switch (wire) {
      case WireFormat.openaiChat:
        final choices = json['choices'];
        final usage = ChatClient.openAiUsage(json['usage']);
        if (choices is! List || choices.isEmpty) return AgentDelta(usage: usage);
        final message = choices.first is Map ? choices.first['message'] : null;
        if (message is! Map) return AgentDelta(usage: usage);
        final calls = <ToolCall>[];
        final raw = message['tool_calls'];
        if (raw is List) {
          for (final c in raw) {
            if (c is! Map) continue;
            final fn = c['function'];
            if (fn is! Map) continue;
            final args = fn['arguments'];
            calls.add(_call(
              id: c['id'] as String?,
              name: fn['name'] as String? ?? '',
              rawArguments: args is String ? args : jsonEncode(args ?? {}),
              fallbackIndex: calls.length,
            ));
          }
        }
        final reasoning = message['reasoning_content'] ?? message['reasoning'];
        return AgentDelta(
          text: message['content'] is String ? message['content'] as String : '',
          reasoning: reasoning is String ? reasoning : '',
          toolCalls: calls,
          usage: usage,
        );
      case WireFormat.openaiResponses:
        final text = StringBuffer();
        final thoughts = StringBuffer();
        final calls = <ToolCall>[];
        final output = json['output'];
        if (output is List) {
          for (final item in output) {
            if (item is! Map) continue;
            if (item['type'] == 'function_call') {
              calls.add(_responsesCall(item, calls.length));
              continue;
            }
            final content = item['content'] ?? item['summary'];
            if (content is! List) continue;
            for (final part in content) {
              if (part is Map && part['text'] is String) {
                (item['type'] == 'reasoning' ? thoughts : text)
                    .write(part['text'] as String);
              }
            }
          }
        }
        return AgentDelta(
          text: text.toString(),
          reasoning: thoughts.toString(),
          toolCalls: calls,
          usage: ChatClient.openAiUsage(json['usage']),
        );
      case WireFormat.anthropic:
        final text = StringBuffer();
        final thoughts = StringBuffer();
        final calls = <ToolCall>[];
        final blocks = json['content'];
        if (blocks is List) {
          for (final b in blocks) {
            if (b is! Map) continue;
            switch (b['type']) {
              case 'text':
                text.write(b['text'] as String? ?? '');
              case 'thinking':
                thoughts.write(b['thinking'] as String? ?? '');
              case 'tool_use':
                calls.add(ToolCall(
                  id: b['id'] as String? ?? 'call_${calls.length}',
                  name: b['name'] as String? ?? '',
                  arguments: b['input'] is Map
                      ? Map<String, dynamic>.from(b['input'] as Map)
                      : const <String, dynamic>{},
                ));
            }
          }
        }
        return AgentDelta(
          text: text.toString(),
          reasoning: thoughts.toString(),
          toolCalls: calls,
          usage: ChatClient.openAiUsage(json['usage']),
        );
      case WireFormat.gemini:
        final reader = _StreamReader(WireFormat.gemini);
        final head = reader.readGemini(json) ?? const AgentDelta();
        return AgentDelta(
          text: head.text,
          reasoning: head.reasoning,
          toolCalls: reader.finish().toolCalls,
          usage: head.usage,
        );
    }
  }

  static ToolCall _responsesCall(Map item, int index) {
    final args = item['arguments'];
    return _call(
      id: (item['call_id'] ?? item['id']) as String?,
      name: item['name'] as String? ?? '',
      rawArguments: args is String ? args : jsonEncode(args ?? {}),
      fallbackIndex: index,
    );
  }

  /// A call from a raw argument string, with an id made up when the host sent
  /// none.
  static ToolCall _call({
    required String? id,
    required String name,
    required String rawArguments,
    required int fallbackIndex,
    String? signature,
  }) {
    final parsed = ToolCall.parseArguments(rawArguments);
    final hasId = id != null && id.trim().isNotEmpty;
    return ToolCall(
      id: hasId ? id : 'call_$fallbackIndex',
      name: name,
      arguments: parsed.arguments,
      argumentError: parsed.error,
      syntheticId: !hasId,
      signature: signature,
    );
  }
}

/// A tool call whose pieces are still arriving.
class _PartialCall {
  _PartialCall({this.id, this.name = ''});

  String? id;
  String name;
  final StringBuffer arguments = StringBuffer();
  Map<String, dynamic>? whole;
  String? signature;
}

/// Reads one dialect's SSE events, streaming text and thinking out as they come
/// and holding tool calls until they are whole.
class _StreamReader {
  _StreamReader(this.wire);

  final WireFormat wire;

  /// Whether the dialect has said it is finished.
  bool done = false;

  /// Calls in the order they started, keyed by the position the dialect uses to
  /// address them (OpenAI's `index`, Anthropic's block `index`, Responses'
  /// output index), or by arrival order for Gemini.
  final Map<int, _PartialCall> _calls = <int, _PartialCall>{};

  AgentDelta? read(String payload) {
    final Object? json;
    try {
      json = jsonDecode(payload);
    } catch (_) {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    switch (wire) {
      case WireFormat.openaiChat:
        return _openAiChat(json);
      case WireFormat.openaiResponses:
        return _responses(json);
      case WireFormat.anthropic:
        return _anthropic(json);
      case WireFormat.gemini:
        return readGemini(json);
    }
  }

  /// The tool calls that were held back, as the turn's last delta.
  AgentDelta finish() {
    final keys = _calls.keys.toList()..sort();
    final calls = <ToolCall>[];
    for (final k in keys) {
      final p = _calls[k]!;
      if (p.name.isEmpty) continue;
      if (p.whole != null) {
        final hasId = p.id != null && p.id!.isNotEmpty;
        calls.add(ToolCall(
          id: hasId ? p.id! : 'call_${calls.length}',
          name: p.name,
          arguments: p.whole!,
          syntheticId: !hasId,
          signature: p.signature,
        ));
      } else {
        calls.add(AgentClient._call(
          id: p.id,
          name: p.name,
          rawArguments: p.arguments.toString(),
          fallbackIndex: calls.length,
          signature: p.signature,
        ));
      }
    }
    _calls.clear();
    return AgentDelta(toolCalls: calls);
  }

  static Never _fail(Map<String, dynamic> json) =>
      throw ChatApiException(ChatClient.describeErrorBody(json));

  AgentDelta? _openAiChat(Map<String, dynamic> json) {
    if (json['error'] != null) _fail(json);
    final usage = ChatClient.openAiUsage(json['usage']);
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      return usage == null ? null : AgentDelta(usage: usage);
    }
    final choice = choices.first;
    if (choice is! Map) return null;
    final delta = choice['delta'] ?? choice['message'];
    if (delta is! Map) return usage == null ? null : AgentDelta(usage: usage);
    final raw = delta['tool_calls'];
    if (raw is List) {
      for (final entry in raw) {
        if (entry is! Map) continue;
        final id = entry['id'] as String?;
        // Most hosts address a call's pieces by `index`. A few gateways leave
        // it out and send each call whole; a new id then means a new call.
        var index = (entry['index'] as num?)?.toInt();
        if (index == null) {
          final last = _calls.isEmpty ? null : _calls[_calls.keys.last];
          index = (last == null || (id != null && id != last.id))
              ? _calls.length
              : _calls.keys.last;
        }
        final partial = _calls.putIfAbsent(index, _PartialCall.new);
        if (id != null && id.isNotEmpty) partial.id = id;
        final fn = entry['function'];
        if (fn is Map) {
          final name = fn['name'];
          if (name is String && name.isNotEmpty) partial.name = name;
          final args = fn['arguments'];
          if (args is String) {
            partial.arguments.write(args);
          } else if (args is Map) {
            partial.whole = Map<String, dynamic>.from(args);
          }
        }
      }
    }
    final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
    return AgentDelta(
      text: delta['content'] is String ? delta['content'] as String : '',
      reasoning: reasoning is String ? reasoning : '',
      usage: usage,
    );
  }

  AgentDelta? _responses(Map<String, dynamic> json) {
    final type = json['type'];
    if (type == 'error' || type == 'response.failed') _fail(json);
    switch (type) {
      case 'response.output_text.delta':
        return json['delta'] is String
            ? AgentDelta(text: json['delta'] as String)
            : null;
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_text.delta':
        return json['delta'] is String
            ? AgentDelta(reasoning: json['delta'] as String)
            : null;
      case 'response.output_item.added':
      case 'response.output_item.done':
        final item = json['item'];
        if (item is Map && item['type'] == 'function_call') {
          final index = (json['output_index'] as num?)?.toInt() ?? _calls.length;
          final partial = _calls.putIfAbsent(index, _PartialCall.new);
          partial.id = (item['call_id'] ?? item['id']) as String? ?? partial.id;
          partial.name = item['name'] as String? ?? partial.name;
          final args = item['arguments'];
          // `.done` carries the finished arguments; they replace the pieces.
          if (type == 'response.output_item.done' && args is String) {
            partial.arguments
              ..clear()
              ..write(args);
          }
        }
        return null;
      case 'response.function_call_arguments.delta':
        final index = (json['output_index'] as num?)?.toInt();
        final partial = index == null ? null : _calls[index];
        if (partial != null && json['delta'] is String) {
          partial.arguments.write(json['delta'] as String);
        }
        return null;
      case 'response.completed':
      case 'response.incomplete':
        done = true;
        final response = json['response'];
        return response is Map
            ? AgentDelta(usage: ChatClient.openAiUsage(response['usage']))
            : null;
    }
    return null;
  }

  AgentDelta? _anthropic(Map<String, dynamic> json) {
    final type = json['type'];
    if (type == 'error') _fail(json);
    switch (type) {
      case 'message_start':
        final message = json['message'];
        final usage =
            message is Map ? ChatClient.openAiUsage(message['usage']) : null;
        return usage == null ? null : AgentDelta(usage: usage);
      case 'content_block_start':
        final block = json['content_block'];
        final index = (json['index'] as num?)?.toInt() ?? _calls.length;
        if (block is Map && block['type'] == 'tool_use') {
          _calls[index] = _PartialCall(
            id: block['id'] as String?,
            name: block['name'] as String? ?? '',
          );
        }
        return null;
      case 'content_block_delta':
        final delta = json['delta'];
        if (delta is! Map) return null;
        switch (delta['type']) {
          case 'text_delta':
            return AgentDelta(text: delta['text'] as String? ?? '');
          case 'thinking_delta':
            return AgentDelta(reasoning: delta['thinking'] as String? ?? '');
          case 'input_json_delta':
            final index = (json['index'] as num?)?.toInt();
            final partial = index == null ? null : _calls[index];
            partial?.arguments.write(delta['partial_json'] as String? ?? '');
        }
        return null;
      case 'message_delta':
        final usage = ChatClient.openAiUsage(json['usage']);
        return usage == null ? null : AgentDelta(usage: usage);
      case 'message_stop':
        done = true;
        return null;
    }
    return null;
  }

  /// One Gemini chunk. A call arrives whole inside one part, with the
  /// signature beside it on that same part.
  AgentDelta? readGemini(Map<String, dynamic> json) {
    if (json['error'] != null) _fail(json);
    final usage = ChatClient.geminiUsage(json['usageMetadata']);
    final candidates = json['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      return usage == null ? null : AgentDelta(usage: usage);
    }
    final content = candidates.first is Map ? candidates.first['content'] : null;
    final parts = content is Map ? content['parts'] : null;
    final text = StringBuffer();
    final thoughts = StringBuffer();
    if (parts is List) {
      for (final part in parts) {
        if (part is! Map) continue;
        final call = part['functionCall'];
        if (call is Map) {
          _calls[_calls.length] = _PartialCall(
            id: call['id'] as String?,
            name: call['name'] as String? ?? '',
          )
            ..whole = call['args'] is Map
                ? Map<String, dynamic>.from(call['args'] as Map)
                : <String, dynamic>{}
            ..signature = part['thoughtSignature'] as String?;
          continue;
        }
        if (part['text'] is String) {
          (part['thought'] == true ? thoughts : text).write(part['text'] as String);
        }
      }
    }
    return AgentDelta(
      text: text.toString(),
      reasoning: thoughts.toString(),
      usage: usage,
    );
  }

}
