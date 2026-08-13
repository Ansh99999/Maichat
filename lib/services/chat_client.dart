import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/message.dart';
import '../models/provider.dart';

/// Raised for anything the user can act on: bad key, bad URL, dead host.
class ChatApiException implements Exception {
  ChatApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Generation knobs a preset contributes to a request. Only values that differ
/// from a neutral default are actually sent, so hosts that reject unknown or
/// unsupported fields keep working.
class GenParams {
  const GenParams({
    this.temperature,
    this.maxTokens,
    this.topP,
    this.topK,
    this.frequencyPenalty,
    this.presencePenalty,
    this.seed,
    this.n,
    this.stop = const <String>[],
    this.stream = true,
    this.thinking = false,
    this.thinkingBudget = 0,
    this.reasoningEffort = '',
  });

  final double? temperature;
  final int? maxTokens;
  final double? topP;
  final int? topK;
  final double? frequencyPenalty;
  final double? presencePenalty;
  final int? seed;
  final int? n;
  final List<String> stop;

  /// Whether to stream the reply. False takes a plain request/response round
  /// trip — no SSE at all — rather than streaming and hiding it.
  final bool stream;

  /// Whether to ask the model to think before answering.
  final bool thinking;

  /// Tokens the model may spend thinking; 0 leaves it to the provider.
  final int thinkingBudget;

  /// `''` | `low` | `medium` | `high`, for the hosts that take
  /// `reasoning_effort`.
  final String reasoningEffort;
}

/// One chunk of a reply: visible [text], the model's [reasoning], or both. The
/// two travel together (and in order) so a thinking block can be timed against
/// the moment the answer starts.
class ChatDelta {
  const ChatDelta({this.text = '', this.reasoning = ''});

  /// Message text meant for the chat.
  final String text;

  /// Thinking the provider returned in its own field — Anthropic's
  /// `thinking_delta`, Gemini's `thought` parts, `reasoning_content` on the
  /// OpenAI-compatible hosts. Thinking a model writes inline in its reply is not
  /// here: it arrives as [text] and is separated later by `splitReasoning`.
  final String reasoning;

  bool get isEmpty => text.isEmpty && reasoning.isEmpty;
}

/// Minimal client for chat and model listing. Speaks two wire formats depending
/// on the provider's [ProviderKind]: the OpenAI-compatible `/chat/completions`
/// and `/models` endpoints, and Anthropic's `/messages` and `/models`. Streaming
/// is done over server-sent events in both.
class ChatClient {
  http.Client? _active;

