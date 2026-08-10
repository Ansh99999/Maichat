import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/message.dart';
import '../models/settings.dart';

/// Raised for anything the user can act on: bad key, bad URL, dead host.
class ChatApiException implements Exception {
  ChatApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Minimal client for the OpenAI-compatible `/chat/completions` and `/models`
/// endpoints. Streaming is done over server-sent events.
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

  Map<String, String> _headers(AppSettings settings, {bool stream = false}) => {
        'Content-Type': 'application/json',
        if (settings.apiKey.trim().isNotEmpty)
          'Authorization': 'Bearer ${settings.apiKey.trim()}',
        if (stream) 'Accept': 'text/event-stream',
      };

  /// Streams assistant text deltas for [history] until the model stops.
  Stream<String> streamChat({
    required AppSettings settings,
    required List<ChatMessage> history,
  }) async* {
    if (settings.model.trim().isEmpty) {
      throw ChatApiException('Pick a model in Settings first.');
    }
    final uri = endpoint(settings.baseUrl, '/chat/completions');
    final client = http.Client();
    _active = client;
    try {
      final request = http.Request('POST', uri)
        ..headers.addAll(_headers(settings, stream: true))
        ..body = jsonEncode({
          'model': settings.model.trim(),
          'stream': true,
          'messages':
              history.map((m) => m.toApi()).toList(growable: false),
        });

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
        if (payload == '[DONE]') break;
        final delta = _extractDelta(payload);
        if (delta != null && delta.isNotEmpty) yield delta;
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

  /// Fetches selectable model ids from `/models`.
  Future<List<String>> listModels(AppSettings settings) async {
    final uri = endpoint(settings.baseUrl, '/models');
    try {
      final response =
          await http.get(uri, headers: _headers(settings)).timeout(
                const Duration(seconds: 30),
              );
      if (response.statusCode != 200) {
        throw ChatApiException(
          _describeFailure(response.statusCode, response.body),
        );
      }
      final decoded = jsonDecode(response.body);
      final data = decoded is Map<String, dynamic>
          ? decoded['data']
          : (decoded is List ? decoded : null);
      if (data is! List) {
        throw ChatApiException('Unexpected /models response from this host.');
      }
      final ids = <String>{};
      for (final entry in data) {
        final id = entry is Map<String, dynamic>
            ? entry['id'] as String?
            : (entry is String ? entry : null);
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
