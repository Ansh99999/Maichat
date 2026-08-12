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
      return {
        'model': model,
        'max_tokens': (params.maxTokens ?? 0) > 0 ? params.maxTokens : 4096,
        'stream': true,
        if (system.isNotEmpty) 'system': system,
        'messages': turns,
        // Anthropic's temperature tops out at 1.0.
        if (params.temperature != null)
          'temperature': params.temperature!.clamp(0.0, 1.0),
        if (params.topP != null && params.topP != 1.0) 'top_p': params.topP,
        if ((params.topK ?? 0) > 0) 'top_k': params.topK,
        if (stop.isNotEmpty) 'stop_sequences': stop,
      };
    }
    return {
      'model': model,
      'stream': true,
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
    };
  }

  /// Streams assistant text deltas for [history] until the model stops.
  Stream<String> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    if (provider.model.trim().isEmpty) {
      throw ChatApiException('Pick a model in Settings first.');
    }
    final anthropic = provider.kind == ProviderKind.anthropic;
    final gemini = provider.kind == ProviderKind.gemini;
    final Uri uri;
    if (gemini) {
      // Gemini names the method on the model path and streams via `alt=sse`.
      uri = endpoint(
        provider.baseUrl,
        '/models/${Uri.encodeComponent(provider.model.trim())}'
            ':streamGenerateContent',
      ).replace(queryParameters: {'alt': 'sse'});
    } else {
      uri = endpoint(
        provider.baseUrl,
        anthropic ? '/messages' : '/chat/completions',
      );
    }
    final client = http.Client();
    _active = client;
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(_headers(provider, stream: true))
        ..body = jsonEncode(_body(provider, history, params));

      final response = await client.send(request);
      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        throw ChatApiException(_describeFailure(response.statusCode, body));
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
          final text = _extractGeminiDelta(payload);
          if (text != null && text.isNotEmpty) yield text;
        } else if (anthropic) {
          final event = _extractAnthropicDelta(payload);
          if (event.stop) break;
          final text = event.text;
          if (text != null && text.isNotEmpty) yield text;
        } else {
          if (payload == '[DONE]') break;
          final delta = _extractDelta(payload);
          if (delta != null && delta.isNotEmpty) yield delta;
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

  /// Pulls the text delta out of one SSE chunk, ignoring keep-alives and
  /// vendor-specific extras.
  static String? _extractDelta(String payload) {
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
      if (delta is Map<String, dynamic>) return delta['content'] as String?;
      // Some hosts echo non-streaming shapes even when stream is requested.
      final message = choice['message'];
      if (message is Map<String, dynamic>) return message['content'] as String?;
      return null;
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Pulls concatenated text out of one Gemini SSE chunk. Gemini nests text in
  /// `candidates[].content.parts[].text` and signals errors with a top-level
  /// `error` object; the stream simply closes when generation is done.
  static String? _extractGeminiDelta(String payload) {
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
      final content = first['content'];
      if (content is! Map<String, dynamic>) return null;
      final parts = content['parts'];
      if (parts is! List) return null;
      final buffer = StringBuffer();
      for (final part in parts) {
        if (part is Map<String, dynamic> && part['text'] is String) {
          buffer.write(part['text'] as String);
        }
      }
      return buffer.isEmpty ? null : buffer.toString();
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return null;
    }
  }

  /// Pulls the text delta out of one Anthropic SSE chunk. Returns whether the
  /// stream has ended ([stop]) alongside any [text] to append. Anthropic ends
  /// with a `message_stop` event rather than OpenAI's `[DONE]` sentinel.
  static ({String? text, bool stop}) _extractAnthropicDelta(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return (text: null, stop: false);
      final type = json['type'];
      if (type == 'error') {
        throw ChatApiException(_describeErrorBody(json));
      }
      if (type == 'message_stop') return (text: null, stop: true);
      if (type == 'content_block_delta') {
        final delta = json['delta'];
        if (delta is Map<String, dynamic> && delta['text'] is String) {
          return (text: delta['text'] as String, stop: false);
        }
      }
      return (text: null, stop: false);
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return (text: null, stop: false);
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
