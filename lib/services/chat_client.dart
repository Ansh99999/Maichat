import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/message.dart';
import '../models/provider.dart';
import '../models/usage.dart';

/// Raised for anything the user can act on: bad key, bad URL, dead host.
class ChatApiException implements Exception {
  ChatApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// What came back from trying one credential.
///
/// [ok] means the host accepted the key. It does not mean every model listed is
/// available to it — no API offers that — so the message stays modest about what
/// was actually proven.
class KeyTestResult {
  const KeyTestResult({
    required this.ok,
    required this.message,
    this.status,
    this.modelCount,
    this.latency,
  });

  final bool ok;

  /// One line for the UI, phrased for someone who does not know what a 401 is.
  final String message;

  /// The HTTP status, where there was one. Null for a transport failure.
  final int? status;

  /// How many models the host listed, when it listed any.
  final int? modelCount;

  final Duration? latency;

  /// A key that is not just wrong but *definitely* wrong — worth telling apart
  /// from a host that was merely unreachable, since only one of the two is
  /// solved by pasting a different key.
  bool get isRejected => status == 401 || status == 403;
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
  const ChatDelta({this.text = '', this.reasoning = '', this.usage});

  /// Message text meant for the chat.
  final String text;

  /// Thinking the provider returned in its own field — Anthropic's
  /// `thinking_delta`, Gemini's `thought` parts, `reasoning_content` on the
  /// OpenAI-compatible hosts. Thinking a model writes inline in its reply is not
  /// here: it arrives as [text] and is separated later by `splitReasoning`.
  final String reasoning;

  /// Token counts, on the one event that carries them. Every dialect reports
  /// usage once — at the end for the OpenAI shapes, incrementally for Anthropic,
  /// as a running snapshot for Gemini — so this is null on almost every delta and
  /// the last non-null value is the authoritative one.
  final TokenUsage? usage;

  bool get isEmpty => text.isEmpty && reasoning.isEmpty && usage == null;
}

/// Minimal client for chat and model listing. Speaks two wire formats depending
/// on the provider's [ProviderKind]: the OpenAI-compatible `/chat/completions`
/// and `/models` endpoints, and Anthropic's `/messages` and `/models`. Streaming
/// is done over server-sent events in both.
class ChatClient {
  http.Client? _active;

