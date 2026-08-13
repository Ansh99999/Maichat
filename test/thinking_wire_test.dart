import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';

/// The thinking wire contract, exercised against a loopback server: what each
/// provider format is asked for, what comes back as reasoning rather than text,
/// and what a request looks like with streaming switched off.
void main() {
  late HttpServer server;
  late Provider provider;
  final requests = <Map<String, dynamic>>[];
  final uris = <Uri>[];
  final accepts = <String?>[];

  Future<void> serve(
    Future<void> Function(HttpRequest request) handler, {
    ProviderKind kind = ProviderKind.openai,
    String model = 'test-model',
  }) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    provider = Provider(
      id: 'p',
      name: 'Test',
      kind: kind,
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
      apiKey: 'sk-test',
      model: model,
    );
    server.listen((request) async {
      uris.add(request.uri);
      accepts.add(request.headers.value(HttpHeaders.acceptHeader));
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        requests.add(jsonDecode(body) as Map<String, dynamic>);
      }
      await handler(request);
    });
  }

  /// Collects a whole reply, keeping text and reasoning apart.
  Future<({String text, String reasoning})> run({
    GenParams params = const GenParams(),
  }) async {
    final text = StringBuffer();
    final reasoning = StringBuffer();
    final deltas = ChatClient().streamChat(
      provider: provider,
      history: [ChatMessage(role: 'user', content: 'hi')],
      params: params,
    );
    await for (final delta in deltas) {
      text.write(delta.text);
      reasoning.write(delta.reasoning);
    }
    return (text: text.toString(), reasoning: reasoning.toString());
  }

  Future<void> closeAfter(HttpRequest request, List<String> events) async {
    request.response.headers.contentType = ContentType('text', 'event-stream');
    for (final event in events) {
      request.response.write('data: $event\n\n');
    }
    await request.response.close();
  }

  setUp(() {
    requests.clear();
    uris.clear();
    accepts.clear();
  });
  tearDown(() => server.close(force: true));

  group('requesting thinking', () {
    test('an OpenAI-compatible host is sent reasoning_effort only', () async {
      await serve((r) => closeAfter(r, ['[DONE]']));
      await run(
        params: const GenParams(thinking: true, reasoningEffort: 'medium'),
      );
      expect(requests.single['reasoning_effort'], 'medium');
      // The budget object is not OpenAI's schema, so an unset budget sends none.
      expect(requests.single.containsKey('reasoning'), isFalse);
    });

    test('a budget is sent as the OpenRouter reasoning object', () async {
      await serve((r) => closeAfter(r, ['[DONE]']));
      await run(
        params: const GenParams(
          thinking: true,
          reasoningEffort: 'high',
          thinkingBudget: 4096,
        ),
      );
      expect(requests.single['reasoning'], {
        'max_tokens': 4096,
        'effort': 'high',
      });
    });

    test('thinking off sends nothing about reasoning at all', () async {
      await serve((r) => closeAfter(r, ['[DONE]']));
      await run(params: const GenParams(reasoningEffort: 'high'));
      expect(requests.single.containsKey('reasoning_effort'), isFalse);
      expect(requests.single.containsKey('reasoning'), isFalse);
    });

    test('Anthropic gets an enabled thinking block with a floor of 1024',
        () async {
      await serve(
        kind: ProviderKind.anthropic,
        (r) => closeAfter(r, [jsonEncode({'type': 'message_stop'})]),
      );
      await run(
        params: const GenParams(thinking: true, maxTokens: 300, temperature: 0.7),
      );
      final body = requests.single;
      expect(body['thinking'], {'type': 'enabled', 'budget_tokens': 1024});
      // max_tokens has to leave room for the answer on top of the budget…
      expect(body['max_tokens'], 2048);
      // …and sampling is fixed while thinking, so it is dropped rather than
      // sent and refused.
      expect(body.containsKey('temperature'), isFalse);
    });

    test('Anthropic keeps a response length that already clears the budget',
        () async {
      await serve(
        kind: ProviderKind.anthropic,
        (r) => closeAfter(r, [jsonEncode({'type': 'message_stop'})]),
      );
      await run(
        params: const GenParams(
          thinking: true,
          maxTokens: 8000,
          thinkingBudget: 2000,
        ),
      );
      expect(requests.single['thinking'],
          {'type': 'enabled', 'budget_tokens': 2000});
      expect(requests.single['max_tokens'], 8000);
    });

    test('Gemini gets a thinkingConfig asking for the thoughts back', () async {
      await serve(kind: ProviderKind.gemini, (r) => closeAfter(r, ['[DONE]']));
      await run(params: const GenParams(thinking: true, thinkingBudget: 2048));
      expect(requests.single['generationConfig']['thinkingConfig'], {
        'includeThoughts': true,
        'thinkingBudget': 2048,
      });
    });

    test('Gemini omits the budget when none is set, rather than sending 0',
        () async {
      await serve(kind: ProviderKind.gemini, (r) => closeAfter(r, ['[DONE]']));
      await run(params: const GenParams(thinking: true));
      expect(requests.single['generationConfig']['thinkingConfig'],
          {'includeThoughts': true});
    });
  });

  group('reading thinking back', () {
    test('reasoning_content on an OpenAI-compatible delta is not message text',
        () async {
      await serve((r) => closeAfter(r, [
            jsonEncode({
              'choices': [
                {'delta': {'reasoning_content': 'weighing it up'}},
              ],
            }),
            jsonEncode({
              'choices': [
                {'delta': {'content': 'Hello'}},
              ],
            }),
            '[DONE]',
          ]));
      final reply = await run();
      expect(reply.reasoning, 'weighing it up');
      expect(reply.text, 'Hello');
    });

    test('OpenRouter names the same field reasoning', () async {
      await serve((r) => closeAfter(r, [
            jsonEncode({
              'choices': [
                {'delta': {'reasoning': 'hmm'}},
              ],
            }),
            '[DONE]',
          ]));
      expect((await run()).reasoning, 'hmm');
    });

    test('an Anthropic thinking_delta arrives as reasoning', () async {
      await serve(
        kind: ProviderKind.anthropic,
        (r) => closeAfter(r, [
          jsonEncode({
            'type': 'content_block_delta',
            'delta': {'type': 'thinking_delta', 'thinking': 'let me see'},
          }),
          jsonEncode({
            'type': 'content_block_delta',
            'delta': {'type': 'text_delta', 'text': 'Done.'},
          }),
          jsonEncode({'type': 'message_stop'}),
        ]),
      );
      final reply = await run();
      expect(reply.reasoning, 'let me see');
      expect(reply.text, 'Done.');
    });

    test('a Gemini part flagged as a thought is reasoning', () async {
      await serve(
        kind: ProviderKind.gemini,
        (r) => closeAfter(r, [
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'thinking aloud', 'thought': true},
                    {'text': 'The answer'},
                  ],
                },
              },
            ],
          }),
        ]),
      );
      final reply = await run();
      expect(reply.reasoning, 'thinking aloud');
      expect(reply.text, 'The answer');
    });
  });

  group('streaming switched off', () {
    test('an OpenAI-compatible request says so and reads one JSON body',
        () async {
      await serve((request) async {
        request.response.write(jsonEncode({
          'choices': [
            {
              'message': {
                'content': 'Whole reply',
                'reasoning_content': 'quietly considered',
              },
            },
          ],
        }));
        await request.response.close();
      });

      final reply = await run(params: const GenParams(stream: false));
      expect(requests.single['stream'], isFalse);
      // No SSE was asked for either — this is a plain request/response.
      expect(accepts.single, isNot('text/event-stream'));
      expect(reply.text, 'Whole reply');
      expect(reply.reasoning, 'quietly considered');
    });

    test('Anthropic reads the content blocks, thinking included', () async {
      await serve(
        kind: ProviderKind.anthropic,
        (request) async {
          request.response.write(jsonEncode({
            'content': [
              {'type': 'thinking', 'thinking': 'first I check'},
              {'type': 'text', 'text': 'Then I answer.'},
            ],
          }));
          await request.response.close();
        },
      );

      final reply = await run(params: const GenParams(stream: false));
      expect(requests.single['stream'], isFalse);
      expect(reply.reasoning, 'first I check');
      expect(reply.text, 'Then I answer.');
    });

    test('Gemini switches method and drops the SSE transport', () async {
      await serve(
        kind: ProviderKind.gemini,
        model: 'gemini-2.5-flash',
        (request) async {
          request.response.write(jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'A single answer'},
                  ],
                },
              },
            ],
          }));
          await request.response.close();
        },
      );

      final reply = await run(params: const GenParams(stream: false));
      expect(uris.single.path, endsWith(':generateContent'));
      expect(uris.single.queryParameters.containsKey('alt'), isFalse);
      expect(reply.text, 'A single answer');
    });

    test('streaming on is still the default', () async {
      await serve((r) => closeAfter(r, ['[DONE]']));
      await run();
      expect(requests.single['stream'], isTrue);
    });

    test('an HTTP failure is still reported when not streaming', () async {
      await serve((request) async {
        request.response.statusCode = 429;
        request.response.write(jsonEncode({
          'error': {'message': 'slow down'},
        }));
        await request.response.close();
      });

      await expectLater(
        run(params: const GenParams(stream: false)),
        throwsA(isA<ChatApiException>()
            .having((e) => e.message, 'message', contains('slow down'))),
      );
    });
  });
}
