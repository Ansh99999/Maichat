import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/summarizer.dart';

/// A ChatClient stand-in that replays scripted deltas keyed by the user
/// transcript, so the summarizer can be driven without a network.
class _FakeClient extends ChatClient {
  _FakeClient(this.reply);
  final ChatDelta Function(String transcript) reply;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    final transcript = history.last.content;
    yield reply(transcript);
  }

  @override
  void cancel() {}
}

Provider _p() => Provider(
      id: 'p',
      name: 'P',
      kind: ProviderKind.openai,
      baseUrl: 'https://example.test',
      model: 'gpt-x',
    );

void main() {
  test('maps each request to a result and preserves order', () async {
    final s = Summarizer(
      clientFactory: () => _FakeClient((t) => ChatDelta(text: 'SUM:$t')),
    );
    final results = await s.run(
      provider: _p(),
      systemPrompt: 'condense',
      maxTokens: 256,
      requests: [
        SummaryRequest(startIndex: 0, endIndex: 5, transcript: 'a'),
        SummaryRequest(startIndex: 5, endIndex: 10, transcript: 'b'),
      ],
    );
    expect(results, hasLength(2));
    expect(results[0].text, 'SUM:a');
    expect(results[1].text, 'SUM:b');
    expect(results.every((r) => r.ok), isTrue);
  });

  test('falls back to reasoning when the answer text is empty', () async {
    final s = Summarizer(
      clientFactory: () =>
          _FakeClient((_) => const ChatDelta(reasoning: 'thought-only')),
    );
    final results = await s.run(
      provider: _p(),
      systemPrompt: 'condense',
      maxTokens: 256,
      requests: [SummaryRequest(startIndex: 0, endIndex: 3, transcript: 'x')],
    );
    expect(results.single.text, 'thought-only');
    expect(results.single.ok, isTrue);
  });

  test('a thrown API error yields an empty, non-ok result with the message',
      () async {
    final s = Summarizer(
      clientFactory: () => _ThrowingClient(),
      maxRetries: 0,
    );
    final results = await s.run(
      provider: _p(),
      systemPrompt: 'condense',
      maxTokens: 256,
      requests: [SummaryRequest(startIndex: 0, endIndex: 3, transcript: 'x')],
    );
    expect(results.single.ok, isFalse);
    expect(results.single.error, contains('boom'));
  });
}

class _ThrowingClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    throw ChatApiException('boom');
  }

  @override
  void cancel() {}
}