  /// Joins [baseUrl] and [path], tolerating trailing slashes and a base URL
  /// that already points at the endpoint.
  static Uri endpoint(String baseUrl, String path, {bool preferHttp = false}) {
    var base = baseUrl.trim();
    if (base.isEmpty) throw ChatApiException('Set a base URL in Settings.');
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      // A scheme-less address gets https, except for the local formats, where
      // `localhost:11434` plainly means http and upgrading it only produces a
      // confusing TLS error against a server that speaks none.
      base = '${preferHttp ? 'http' : 'https'}://$base';
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
  /// `x-goog-api-key`; the OpenAI dialects want a bearer.
  ///
  /// [Provider.customHeaders] is merged last so a user can deliberately override
  /// anything above — including the auth header — which is the point of it.
  Map<String, String> _headers(Provider provider, {bool stream = false}) {
    final key = provider.apiKey.trim();
    return {
      'Content-Type': 'application/json',
      if (stream) 'Accept': 'text/event-stream',
      if (provider.wire == WireFormat.anthropic)
        'anthropic-version': '2023-06-01',
      if (key.isNotEmpty)
        ...switch (provider.wire) {
          WireFormat.anthropic => {'x-api-key': key},
          WireFormat.gemini => {'x-goog-api-key': key},
          WireFormat.openaiChat ||
          WireFormat.openaiResponses =>
            {'Authorization': 'Bearer $key'},
        },
      if (provider.claudeCodeHeaders) ..._claudeCodeHeaders,
      ...provider.customHeaders,
    };
  }

  /// The headers Claude Code sends to identify itself. Kept in one place so the
  /// set is auditable rather than scattered through the request builder.
  static const Map<String, String> _claudeCodeHeaders = <String, String>{
    'x-app': 'cli',
    'user-agent': 'claude-cli/2.1.0 (external, cli)',
    'anthropic-beta': 'claude-code-20250219,oauth-2025-04-20',
  };

  /// The request body for a chat turn, shaped for the provider's format and
  /// carrying the preset's [GenParams].
  Object _body(Provider provider, List<ChatMessage> history, GenParams params) {
    final model = provider.model.trim();
    final stop = params.stop.where((s) => s.trim().isNotEmpty).toList();
    if (provider.wire == WireFormat.gemini) {
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
    if (provider.wire == WireFormat.anthropic) {
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
    if (provider.wire == WireFormat.openaiResponses) {
      // The Responses API renames nearly every field: the system prompt is
      // `instructions`, turns are `input` items whose content is a typed list,
      // and the ceiling is `max_output_tokens`. Thinking is an object rather
      // than a flat effort string.
      final system = history
          .where((m) => m.role == 'system')
          .map((m) => m.content)
          .join('\n')
          .trim();
      final input = history
          .where((m) => m.role != 'system')
          .map((m) => {
                'role': m.role,
                'content': [
                  {
                    // The content type is named from the speaker's side; a host
                    // rejects `input_text` on an assistant turn and vice versa.
                    'type':
                        m.role == 'assistant' ? 'output_text' : 'input_text',
                    'text': m.content,
                  }
                ],
              })
          .toList(growable: false);
      return {
        'model': model,
        'stream': params.stream,
        if (system.isNotEmpty) 'instructions': system,
        'input': input,
        if (params.temperature != null) 'temperature': params.temperature,
        if ((params.maxTokens ?? 0) > 0) 'max_output_tokens': params.maxTokens,
        if (params.topP != null && params.topP != 1.0) 'top_p': params.topP,
        if (params.thinking && params.reasoningEffort.isNotEmpty)
          'reasoning': <String, dynamic>{'effort': params.reasoningEffort},
      };
    }
    return {
      'model': model,
      'stream': params.stream,
      // Ask for the token counts, which the chat dialect only sends when told to.
      // Withheld from the local kinds: several OpenAI-compatible servers reject
      // the field, and a rejected request is worse than a missing number.
      if (params.stream && provider.kind.usageReporting)
        'stream_options': <String, dynamic>{'include_usage': true},
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

  /// Whether a header carries a credential and so must never reach the request
  /// preview (which is copyable, and ends up on clipboards and in bug reports).
  ///
  /// Deliberately broad: on top of the three the app itself sends, anything
  /// whose name reads like a secret is redacted, because a user can now add
  /// arbitrary custom headers and a gateway's bespoke auth header should not be
  /// the one thing that leaks.
  static bool _isSecretHeader(String name) {
    final lower = name.toLowerCase();
    return lower == 'authorization' ||
        lower == 'x-api-key' ||
        lower == 'x-goog-api-key' ||
        lower == 'proxy-authorization' ||
        lower == 'cookie' ||
        lower == 'set-cookie' ||
        _secretish.hasMatch(lower);
  }

  /// Names that read like a credential: `x-gateway-token`, `api_secret`, …
  static final RegExp _secretish = RegExp(r'key|token|secret|auth|password');

  /// Token usage out of an OpenAI-shaped `usage` object, covering the field names
  /// the chat and Responses dialects use for the same numbers.
  static TokenUsage? _openAiUsage(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final input = (raw['prompt_tokens'] ?? raw['input_tokens']) as num?;
    final output = (raw['completion_tokens'] ?? raw['output_tokens']) as num?;
    if (input == null && output == null) return null;
    final outputDetails = raw['completion_tokens_details'] ??
        raw['output_tokens_details'];
    final inputDetails =
        raw['prompt_tokens_details'] ?? raw['input_tokens_details'];
    return TokenUsage(
      inputTokens: input?.toInt() ?? 0,
      outputTokens: output?.toInt() ?? 0,
      reasoningTokens: outputDetails is Map<String, dynamic>
          ? (outputDetails['reasoning_tokens'] as num?)?.toInt() ?? 0
          : 0,
      cachedTokens: inputDetails is Map<String, dynamic>
          ? (inputDetails['cached_tokens'] as num?)?.toInt() ?? 0
          : 0,
    );
  }

  /// Token usage out of Gemini's `usageMetadata`. Gemini reports a running total
  /// on every chunk rather than a final tally, so the last one seen wins.
  static TokenUsage? _geminiUsage(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final input = raw['promptTokenCount'] as num?;
    final output = raw['candidatesTokenCount'] as num?;
    final thoughts = raw['thoughtsTokenCount'] as num?;
    if (input == null && output == null) return null;
    return TokenUsage(
      inputTokens: input?.toInt() ?? 0,
      // Thinking is billed as output but reported beside it, not inside it.
      outputTokens: (output?.toInt() ?? 0) + (thoughts?.toInt() ?? 0),
      reasoningTokens: thoughts?.toInt() ?? 0,
      cachedTokens:
          (raw['cachedContentTokenCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// The endpoint a chat turn is POSTed to, by wire format. Gemini puts the
  /// choice between streaming and a single response in the URL (a different
  /// method plus the `alt=sse` transport), where the other formats carry it as a
  /// body field.
  static Uri requestUri(Provider provider, {bool stream = true}) {
    final http = provider.kind.prefersHttp;
    switch (provider.wire) {
      case WireFormat.gemini:
        final uri = endpoint(
          provider.baseUrl,
          '/models/${Uri.encodeComponent(provider.model.trim())}'
              '${stream ? ':streamGenerateContent' : ':generateContent'}',
          preferHttp: http,
        );
        return stream ? uri.replace(queryParameters: {'alt': 'sse'}) : uri;
      case WireFormat.anthropic:
        return endpoint(provider.baseUrl, '/messages', preferHttp: http);
      case WireFormat.openaiResponses:
        return endpoint(provider.baseUrl, '/responses', preferHttp: http);
      case WireFormat.openaiChat:
        return endpoint(provider.baseUrl, '/chat/completions', preferHttp: http);
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
    final anthropic = provider.wire == WireFormat.anthropic;
    final gemini = provider.wire == WireFormat.gemini;
    final responses = provider.wire == WireFormat.openaiResponses;
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
          final delta = event.delta;
          // Yielded before the break: a terminating event can still carry the
          // token counts, and breaking first would throw them away.
          if (delta != null && !delta.isEmpty) yield delta;
          if (event.stop) break;
        } else if (responses) {
          final event = _extractResponsesDelta(payload);
          final delta = event.delta;
          if (delta != null && !delta.isEmpty) yield delta;
          if (event.stop) break;
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
    if (provider.wire != WireFormat.anthropic) return null;
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

  /// The `/embeddings` URL for [baseUrl]. Tolerates a base that already points at
  /// a chat endpoint: a user commonly pastes the full `.../v1/chat/completions`
  /// URL (chat still works because [endpoint] detects that suffix), but naively
  /// appending `/embeddings` to it would 404. So strip a trailing chat suffix
  /// first, then append.
  static Uri embeddingsUri(String baseUrl) {
    var base = baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    for (final suffix in const [
      '/chat/completions',
      '/completions',
      '/messages',
    ]) {
      if (base.endsWith(suffix)) {
        base = base.substring(0, base.length - suffix.length);
        break;
      }
    }
    return endpoint(base, '/embeddings');
  }

  /// Embeds [texts] via an OpenAI-compatible `POST /embeddings` (the wire both
  /// SillyTavern and Agnai use), returning one vector per input in the same
  /// order. Batches the whole list in a single `input` array and realigns the
  /// response by its `index` field. Throws [ChatApiException] on any failure so
  /// the caller can back off on a 429. Not on the streaming send path.
  Future<List<Float32List>> embed(
    Provider provider,
    List<String> texts, {
    required String model,
  }) async {
    if (texts.isEmpty) return const <Float32List>[];
    final name = model.trim();
    if (name.isEmpty) throw ChatApiException('No embedding model is set.');
    final http.Response response;
    try {
      response = await http
          .post(
            embeddingsUri(provider.baseUrl),
            headers: _headers(provider),
            body: jsonEncode({'input': texts, 'model': name}),
          )
          .timeout(const Duration(seconds: 60));
    } catch (e) {
      throw ChatApiException(_describeTransport(e));
    }
    if (response.statusCode != 200) {
      // A 404 on /embeddings usually means this provider has no embeddings
      // endpoint at all, rather than a wrong base URL — say so plainly.
      if (response.statusCode == 404) {
        throw ChatApiException(
          "This provider's embeddings endpoint was not found (HTTP 404). It may "
          'not support embeddings, or the base URL is wrong (it usually ends in '
          '/v1). Try a provider/model that offers embeddings, e.g. OpenAI '
          'text-embedding-3-small.',
        );
      }
      throw ChatApiException(
        _describeFailure(response.statusCode, response.body),
      );
    }
    final decoded = jsonDecode(response.body);
    final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
    if (data is! List) {
      throw ChatApiException('Unexpected /embeddings response from this host.');
    }
    // Pair each embedding with its index, then sort so the order matches [texts]
    // even if the host returns them shuffled.
    final indexed = <MapEntry<int, Float32List>>[];
    for (var i = 0; i < data.length; i++) {
      final row = data[i];
      if (row is! Map) continue;
      final idx = (row['index'] as num?)?.toInt() ?? i;
      final vec = row['embedding'];
      if (vec is! List) continue;
      final floats = Float32List(vec.length);
      for (var j = 0; j < vec.length; j++) {
        floats[j] = (vec[j] as num).toDouble();
      }
      indexed.add(MapEntry(idx, floats));
    }
    indexed.sort((a, b) => a.key.compareTo(b.key));
    return indexed.map((e) => e.value).toList(growable: false);
  }

  /// What [listModels] says when a host answers but names nothing.
  ///
  /// A constant because [testKey] has to tell this apart from a real failure: the
  /// host authenticated the request, which is exactly what a key test is asking
  /// about, and only the model list came back empty.
  static const String noModelsListed = 'This host listed no models.';

  /// Tries one credential against the host and reports what happened.
  ///
  /// Always sends exactly [key] — never the rest of the pool — by narrowing the
  /// provider first, so testing key 3 cannot pass on key 1's authority. `/models`
  /// is the probe because every dialect the app speaks serves it and it is the
  /// cheapest authenticated call available; a host that authenticates but has no
  /// model list still counts as reachable.
  Future<KeyTestResult> testKey(Provider provider, String key) async {
    final trimmed = key.trim();
    if (trimmed.isEmpty) {
      return const KeyTestResult(ok: false, message: 'No key to test.');
    }
    final stopwatch = Stopwatch()..start();
    try {
      final models = await listModels(provider.withActiveKey(trimmed));
      stopwatch.stop();
      return KeyTestResult(
        ok: true,
        status: 200,
        modelCount: models.length,
        latency: stopwatch.elapsed,
        message: models.isEmpty
            ? 'Key accepted, though the host listed no models.'
            : 'Key works — ${models.length} '
                'model${models.length == 1 ? '' : 's'} available.',
      );
    } on ChatApiException catch (e) {
      stopwatch.stop();
      // The host answered and authenticated us; it simply has no list to give.
      // That is a pass for the question being asked here.
      if (e.message == noModelsListed) {
        return KeyTestResult(
          ok: true,
          status: 200,
          modelCount: 0,
          latency: stopwatch.elapsed,
          message: 'Key accepted, though the host listed no models.',
        );
      }
      return KeyTestResult(
        ok: false,
        status: _statusIn(e.message),
        latency: stopwatch.elapsed,
        message: e.message,
      );
    } catch (e) {
      stopwatch.stop();
      return KeyTestResult(
        ok: false,
        latency: stopwatch.elapsed,
        message: _describeTransport(e),
      );
    }
  }

  /// Recovers the status code from a message [_describeFailure] built, so a
  /// rejected key can be told from an unreachable host without changing the
  /// exception type every call site already handles.
  static int? _statusIn(String message) =>
      int.tryParse(RegExp(r'\b(4\d\d|5\d\d)\b').firstMatch(message)?[0] ?? '');

  /// A delta with [usage] attached, when there is any to attach.
  static ChatDelta _withUsage(ChatDelta delta, TokenUsage? usage) =>
      usage == null
          ? delta
          : ChatDelta(
              text: delta.text,
              reasoning: delta.reasoning,
              usage: usage,
            );

  /// Fetches selectable model ids from the provider's `/models` endpoint.
  Future<List<String>> listModels(Provider provider) async {
    final uri = endpoint(
      provider.baseUrl,
      '/models',
      preferHttp: provider.kind.prefersHttp,
    );
    final gemini = provider.wire == WireFormat.gemini;
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
        throw ChatApiException(noModelsListed);
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
      // The usage-bearing chunk arrives with an empty `choices` list, after the
      // last text chunk. It is a delta in its own right, carrying no text.
      if (choices is! List || choices.isEmpty) {
        final usage = _openAiUsage(json['usage']);
        return usage == null ? null : ChatDelta(usage: usage);
      }
      final choice = choices.first;
      if (choice is! Map<String, dynamic>) return null;
      // A host may also attach usage to the final text chunk.
      final usage = _openAiUsage(json['usage']);
      final delta = choice['delta'];
      if (delta is Map<String, dynamic>) {
        return _withUsage(_openAiParts(delta), usage);
      }
      // Some hosts echo non-streaming shapes even when stream is requested.
      final message = choice['message'];
      if (message is Map<String, dynamic>) {
        return _withUsage(_openAiParts(message), usage);
      }
      return usage == null ? null : ChatDelta(usage: usage);
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
      // Gemini repeats a running usage total on every chunk, and sends a final
      // chunk that is usage only.
      final usage = _geminiUsage(json['usageMetadata']);
      if (candidates is! List || candidates.isEmpty) {
        return usage == null ? null : ChatDelta(usage: usage);
      }
      final first = candidates.first;
      if (first is! Map<String, dynamic>) return null;
      final parts = _geminiParts(first['content']);
      if (parts == null) return usage == null ? null : ChatDelta(usage: usage);
      return _withUsage(parts, usage);
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
      // Anthropic splits usage across the stream: the input count arrives with
      // `message_start`, the output count with `message_delta` at the end.
      if (type == 'message_start') {
        final message = json['message'];
        final usage = message is Map<String, dynamic>
            ? _openAiUsage(message['usage'])
            : null;
        return (
          delta: usage == null ? null : ChatDelta(usage: usage),
          stop: false,
        );
      }
      if (type == 'message_delta') {
        final usage = _openAiUsage(json['usage']);
        return (
          delta: usage == null ? null : ChatDelta(usage: usage),
          stop: false,
        );
      }
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

  /// One event from the Responses API stream. Unlike the chat dialect every
  /// event is typed, so text, thinking, completion and failure are told apart by
  /// name rather than by which field happens to be present.
  static ({ChatDelta? delta, bool stop}) _extractResponsesDelta(String payload) {
    try {
      final json = jsonDecode(payload);
      if (json is! Map<String, dynamic>) return (delta: null, stop: false);
      final type = json['type'];
      if (type == 'error' || type == 'response.failed') {
        throw ChatApiException(_describeErrorBody(json));
      }
      if (type == 'response.completed' || type == 'response.incomplete') {
        final response = json['response'];
        final usage = response is Map<String, dynamic>
            ? _openAiUsage(response['usage'])
            : null;
        return (
          delta: usage == null ? null : ChatDelta(usage: usage),
          stop: true,
        );
      }
      if (type == 'response.output_text.delta' && json['delta'] is String) {
        return (
          delta: ChatDelta(text: json['delta'] as String),
          stop: false,
        );
      }
      // Reasoning summaries are the only thinking the API exposes; the raw
      // chain is never sent.
      if ((type == 'response.reasoning_summary_text.delta' ||
              type == 'response.reasoning_text.delta') &&
          json['delta'] is String) {
        return (
          delta: ChatDelta(reasoning: json['delta'] as String),
          stop: false,
        );
      }
      return (delta: null, stop: false);
    } on ChatApiException {
      rethrow;
    } catch (_) {
      return (delta: null, stop: false);
    }
  }

  /// A non-streamed Responses body. The reply lives in `output`, a list of
  /// items whose `message` entries hold the `output_text` parts.
  static ChatDelta _responsesWhole(Map<String, dynamic> json) {
    // Hosts that implement the convenience field make this trivial.
    if (json['output_text'] is String) {
      return ChatDelta(text: json['output_text'] as String);
    }
    final output = json['output'];
    if (output is! List) return const ChatDelta();
    final text = StringBuffer();
    final thoughts = StringBuffer();
    for (final item in output) {
      if (item is! Map<String, dynamic>) continue;
      final content = item['content'];
      if (content is! List) continue;
      final isReasoning = item['type'] == 'reasoning';
      for (final part in content) {
        if (part is! Map<String, dynamic>) continue;
        final value = part['text'];
        if (value is! String) continue;
        (isReasoning ? thoughts : text).write(value);
      }
    }
    return ChatDelta(text: text.toString(), reasoning: thoughts.toString());
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
    switch (provider.wire) {
      case WireFormat.gemini:
        final candidates = json['candidates'];
        if (candidates is List && candidates.isNotEmpty) {
          final first = candidates.first;
          if (first is Map<String, dynamic>) {
            final parts = _geminiParts(first['content']);
            if (parts != null) return parts;
          }
        }
        return const ChatDelta();
      case WireFormat.anthropic:
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
      case WireFormat.openaiResponses:
        return _responsesWhole(json);
      case WireFormat.openaiChat:
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