  /// Joins [baseUrl] and [path], tolerating trailing slashes and a base URL
  /// that already points at the endpoint.
  static Uri endpoint(String baseUrl, String path) {
    var base = baseUrl.trim();
    if (base.isEmpty) throw ChatApiException('Set a base URL in Settings.');
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      base = 'https://$base';
    }
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith(path)) return Uri.parse(base);
    final uri = Uri.tryParse('$base$path');
    if (uri == null) throw ChatApiException('Base URL is not a valid URL.');
    return uri;
  }

  /// Auth and content headers for [provider], keyed by its wire format:
  /// Anthropic wants `x-api-key` + a version header; Gemini wants
  /// `x-goog-api-key`; OpenAI wants a bearer.
  Map<String, String> _headers(Provider provider, {bool stream = false}) {
    final key = provider.apiKey.trim();
    return {
      'Content-Type': 'application/json',
      if (stream) 'Accept': 'text/event-stream',
      if (provider.kind == ProviderKind.anthropic)
        'anthropic-version': '2023-06-01',
      if (key.isNotEmpty)
        ...switch (provider.kind) {
          ProviderKind.anthropic => {'x-api-key': key},
          ProviderKind.gemini => {'x-goog-api-key': key},
          ProviderKind.openai => {'Authorization': 'Bearer $key'},
        },
    };
  }

  /// The request body for a chat turn, shaped for the provider's format and
  /// carrying the preset's [GenParams].
  Object _body(Provider provider, List<ChatMessage> history, GenParams params) {
    final model = provider.model.trim();
    final stop = params.stop.where((s) => s.trim().isNotEmpty).toList();
    if (provider.kind == ProviderKind.gemini) {
      // Gemini carries the system prompt as `systemInstruction`, names the
      // assistant role "model", and wraps text in `parts`. The model id travels
      // in the URL, not the body.
      final system = history
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n')
          .trim();
      final contents = history
          .where((m) => m.role != 'system')
          .map((m) => {
                'role': m.role == 'assistant' ? 'model' : 'user',
                'parts': [
                  {'text': m.content}
                ],
              })
          .toList(growable: false);
      final gen = <String, dynamic>{
        if (params.temperature != null) 'temperature': params.temperature,
        if ((params.maxTokens ?? 0) > 0) 'maxOutputTokens': params.maxTokens,
        if (params.topP != null && params.topP != 1.0) 'topP': params.topP,
        if ((params.topK ?? 0) > 0) 'topK': params.topK,
        if (stop.isNotEmpty) 'stopSequences': stop,
        // Gemini takes thinking as a budget in tokens plus a flag asking for the
        // thoughts themselves back; omitting the budget leaves it to the model.
        // Thinking off sends nothing rather than a 0 budget, because several
        // 2.5-era models reject an attempt to switch thinking off outright.
        if (params.thinking)
          'thinkingConfig': <String, dynamic>{
            'includeThoughts': true,
            if (params.thinkingBudget > 0) 'thinkingBudget': params.thinkingBudget,
          },
      };
      return {
        'contents': contents,
        if (system.isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': system}
            ],
          },
        if (gen.isNotEmpty) 'generationConfig': gen,
      };
    }
    if (provider.kind == ProviderKind.anthropic) {
      // Anthropic carries the system prompt separately and requires a token
      // ceiling; only user/assistant turns go in `messages`.
      final system = history
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n')
          .trim();
      final turns = history
          .where((m) => m.role != 'system')
          .map((m) => m.toApi())
          .toList(growable: false);
      var maxTokens = (params.maxTokens ?? 0) > 0 ? params.maxTokens! : 4096;
      // Extended thinking: the budget is a floor of 1024 and must leave room for
      // the answer, so a small response length is raised rather than rejected.
      // Sampling is fixed while thinking (the API refuses temperature/top_p/
      // top_k alongside it), so those are dropped instead of sent and refused.
      Map<String, dynamic>? thinking;
      if (params.thinking) {
        final budget =
            params.thinkingBudget > 1024 ? params.thinkingBudget : 1024;
        if (maxTokens <= budget) maxTokens = budget + 1024;
        thinking = {'type': 'enabled', 'budget_tokens': budget};
      }
      return {
        'model': model,
        'max_tokens': maxTokens,
        'stream': params.stream,
        if (system.isNotEmpty) 'system': system,
        'messages': turns,
        if (params.thinking) 'thinking': thinking,
        // Anthropic's temperature tops out at 1.0.
        if (thinking == null && params.temperature != null)
          'temperature': params.temperature!.clamp(0.0, 1.0),
        if (thinking == null && params.topP != null && params.topP != 1.0)
          'top_p': params.topP,
        if (thinking == null && (params.topK ?? 0) > 0) 'top_k': params.topK,
        if (stop.isNotEmpty) 'stop_sequences': stop,
      };
    }
    return {
      'model': model,
      'stream': params.stream,
      'messages': history.map((m) => m.toApi()).toList(growable: false),
      if (params.temperature != null) 'temperature': params.temperature,
      if ((params.maxTokens ?? 0) > 0) 'max_tokens': params.maxTokens,
      if (params.topP != null && params.topP != 1.0) 'top_p': params.topP,
      if (params.frequencyPenalty != null && params.frequencyPenalty != 0)
        'frequency_penalty': params.frequencyPenalty,
      if (params.presencePenalty != null && params.presencePenalty != 0)
        'presence_penalty': params.presencePenalty,
      if ((params.seed ?? -1) >= 0) 'seed': params.seed,
      if ((params.n ?? 1) > 1) 'n': params.n,
      if (stop.isNotEmpty) 'stop': stop,
      // `reasoning_effort` is OpenAI's own parameter and is understood by most
      // OpenAI-compatible hosts (OpenRouter, DeepSeek, Groq, the local servers).
      if (params.thinking && params.reasoningEffort.isNotEmpty)
        'reasoning_effort': params.reasoningEffort,
      // A token budget is not part of OpenAI's schema — OpenRouter's `reasoning`
      // object is the closest thing to a standard — so it is only sent when the
      // user has actually set one, keeping a strict host untouched by default.
      if (params.thinking && params.thinkingBudget > 0)
        'reasoning': <String, dynamic>{
          'max_tokens': params.thinkingBudget,
          if (params.reasoningEffort.isNotEmpty) 'effort': params.reasoningEffort,
        },
    };
  }

  /// The exact JSON request body this client would POST for [history], pretty
  /// printed — the inspector's "copy raw request", so what a user reports is the
  /// literal payload rather than a re-derivation of it. Shares [_body] with
  /// [streamChat], so the two can never drift.
  String requestPreview(
    Provider provider,
    List<ChatMessage> history, {
    GenParams params = const GenParams(),
  }) {
    final uri = requestUri(provider, stream: params.stream);
    final headers = _headers(provider, stream: params.stream)
      // Never put a credential on the clipboard.
      ..updateAll((key, value) => _isSecretHeader(key) ? '<redacted>' : value);
    final body =
        const JsonEncoder.withIndent('  ').convert(_body(provider, history, params));
    return 'POST $uri\n'
        '${headers.entries.map((e) => '${e.key}: ${e.value}').join('\n')}\n\n'
        '$body';
  }

  static bool _isSecretHeader(String name) {
    final lower = name.toLowerCase();
    return lower == 'authorization' ||
        lower == 'x-api-key' ||
        lower == 'x-goog-api-key';
  }

  /// The endpoint a chat turn is POSTed to, by provider format. Gemini puts the
  /// choice between streaming and a single response in the URL (a different
  /// method plus the `alt=sse` transport), where the other two formats carry it
  /// as a body field.
  static Uri requestUri(Provider provider, {bool stream = true}) {
    switch (provider.kind) {
      case ProviderKind.gemini:
        final uri = endpoint(
          provider.baseUrl,
          '/models/${Uri.encodeComponent(provider.model.trim())}'
              '${stream ? ':streamGenerateContent' : ':generateContent'}',
        );
        return stream ? uri.replace(queryParameters: {'alt': 'sse'}) : uri;
      case ProviderKind.anthropic:
        return endpoint(provider.baseUrl, '/messages');
      case ProviderKind.openai:
        return endpoint(provider.baseUrl, '/chat/completions');
    }
  }

  /// Streams a reply for [history] until the model stops: visible text and, when
  /// the provider returns it separately, the model's thinking.
  ///
  /// With `params.stream` off this makes an ordinary request and yields the whole
  /// reply as a single event — genuinely no streaming, rather than a stream the
  /// UI pretends not to see.
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    if (provider.model.trim().isEmpty) {
      throw ChatApiException('Pick a model in Settings first.');
    }
    final anthropic = provider.kind == ProviderKind.anthropic;
    final gemini = provider.kind == ProviderKind.gemini;
    final uri = requestUri(provider, stream: params.stream);
    final client = http.Client();
    _active = client;
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(_headers(provider, stream: params.stream))
        ..body = jsonEncode(_body(provider, history, params));

      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw ChatApiException(_describeFailure(response.statusCode, body));
      }

      if (!params.stream) {
        final body = await response.stream.bytesToString();
        final whole = _extractWhole(provider, body);
        if (!whole.isEmpty) yield whole;
        return;
      }

      final lines = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (gemini) {
          if (payload == '[DONE]') break;
          final delta = _extractGeminiDelta(payload);
          if (delta != null && !delta.isEmpty) yield delta;
        } else if (anthropic) {
          final event = _extractAnthropicDelta(payload);
          if (event.stop) break;
          final delta = event.delta;
          if (delta != null && !delta.isEmpty) yield delta;
        } else {
          if (payload == '[DONE]') break;
          final delta = _extractDelta(payload);
          if (delta != null && !delta.isEmpty) yield delta;
        }
      }
    } on ChatApiException {
      rethrow;
    } catch (e) {
      throw ChatApiException(_describeTransport(e));
    } finally {
      client.close();
      if (_active == client) _active = null;
    }
  }

  /// Aborts the in-flight stream, if any.
  void cancel() {
    _active?.close();
    _active = null;
  }

  /// The exact input-token count for [history] from Anthropic's
  /// `/messages/count_tokens` endpoint. Returns null for a non-Anthropic
  /// provider, a missing model/key, or any transport/HTTP failure — it is a
  /// best-effort display aid, never on the send path.
  Future<int?> countTokens(Provider provider, List<ChatMessage> history) async {
    if (provider.kind != ProviderKind.anthropic) return null;
    final model = provider.model.trim();
    if (model.isEmpty || provider.apiKey.isEmpty) return null;
    try {
      final system = history
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n')
          .trim();
      final turns = history
          .where((m) => m.role != 'system')
          .map((m) => m.toApi())
          .toList(growable: false);
      // count_tokens rejects an empty messages array; nothing to count then.
      if (turns.isEmpty) return null;
      final response = await http
          .post(
            endpoint(provider.baseUrl, '/messages/count_tokens'),
            headers: _headers(provider),
            body: jsonEncode({
              'model': model,
              if (system.isNotEmpty) 'system': system,
              'messages': turns,
            }),
          )
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json is Map<String, dynamic>) {
        final n = json['input_tokens'];
        if (n is num) return n.toInt();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fetches selectable model ids from the provider's `/models` endpoint.
  Future<List<String>> listModels(Provider provider) async {
    final uri = endpoint(provider.baseUrl, '/models');
    final gemini = provider.kind == ProviderKind.gemini;
    try {
      final response =
          await http.get(uri, headers: _headers(provider)).timeout(
                const Duration(seconds: 30),
              );
      if (response.statusCode != 200) {
        throw ChatApiException(
          _describeFailure(response.statusCode, response.body),
        );
      }
      final decoded = jsonDecode(response.body);
      // Gemini returns `{models:[{name:"models/gemini-..."}]}`; OpenAI-style
      // hosts return `{data:[{id:...}]}` (or a bare list).
      final data = decoded is Map<String, dynamic>
          ? (gemini ? decoded['models'] : decoded['data'])
          : (decoded is List ? decoded : null);
      if (data is! List) {
        throw ChatApiException('Unexpected /models response from this host.');
      }
      final ids = <String>{};
      for (final entry in data) {
        String? id;
        if (entry is Map<String, dynamic>) {
          id = gemini ? entry['name'] as String? : entry['id'] as String?;
          // Gemini prefixes ids with "models/"; drop it for a clean label.
          if (gemini && id != null && id.startsWith('models/')) {
            id = id.substring('models/'.length);
          }
        } else if (entry is String) {
          id = entry;
        }
        if (id != null && id.trim().isNotEmpty) ids.add(id.trim());
      }
      if (ids.isEmpty) {
        throw ChatApiException('This host listed no models.');
      }
      final sorted = ids.toList()..sort();
      return sorted;
    } on ChatApiException {
      rethrow;
    } catch (e) {
      throw ChatApiException(_describeTransport(e));
    }
  }

  /// Pulls the text (and any separately-returned reasoning) out of one SSE
  /// chunk, ignoring keep-alives and vendor-specific extras.
  ///
  /// Reasoning has no standard field on the OpenAI-compatible hosts: DeepSeek
  /// and most gateways use `reasoning_content`, OpenRouter uses `reasoning`.
  /// Both are read.
  static ChatDelta? _extractDelta(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return null;
      if (json['error'] != null) {
        throw ChatApiException(_describeErrorBody(json));
      }
      final choices = json['choices'];
      if (choices is! List || choices.isEmpty) return null;
      final choice = choices.first;
      if (choice is! Map<String, dynamic>) return null;
      final delta = choice['delta'];
      if (delta is Map<String, dynamic>) return _openAiParts(delta);
      // Some hosts echo non-streaming shapes even when stream is requested.
      final message = choice['message'];
      if (message is Map<String, dynamic>) return _openAiParts(message);
      return null;
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Reads `content` plus either reasoning field out of an OpenAI-shaped delta
  /// or message object.
  static ChatDelta _openAiParts(Map<String, dynamic> part) {
    final reasoning = part['reasoning_content'] ?? part['reasoning'];
    return ChatDelta(
      text: part['content'] is String ? part['content'] as String : '',
      reasoning: reasoning is String ? reasoning : '',
    );
  }

  /// Pulls text and thoughts out of one Gemini SSE chunk. Gemini nests text in
  /// `candidates[].content.parts[].text` and marks a thinking part with
  /// `thought: true`; it signals errors with a top-level `error` object, and the
  /// stream simply closes when generation is done.
  static ChatDelta? _extractGeminiDelta(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return null;
      if (json['error'] != null) {
        throw ChatApiException(_describeErrorBody(json));
      }
      final candidates = json['candidates'];
      if (candidates is! List || candidates.isEmpty) return null;
      final first = candidates.first;
      if (first is! Map<String, dynamic>) return null;
      return _geminiParts(first['content']);
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Splits a Gemini `content` object's parts into answer text and thoughts.
  static ChatDelta? _geminiParts(Object? content) {
    if (content is! Map<String, dynamic>) return null;
    final parts = content['parts'];
    if (parts is! List) return null;
    final text = StringBuffer();
    final thoughts = StringBuffer();
    for (final part in parts) {
      if (part is! Map<String, dynamic> || part['text'] is! String) continue;
      (part['thought'] == true ? thoughts : text).write(part['text'] as String);
    }
    return ChatDelta(text: text.toString(), reasoning: thoughts.toString());
  }

  /// Pulls the deltas out of one Anthropic SSE chunk. Returns whether the stream
  /// has ended ([stop]) alongside anything to append. Anthropic ends with a
  /// `message_stop` event rather than OpenAI's `[DONE]` sentinel, and extended
  /// thinking arrives as `thinking_delta` events ahead of the text ones.
  static ({ChatDelta? delta, bool stop}) _extractAnthropicDelta(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return (delta: null, stop: false);
      final type = json['type'];
      if (type == 'error') {
        throw ChatApiException(_describeErrorBody(json));
      }
      if (type == 'message_stop') return (delta: null, stop: true);
      if (type == 'content_block_delta') {
        final delta = json['delta'];
        if (delta is Map<String, dynamic>) {
          if (delta['thinking'] is String) {
            return (
              delta: ChatDelta(reasoning: delta['thinking'] as String),
              stop: false,
            );
          }
          if (delta['text'] is String) {
            return (
              delta: ChatDelta(text: delta['text'] as String),
              stop: false,
            );
          }
        }
      }
      return (delta: null, stop: false);
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return (delta: null, stop: false);
    }
  }

  /// Reads a whole (non-streamed) response body into one delta, by provider
  /// format. Used when streaming is switched off, where there are no SSE events
  /// to parse — just one JSON document.
  static ChatDelta _extractWhole(Provider provider, String body) {
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
      throw ChatApiException(_describeErrorBody(json));
    }
    switch (provider.kind) {
      case ProviderKind.gemini:
        final candidates = json['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final first = candidates.first;
          if (first is Map<String, dynamic>) {
            final parts = _geminiParts(first['content']);
            if (parts != null) return parts;
          }
        }
        return const ChatDelta();
      case ProviderKind.anthropic:
        // `content` is a list of blocks: `thinking` ones first, then `text`.
        final blocks = json['content'];
        if (blocks is! List) return const ChatDelta();
        final text = StringBuffer();
        final thoughts = StringBuffer();
        for (final block in blocks) {
          if (block is! Map<String, dynamic>) continue;
          if (block['type'] == 'thinking' && block['thinking'] is String) {
            thoughts.write(block['thinking'] as String);
          } else if (block['text'] is String) {
            text.write(block['text'] as String);
          }
        }
        return ChatDelta(text: text.toString(), reasoning: thoughts.toString());
      case ProviderKind.openai:
        final choices = json['choices'];
        if (choices is! List || choices.isEmpty) return const ChatDelta();
        final choice = choices.first;
        if (choice is! Map<String, dynamic>) return const ChatDelta();
        final message = choice['message'];
        if (message is Map<String, dynamic>) return _openAiParts(message);
        // Legacy completion shape.
        if (choice['text'] is String) {
          return ChatDelta(text: choice['text'] as String);
        }
        return const ChatDelta();
    }
  }

  static String _describeFailure(int status, String body) {
    final detail = _tryErrorMessage(body);
    switch (status) {
      case 401:
      case 403:
        return 'Rejected (HTTP $status): check your API key.'
            '${detail == null ? '' : '\n$detail'}';
      case 404:
        return 'Not found (HTTP 404): check the base URL path, e.g. it usually '
            'ends in /v1.${detail == null ? '' : '\n$detail'}';
      case 429:
        return 'Rate limited (HTTP 429). Try again shortly.'
            '${detail == null ? '' : '\n$detail'}';
      default:
        return 'Request failed (HTTP $status).'
            '${detail == null ? '' : '\n$detail'}';
    }
  }

  static String? _tryErrorMessage(String body) {
    if (body.trim().isEmpty) return null;
    try {
      final json = jsonDecode(body);
      if (json is Map<String, dynamic>) return _describeErrorBody(json);
    } catch (_) {
      // Fall through to the raw body.
    }
    final flat = body.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 300 ? flat : '${flat.substring(0, 300)}...';
  }

  static String _describeErrorBody(Map<String, dynamic> json) {
    final error = json['error'];
    if (error is Map<String, dynamic>) {
      final message = error['message'];
      if (message is String && message.trim().isNotEmpty) return message.trim();
    }
    if (error is String && error.trim().isNotEmpty) return error.trim();
    final message = json['message'];
    if (message is String && message.trim().isNotEmpty) return message.trim();
    return 'The host returned an error.';
  }

  static String _describeTransport(Object e) {
    if (e is TimeoutException) return 'The host did not respond in time.';
    if (e is FormatException) return 'The host sent a malformed response.';
    if (e is http.ClientException) {
      // Closing the client mid-stream surfaces here; the caller treats a
      // user-initiated stop as success, so keep the wording neutral.
      return 'Connection interrupted: ${e.message}';
    }
    return 'Could not reach the host. Check the base URL and your network.';
  }
}
