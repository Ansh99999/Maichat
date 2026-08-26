import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/usage.dart';
import 'package:maichat/services/chat_client.dart';

/// Token usage is the one number in a reply the user is billed for, so it is
/// read off the wire for every dialect rather than estimated. These tests pin
/// each dialect's shape against a loopback server.
void main() {
  late HttpServer server;
  final requests = <Map<String, dynamic>>[];

  /// The last usage the stream reported — what AppState records.
  Future<TokenUsage?> usageOf(Stream<ChatDelta> stream) async {
    TokenUsage? last;
    await for (final delta in stream) {
      if (delta.usage != null) last = delta.usage;
    }
    return last;
  }

  Future<Provider> serveSse(
    List<String> events, {
    ProviderKind kind = ProviderKind.openai,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        requests.add(jsonDecode(body) as Map<String, dynamic>);
      }
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      for (final event in events) {
        request.response.write('data: $event\n\n');
      }
      await request.response.close();
    });
    return Provider(
      id: 'p',
      name: 'Test',
      kind: kind,
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );
  }

  setUp(requests.clear);
  tearDown(() => server.close(force: true));

  test('the chat dialect asks for usage, and reads the final chunk', () async {
    final provider = await serveSse(<String>[
      jsonEncode({
        'choices': [
          {'delta': {'content': 'hi'}}
        ],
      }),
      jsonEncode({
        'choices': <dynamic>[],
        'usage': {
          'prompt_tokens': 1200,
          'completion_tokens': 340,
          'completion_tokens_details': {'reasoning_tokens': 100},
          'prompt_tokens_details': {'cached_tokens': 900},
        },
      }),
      '[DONE]',
    ]);

    final usage = await usageOf(ChatClient().streamChat(
      provider: provider,
      history: <ChatMessage>[ChatMessage(role: 'user', content: 'hello')],
    ));

    expect(requests.single['stream_options'],
        <String, dynamic>{'include_usage': true});
    expect(usage, isNotNull);
    expect(usage!.inputTokens, 1200);
    expect(usage.outputTokens, 340);
    expect(usage.reasoningTokens, 100);
    expect(usage.cachedTokens, 900);
    expect(usage.estimated, isFalse);
  });

  test('a local host is never asked for usage', () async {
    final provider = await serveSse(
      <String>[
        jsonEncode({
          'choices': [
            {'delta': {'content': 'hi'}}
          ],
        }),
        '[DONE]',
      ],
      kind: ProviderKind.localLlm,
    );

    await usageOf(ChatClient().streamChat(
      provider: provider,
      history: <ChatMessage>[ChatMessage(role: 'user', content: 'hello')],
    ));

    // Several OpenAI-compatible servers reject the field outright, so it must not
    // be sent to them at all.
    expect(requests.single.containsKey('stream_options'), isFalse);
  });

  test('Anthropic splits usage across the start and the end', () async {
    final provider = await serveSse(
      <String>[
        jsonEncode({
          'type': 'message_start',
          'message': {
            'usage': {'input_tokens': 2048, 'output_tokens': 1},
          },
        }),
        jsonEncode({
          'type': 'content_block_delta',
          'delta': {'text': 'hello'},
        }),
        jsonEncode({
          'type': 'message_delta',
          'usage': {'output_tokens': 512},
        }),
        jsonEncode({'type': 'message_stop'}),
      ],
      kind: ProviderKind.anthropic,
    );

    final usage = await usageOf(ChatClient().streamChat(
      provider: provider,
      history: <ChatMessage>[ChatMessage(role: 'user', content: 'hello')],
    ));

    // message_delta carries only the output count, and it is the last word.
    expect(usage!.outputTokens, 512);
  });

  test('Gemini reports a running total; the newest wins', () async {
    final provider = await serveSse(
      <String>[
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'hel'}
                ],
              },
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 100,
            'candidatesTokenCount': 3,
          },
        }),
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'lo'}
                ],
              },
            }
          ],
          'usageMetadata': {
            'promptTokenCount': 100,
            'candidatesTokenCount': 5,
            'thoughtsTokenCount': 40,
          },
        }),
      ],
      kind: ProviderKind.gemini,
    );

    final usage = await usageOf(ChatClient().streamChat(
      provider: provider,
      history: <ChatMessage>[ChatMessage(role: 'user', content: 'hello')],
    ));

    expect(usage!.inputTokens, 100);
    // Gemini reports thinking beside the output count, not inside it, and it is
    // billed as output — so the two are added.
    expect(usage.outputTokens, 45);
    expect(usage.reasoningTokens, 40);
  });

  test('the Responses dialect reads usage off the completion event', () async {
    final provider = await serveSse(
      <String>[
        jsonEncode({
          'type': 'response.output_text.delta',
          'delta': 'hello',
        }),
        jsonEncode({
          'type': 'response.completed',
          'response': {
            'usage': {'input_tokens': 900, 'output_tokens': 120},
          },
        }),
      ],
      kind: ProviderKind.openaiResponses,
    );

    final client = ChatClient();
    final text = StringBuffer();
    TokenUsage? usage;
    await for (final delta in client.streamChat(
      provider: provider,
      history: <ChatMessage>[ChatMessage(role: 'user', content: 'hello')],
    )) {
      text.write(delta.text);
      if (delta.usage != null) usage = delta.usage;
    }

    expect(text.toString(), 'hello');
    expect(usage!.inputTokens, 900);
    expect(usage.outputTokens, 120);
    // The system prompt travels as `instructions`, and turns as `input` items.
    expect(requests.single.containsKey('input'), isTrue);
    expect(requests.single.containsKey('messages'), isFalse);
  });

  test('a reply with no usage at all reports none, rather than zeros', () async {
    final provider = await serveSse(<String>[
      jsonEncode({
        'choices': [
          {'delta': {'content': 'hi'}}
        ],
      }),
      '[DONE]',
    ]);

    final usage = await usageOf(ChatClient().streamChat(
      provider: provider,
      history: <ChatMessage>[ChatMessage(role: 'user', content: 'hello')],
    ));

    // Null is what tells AppState to fall back to an estimate and label it.
    expect(usage, isNull);
  });
}
