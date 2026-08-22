import 'dart:async';

import '../models/message.dart';
import '../models/provider.dart';
import 'chat_client.dart';

/// One condense request: the transcript to summarise plus the message range it
/// covers (indices into `Conversation.messages`, start inclusive/end exclusive).
class SummaryRequest {
  SummaryRequest({
    required this.startIndex,
    required this.endIndex,
    required this.transcript,
  });

  final int startIndex;
  final int endIndex;
  final String transcript;
}

/// The result of a condense request; [text] is empty when it failed.
class SummaryResult {
  SummaryResult({
    required this.startIndex,
    required this.endIndex,
    required this.text,
    this.error,
  });

  final int startIndex;
  final int endIndex;
  final String text;
  final String? error;

  bool get ok => text.trim().isNotEmpty;
}

/// Runs chat summarisation as one-shot (non-streaming) completions, several at a
/// time. Kept entirely separate from the chat's own streaming [ChatClient] so
/// summaries run in the background without disturbing — or being cancelled by —
/// a live send: each request gets its own client, and nothing here touches the
/// app's `_streaming`/`stop()` machinery.
class Summarizer {
  Summarizer({
    this.maxConcurrent = 3,
    this.maxRetries = 2,
    ChatClient Function()? clientFactory,
  }) : _newClient = clientFactory ?? (() => ChatClient());

  /// How many condense requests may be in flight at once. Higher throughput at
  /// the cost of more RPM against the provider.
  final int maxConcurrent;

  /// Retries per request on an HTTP 429 (rate limit), with exponential backoff.
  final int maxRetries;

  final ChatClient Function() _newClient;

  /// Runs every request in [requests] (capped at [maxConcurrent] concurrently)
  /// and returns their results in the same order. A request that fails after
  /// retries yields an empty [SummaryResult.text].
  Future<List<SummaryResult>> run({
    required Provider provider,
    required String systemPrompt,
    required int maxTokens,
    required List<SummaryRequest> requests,
  }) async {
    if (requests.isEmpty) return const <SummaryResult>[];
    final results = List<SummaryResult?>.filled(requests.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= requests.length) return;
        results[i] = await _one(provider, systemPrompt, maxTokens, requests[i]);
      }
    }

    final workers = <Future<void>>[
      for (var w = 0; w < maxConcurrent && w < requests.length; w++) worker(),
    ];
    await Future.wait(workers);
    return results.map((r) => r!).toList(growable: false);
  }

  Future<SummaryResult> _one(
    Provider provider,
    String systemPrompt,
    int maxTokens,
    SummaryRequest req,
  ) async {
    final messages = <ChatMessage>[
      ChatMessage(role: 'system', content: systemPrompt),
      ChatMessage(role: 'user', content: req.transcript),
    ];
    for (var attempt = 0;; attempt++) {
      final client = _newClient();
      final buf = StringBuffer();
      final reasoning = StringBuffer();
      try {
        // Stream, like the chat itself does. A non-streaming round trip failed
        // silently on providers/gateways that only support SSE (the summary came
        // back empty), so mirror the path we already know works for this device.
        await for (final d in client.streamChat(
          provider: provider,
          history: messages,
          params: GenParams(maxTokens: maxTokens, temperature: 0.3),
        )) {
          if (d.text.isNotEmpty) buf.write(d.text);
          if (d.reasoning.isNotEmpty) reasoning.write(d.reasoning);
        }
        // Prefer the answer; if a reasoning-only model returned no answer text,
        // fall back to its thinking so the summary is never silently empty.
        final text = buf.toString().trim().isNotEmpty
            ? buf.toString().trim()
            : reasoning.toString().trim();
        return SummaryResult(
          startIndex: req.startIndex,
          endIndex: req.endIndex,
          text: text,
        );
      } on ChatApiException catch (e) {
        final rateLimited = e.message.contains('429') ||
            e.message.toLowerCase().contains('rate limit');
        if (rateLimited && attempt < maxRetries) {
          await Future<void>.delayed(
              Duration(milliseconds: 800 * (1 << attempt)));
          continue;
        }
        return SummaryResult(
          startIndex: req.startIndex,
          endIndex: req.endIndex,
          text: '',
          error: e.message,
        );
      } catch (e) {
        return SummaryResult(
          startIndex: req.startIndex,
          endIndex: req.endIndex,
          text: '',
          error: e.toString(),
        );
      } finally {
        client.cancel();
      }
    }
  }
}
