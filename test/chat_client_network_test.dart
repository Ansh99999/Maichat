import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/settings.dart';
import 'package:maichat/services/chat_client.dart';

/// Exercises the real HTTP/SSE path against a loopback server, so parsing and
/// error mapping are covered rather than mocked away.
void main() {
  late HttpServer server;
  late AppSettings settings;
  final requests = <Map<String, dynamic>>[];

  Future<void> serve(
    Future<void> Function(HttpRequest request) handler,
  ) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    settings = AppSettings(
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

    final text = await ChatClient()
        .streamChat(
          settings: settings,
          history: [ChatMessage(role: 'user', content: 'hi')],
        )
        .join();

    expect(text, 'Hello, world');
    expect(requests.single['model'], 'test-model');
    expect(requests.single['stream'], isTrue);
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
          settings: settings,
          history: [ChatMessage(role: 'user', content: 'hi')],
        )
        .drain<void>();

    expect(auth, 'Bearer sk-test');
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
            settings: settings,
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
            settings: settings,
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

    expect(await ChatClient().listModels(settings), ['alpha', 'zeta']);
  });

  test('reports an unreachable host rather than throwing raw socket errors',
      () async {
    await serve((request) async => request.response.close());
    final port = server.port;
    await server.close(force: true);

    await expectLater(
      ChatClient().listModels(
        AppSettings(baseUrl: 'http://127.0.0.1:$port/v1', model: 'm'),
      ),
      throwsA(isA<ChatApiException>()),
    );
  });
}
