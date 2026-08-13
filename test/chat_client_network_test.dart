import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';

/// Exercises the real HTTP/SSE path against a loopback server, so parsing and
/// error mapping are covered rather than mocked away.
/// The visible text of a whole reply, joined — the tests assert on what the chat
/// would show, with any reasoning read separately.
Future<String> textOf(Stream<ChatDelta> stream) async {
  final out = StringBuffer();
  await for (final delta in stream) {
    out.write(delta.text);
  }
  return out.toString();
}

/// Every reasoning chunk of a reply, joined.
Future<String> reasoningOf(Stream<ChatDelta> stream) async {
  final out = StringBuffer();
  await for (final delta in stream) {
    out.write(delta.reasoning);
  }
  return out.toString();
}

void main() {
  late HttpServer server;
  late Provider provider;
  final requests = <Map<String, dynamic>>[];

  Future<void> serve(
    Future<void> Function(HttpRequest request) handler, {
    ProviderKind kind = ProviderKind.openai,
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = Provider(
      id: 'p',
      name: 'Test',
      kind: kind,
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'sk-test',
      model: 'test-model',
    );
    server.listen((request) async {
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        requests.add(jsonDecode(body) as Map<String, dynamic>);
      }
      await handler(request);
    });
  }

  setUp(requests.clear);
  tearDown(() => server.close(force: true));

  test('parses SSE deltas and stops at [DONE]', () async {
    await serve((request) async {
      request.response.headers.contentType =
          ContentType('text', 'event-stream');
      void chunk(String content) => request.response.write(
            'data: ${jsonEncode({
                  'choices': [
                    {'delta': {'content': content}},
                  ],
                })}\n\n',
          );
      chunk('Hello');
      chunk(', ');
      request.response.write(': keep-alive\n\n');
      request.response.write('data: \n\n');
      chunk('world');
      request.response.write('data: [DONE]\n\n');
      // Anything after [DONE] must be ignored.
      chunk(' ignored');
      await request.response.close();
    });

    final text = await textOf(
      ChatClient().streamChat(
        provider: provider,
        history: [ChatMessage(role: 'user', content: 'hi')],
      ),
    );

    expect(text, 'Hello, world');
    expect(requests.single['model'], 'test-model');
    expect(requests.single['stream'], isTrue);
    expect(requests.single.containsKey('max_tokens'), isFalse);
    expect(requests.single['messages'], [
      {'role': 'user', 'content': 'hi'},
    ]);
  });

  test('sends the API key as a bearer token', () async {
    String? auth;
    await serve((request) async {
      auth = request.headers.value(HttpHeaders.authorizationHeader);
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });

    await ChatClient()
        .streamChat(
          provider: provider,
          history: [ChatMessage(role: 'user', content: 'hi')],
        )
        .drain<void>();

    expect(auth, 'Bearer sk-test');
  });

  test('parses Anthropic content_block_delta events and stops at message_stop',
      () async {
    await serve(
      kind: ProviderKind.anthropic,
      (request) async {
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        void event(String type, Map<String, dynamic> body) => request.response
            .write('event: $type\ndata: ${jsonEncode(body)}\n\n');
        event('content_block_delta', {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'Hel'},
        });
        event('content_block_delta', {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'lo'},
        });
        event('message_stop', {'type': 'message_stop'});
        // Anything after message_stop must be ignored.
        event('content_block_delta', {
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': ' ignored'},
        });
        await request.response.close();
      },
    );

    final text = await textOf(
      ChatClient().streamChat(
        provider: provider,
        history: [ChatMessage(role: 'user', content: 'hi')],
      ),
    );

    expect(text, 'Hello');
    expect(requests.single['model'], 'test-model');
    expect(requests.single['max_tokens'], 4096);
    expect(requests.single['stream'], isTrue);
    expect(requests.single['messages'], [
      {'role': 'user', 'content': 'hi'},
    ]);
  });

  test('Anthropic sends x-api-key and a version header, not a bearer',
      () async {
    String? key;
    String? version;
    String? auth;
    await serve(
      kind: ProviderKind.anthropic,
      (request) async {
        key = request.headers.value('x-api-key');
        version = request.headers.value('anthropic-version');
        auth = request.headers.value(HttpHeaders.authorizationHeader);
        request.response
            .write('data: ${jsonEncode({'type': 'message_stop'})}\n\n');
        await request.response.close();
      },
    );

    await ChatClient()
        .streamChat(
          provider: provider,
          history: [ChatMessage(role: 'user', content: 'hi')],
        )
        .drain<void>();

    expect(key, 'sk-test');
    expect(version, '2023-06-01');
    expect(auth, isNull);
  });

  test('surfaces an Anthropic error event', () async {
    await serve(
      kind: ProviderKind.anthropic,
      (request) async {
        request.response.write(
          'data: ${jsonEncode({
                'type': 'error',
                'error': {'message': 'overloaded'},
              })}\n\n',
        );
        await request.response.close();
      },
    );

    await expectLater(
      ChatClient()
          .streamChat(
            provider: provider,
            history: [ChatMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<ChatApiException>()
            .having((e) => e.message, 'message', contains('overloaded')),
      ),
    );
  });

  test('maps a 401 to an actionable message including the host detail',
      () async {
    await serve((request) async {
      request.response.statusCode = 401;
      request.response.write(
        jsonEncode({'error': {'message': 'Incorrect API key provided'}}),
      );
      await request.response.close();
    });

    await expectLater(
      ChatClient()
          .streamChat(
            provider: provider,
            history: [ChatMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<ChatApiException>().having(
          (e) => e.message,
          'message',
          allOf(contains('API key'), contains('Incorrect API key provided')),
        ),
      ),
    );
  });

  test('surfaces an error delivered inside the stream', () async {
    await serve((request) async {
      request.response.write(
        'data: ${jsonEncode({'error': {'message': 'quota exceeded'}})}\n\n',
      );
      await request.response.close();
    });

    await expectLater(
      ChatClient()
          .streamChat(
            provider: provider,
            history: [ChatMessage(role: 'user', content: 'hi')],
          )
          .drain<void>(),
      throwsA(
        isA<ChatApiException>()
            .having((e) => e.message, 'message', contains('quota exceeded')),
      ),
    );
  });

  test('lists model ids in sorted order', () async {
    await serve((request) async {
      request.response.write(
        jsonEncode({
          'data': [
            {'id': 'zeta'},
            {'id': 'alpha'},
            {'id': 'alpha'},
          ],
        }),
      );
      await request.response.close();
    });

    expect(await ChatClient().listModels(provider), ['alpha', 'zeta']);
  });

  test('parses Gemini streamGenerateContent SSE deltas', () async {
    await serve(
      kind: ProviderKind.gemini,
      (request) async {
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        void chunk(String text) => request.response.write(
              'data: ${jsonEncode({
                    'candidates': [
                      {
                        'content': {
                          'parts': [
                            {'text': text},
                          ],
                        },
                      },
                    ],
                  })}\n\n',
            );
        chunk('Hel');
        chunk('lo');
        await request.response.close();
      },
    );

    final text = await textOf(
      ChatClient().streamChat(
        provider: provider,
        history: [ChatMessage(role: 'user', content: 'hi')],
      ),
    );

    expect(text, 'Hello');
    // Gemini names the assistant role "model" and wraps text in parts.
    expect(requests.single['contents'], [
      {
        'role': 'user',
        'parts': [
          {'text': 'hi'},
        ],
      },
    ]);
  });

  test('Gemini authenticates with x-goog-api-key, not a bearer', () async {
    String? key;
    String? auth;
    await serve(
      kind: ProviderKind.gemini,
      (request) async {
        key = request.headers.value('x-goog-api-key');
        auth = request.headers.value(HttpHeaders.authorizationHeader);
        await request.response.close();
      },
    );

    await ChatClient()
        .streamChat(
          provider: provider,
          history: [ChatMessage(role: 'user', content: 'hi')],
        )
        .drain<void>();

    expect(key, 'sk-test');
    expect(auth, isNull);
  });

  test('lists Gemini model ids without the models/ prefix', () async {
    await serve(
      kind: ProviderKind.gemini,
      (request) async {
        request.response.write(
          jsonEncode({
            'models': [
              {'name': 'models/gemini-2.5-flash'},
              {'name': 'models/gemini-1.5-pro'},
            ],
          }),
        );
        await request.response.close();
      },
    );

    expect(
      await ChatClient().listModels(provider),
      ['gemini-1.5-pro', 'gemini-2.5-flash'],
    );
  });

  test('reports an unreachable host rather than throwing raw socket errors',
      () async {
    await serve((request) async => request.response.close());
    final dead = provider;
    await server.close(force: true);

    await expectLater(
      ChatClient().listModels(dead),
      throwsA(isA<ChatApiException>()),
    );
  });
}
