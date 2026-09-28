import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/agent_client.dart';
import 'package:maichat/services/chat_client.dart';

/// The Studio's tool-calling wire, asserted on the bytes that leave the app and
/// the events a real host sends back — one loopback server per test, speaking
/// each dialect's own SSE.
void main() {
  late HttpServer server;
  Map<String, dynamic>? captured;
  Uri? capturedUri;

  /// Starts a server that records the request and answers with [events], each
  /// sent as one `data:` line (Anthropic's `event:` lines are left out; the
  /// client reads only `data:`).
  Future<void> serve(List<Object> events, {int status = 200}) async {
    captured = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      capturedUri = request.uri;
      captured = jsonDecode(await utf8.decoder.bind(request).join())
          as Map<String, dynamic>;
      request.response.statusCode = status;
      if (status != 200) {
        request.response.write(jsonEncode(events.single));
      } else {
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        for (final e in events) {
          request.response.write(
            'data: ${e is String ? e : jsonEncode(e)}\n\n',
          );
        }
      }
      await request.response.close();
    });
  }

  tearDown(() => server.close(force: true));

  Provider provider(ProviderKind kind) => Provider(
        id: 'p',
        name: 'test',
        kind: kind,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'm',
        apiKey: 'k',
      );

  const setField = ToolSpec(
    name: 'set_field',
    description: 'Sets a field.',
    parameters: {
      'type': 'object',
      'properties': {
        'field': {'type': 'string'},
        'value': {'type': 'string'},
      },
      'required': ['field', 'value'],
    },
  );
  const getDraft = ToolSpec(name: 'get_draft', description: 'Reads it.');

  /// A history with one round of tool use already in it, so every test also
  /// pins how a dialect is sent a call and its result.
  List<AgentMessage> history({String? signature, bool synthetic = false}) {
    final call = ToolCall(
      id: 'call_1',
      name: 'set_field',
      arguments: const {'field': 'name', 'value': 'Aria'},
      signature: signature,
      syntheticId: synthetic,
    );
    return [
      AgentMessage.system('You build characters.'),
      AgentMessage.user('Make a lighthouse keeper.'),
      AgentMessage(
        role: AgentRole.assistant,
        text: 'Naming her first.',
        toolCalls: [call],
      ),
      AgentMessage.toolResult(call, 'ok'),
      AgentMessage.user('Make her older.'),
    ];
  }

  Future<List<AgentDelta>> run(
    ProviderKind kind, {
    List<AgentMessage>? messages,
    bool stream = true,
  }) =>
      AgentClient()
          .stream(
            provider: provider(kind),
            messages: messages ?? history(),
            tools: const [setField, getDraft],
            params: AgentParams(stream: stream),
          )
          .toList();

  String textOf(List<AgentDelta> deltas) => deltas.map((d) => d.text).join();
  List<ToolCall> callsOf(List<AgentDelta> deltas) =>
      [for (final d in deltas) ...d.toolCalls];

  group('OpenAI chat/completions', () {
    test('sends tools, the call and its result in OpenAI shape', () async {
      await serve(['[DONE]']);
      await run(ProviderKind.openai);
      expect(capturedUri!.path, '/v1/chat/completions');
      final messages = (captured!['messages'] as List).cast<Map>();
      expect(messages.map((m) => m['role']),
          ['system', 'user', 'assistant', 'tool', 'user']);
      expect(messages[0]['content'], 'You build characters.');
      final call = (messages[2]['tool_calls'] as List).single as Map;
      expect(call['id'], 'call_1');
      expect(call['type'], 'function');
      expect(call['function']['name'], 'set_field');
      expect(jsonDecode(call['function']['arguments'] as String),
          {'field': 'name', 'value': 'Aria'});
      expect(messages[3], {
        'role': 'tool',
        'tool_call_id': 'call_1',
        'content': 'ok',
      });
      final tools = (captured!['tools'] as List).cast<Map>();
      expect(tools.map((t) => t['function']['name']), ['set_field', 'get_draft']);
      expect(tools.first['type'], 'function');
      expect(tools.first['function']['parameters']['required'],
          ['field', 'value']);
    });

    test('a turn that only calls tools sends null content, not ""', () async {
      await serve(['[DONE]']);
      await run(ProviderKind.openai, messages: [
        AgentMessage.user('go'),
        AgentMessage(
          role: AgentRole.assistant,
          toolCalls: const [ToolCall(id: 'c', name: 'get_draft')],
        ),
      ]);
      final assistant = (captured!['messages'] as List)[1] as Map;
      expect(assistant.containsKey('content'), isTrue);
      expect(assistant['content'], isNull);
    });

    test('stitches two parallel calls streamed in pieces', () async {
      Map<String, dynamic> chunk(Map<String, dynamic> delta) => {
            'choices': [
              {'delta': delta},
            ],
          };
      await serve([
        chunk({'content': 'On it. '}),
        chunk({
          'tool_calls': [
            {
              'index': 0,
              'id': 'a',
              'type': 'function',
              'function': {'name': 'set_field', 'arguments': '{"field":'},
            },
          ],
        }),
        chunk({
          'tool_calls': [
            {
              'index': 0,
              'function': {'arguments': '"name","value":"Aria"}'},
            },
            {
              'index': 1,
              'id': 'b',
              'function': {'name': 'get_draft', 'arguments': ''},
            },
          ],
        }),
        {
          'choices': <Object>[],
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
        },
        '[DONE]',
      ]);
      final deltas = await run(ProviderKind.openai);
      expect(textOf(deltas), 'On it. ');
      final calls = callsOf(deltas);
      expect(calls.map((c) => c.id), ['a', 'b']);
      expect(calls[0].arguments, {'field': 'name', 'value': 'Aria'});
      expect(calls[1].name, 'get_draft');
      expect(calls[1].arguments, isEmpty);
      expect(calls.every((c) => c.argumentError == null), isTrue);
      expect(deltas.firstWhere((d) => d.usage != null).usage!.inputTokens, 10);
      // Calls come out once, whole, after the text.
      expect(deltas.indexWhere((d) => d.toolCalls.isNotEmpty),
          deltas.length - 1);
    });

    test('a gateway that omits `index` still yields separate calls', () async {
      await serve([
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'id': 'x',
                    'function': {'name': 'get_draft', 'arguments': '{}'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'id': 'y',
                    'function': {
                      'name': 'set_field',
                      'arguments': '{"field":"tags","value":"a"}',
                    },
                  },
                ],
              },
            },
          ],
        },
        '[DONE]',
      ]);
      final calls = callsOf(await run(ProviderKind.openai));
      expect(calls.map((c) => c.id), ['x', 'y']);
      expect(calls[1].arguments['field'], 'tags');
    });

    test('parallel calls that each restart `index` at 0 stay separate',
        () async {
      // The shape AIClient2API's Gemini converter sends: every chunk numbers
      // its own calls from 0, so two delegate calls in two chunks both say 0.
      Map<String, dynamic> chunk(String id, String task) => {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'id': id,
                      'type': 'function',
                      'function': {
                        'name': 'delegate',
                        'arguments': jsonEncode({'helper': 'writer', 'task': task}),
                      },
                    },
                  ],
                },
              },
            ],
          };
      await serve([chunk('a', 'greetings'), chunk('b', 'lore'), '[DONE]']);
      final calls = callsOf(await run(ProviderKind.openai));
      expect(calls.map((c) => c.id), ['a', 'b']);
      expect(calls.map((c) => c.arguments['task']), ['greetings', 'lore']);
      expect(calls.every((c) => c.argumentError == null), isTrue);
    });

    test('same tool, no ids, reused index: a new object is a new call',
        () async {
      Map<String, dynamic> chunk(String task) => {
            'choices': [
              {
                'delta': {
                  'tool_calls': [
                    {
                      'index': 0,
                      'function': {
                        'name': 'delegate',
                        'arguments': jsonEncode({'helper': 'critic', 'task': task}),
                      },
                    },
                  ],
                },
              },
            ],
          };
      await serve([chunk('one'), chunk('two'), chunk('three'), '[DONE]']);
      final calls = callsOf(await run(ProviderKind.openai));
      expect(calls.map((c) => c.arguments['task']), ['one', 'two', 'three']);
      expect(calls.map((c) => c.id).toSet(), hasLength(3));
    });

    test('broken argument JSON becomes an error on the call', () async {
      await serve([
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'a',
                    'function': {'name': 'set_field', 'arguments': '{"field":'},
                  },
                ],
              },
            },
          ],
        },
        '[DONE]',
      ]);
      final call = callsOf(await run(ProviderKind.openai)).single;
      expect(call.argumentError, contains('not valid JSON'));
      expect(call.arguments, isEmpty);
    });

    test('a refused request reads like a chat failure', () async {
      await serve([
        {
          'error': {'message': 'tools are not supported by this model'},
        },
      ], status: 400);
      await expectLater(
        run(ProviderKind.openai),
        throwsA(isA<ChatApiException>().having(
          (e) => e.message,
          'message',
          allOf(contains('HTTP 400'), contains('tools are not supported')),
        )),
      );
    });

    test('non-streamed reply carries its calls', () {
      final delta = AgentClient.parseWhole(
        WireFormat.openaiChat,
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': null,
                'tool_calls': [
                  {
                    'id': 'a',
                    'type': 'function',
                    'function': {
                      'name': 'set_field',
                      'arguments': '{"field":"name","value":"Aria"}',
                    },
                  },
                ],
              },
            },
          ],
        }),
      );
      expect(delta.text, '');
      expect(delta.toolCalls.single.arguments['value'], 'Aria');
    });
  });

  group('OpenAI responses', () {
    test('sends function_call and function_call_output items', () async {
      await serve([
        {'type': 'response.completed', 'response': <String, dynamic>{}},
      ]);
      await run(ProviderKind.openaiResponses);
      expect(capturedUri!.path, '/v1/responses');
      expect(captured!['instructions'], 'You build characters.');
      final input = (captured!['input'] as List).cast<Map>();
      expect(input[0]['role'], 'user');
      expect(input[1]['role'], 'assistant');
      expect(input[1]['content'][0]['type'], 'output_text');
      expect(input[2]['type'], 'function_call');
      expect(input[2]['call_id'], 'call_1');
      expect(input[2].containsKey('id'), isFalse);
      expect(jsonDecode(input[2]['arguments'] as String)['value'], 'Aria');
      expect(input[3], {
        'type': 'function_call_output',
        'call_id': 'call_1',
        'output': 'ok',
      });
      expect(input[4]['content'][0]['type'], 'input_text');
      final tools = (captured!['tools'] as List).cast<Map>();
      expect(tools.first['type'], 'function');
      expect(tools.first['name'], 'set_field');
      expect(tools.first['parameters']['type'], 'object');
    });

    test('reads a call from its item and argument events', () async {
      await serve([
        {'type': 'response.output_text.delta', 'delta': 'Sure.'},
        {
          'type': 'response.output_item.added',
          'output_index': 1,
          'item': {
            'type': 'function_call',
            'id': 'fc_1',
            'call_id': 'call_9',
            'name': 'set_field',
            'arguments': '',
          },
        },
        {
          'type': 'response.function_call_arguments.delta',
          'output_index': 1,
          'delta': '{"field":"name",',
        },
        {
          'type': 'response.function_call_arguments.delta',
          'output_index': 1,
          'delta': '"value":"Aria"}',
        },
        {
          'type': 'response.completed',
          'response': {
            'usage': {'input_tokens': 7, 'output_tokens': 3},
          },
        },
      ]);
      final deltas = await run(ProviderKind.openaiResponses);
      expect(textOf(deltas), 'Sure.');
      final call = callsOf(deltas).single;
      expect(call.id, 'call_9');
      expect(call.arguments, {'field': 'name', 'value': 'Aria'});
    });

    test('`output_item.done` arguments win over the pieces', () async {
      await serve([
        {
          'type': 'response.output_item.added',
          'output_index': 0,
          'item': {'type': 'function_call', 'call_id': 'c', 'name': 'get_draft'},
        },
        {
          'type': 'response.function_call_arguments.delta',
          'output_index': 0,
          'delta': '{"x"',
        },
        {
          'type': 'response.output_item.done',
          'output_index': 0,
          'item': {
            'type': 'function_call',
            'call_id': 'c',
            'name': 'get_draft',
            'arguments': '{}',
          },
        },
        {'type': 'response.completed', 'response': <String, dynamic>{}},
      ]);
      final call = callsOf(await run(ProviderKind.openaiResponses)).single;
      expect(call.argumentError, isNull);
      expect(call.arguments, isEmpty);
    });
  });

  group('Anthropic', () {
    test('results ride first in one user turn with the next message', () async {
      await serve([
        {'type': 'message_stop'},
      ]);
      await run(ProviderKind.anthropic);
      expect(capturedUri!.path, '/v1/messages');
      expect(captured!['system'], 'You build characters.');
      expect(captured!['max_tokens'], kAgentDefaultMaxTokens);
      final messages = (captured!['messages'] as List).cast<Map>();
      expect(messages.map((m) => m['role']), ['user', 'assistant', 'user']);
      final assistant = (messages[1]['content'] as List).cast<Map>();
      expect(assistant[0], {'type': 'text', 'text': 'Naming her first.'});
      expect(assistant[1], {
        'type': 'tool_use',
        'id': 'call_1',
        'name': 'set_field',
        'input': {'field': 'name', 'value': 'Aria'},
      });
      final after = (messages[2]['content'] as List).cast<Map>();
      expect(after[0], {
        'type': 'tool_result',
        'tool_use_id': 'call_1',
        'content': 'ok',
      });
      expect(after[1], {'type': 'text', 'text': 'Make her older.'});
      final tools = (captured!['tools'] as List).cast<Map>();
      expect(tools.first['input_schema']['required'], ['field', 'value']);
      // A no-argument tool still gets a schema; Anthropic requires one.
      expect(tools.last['input_schema']['type'], 'object');
    });

    test('a failed tool result is flagged', () async {
      await serve([
        {'type': 'message_stop'},
      ]);
      const call = ToolCall(id: 'c', name: 'get_draft');
      await run(ProviderKind.anthropic, messages: [
        AgentMessage.user('go'),
        AgentMessage(role: AgentRole.assistant, toolCalls: const [call]),
        AgentMessage.toolResult(call, 'no such field', isError: true),
      ]);
      final last = ((captured!['messages'] as List).last as Map)['content']
          as List;
      expect((last.single as Map)['is_error'], isTrue);
    });

    test('reads text and a tool_use block streamed as JSON pieces', () async {
      await serve([
        {
          'type': 'message_start',
          'message': {
            'usage': {'input_tokens': 12, 'output_tokens': 1},
          },
        },
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {'type': 'text', 'text': ''},
        },
        {
          'type': 'content_block_delta',
          'index': 0,
          'delta': {'type': 'text_delta', 'text': 'Writing.'},
        },
        {
          'type': 'content_block_start',
          'index': 1,
          'content_block': {
            'type': 'tool_use',
            'id': 'toolu_1',
            'name': 'set_field',
            'input': <String, dynamic>{},
          },
        },
        {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {'type': 'input_json_delta', 'partial_json': '{"field": "na'},
        },
        {
          'type': 'content_block_delta',
          'index': 1,
          'delta': {
            'type': 'input_json_delta',
            'partial_json': 'me", "value": "Aria"}',
          },
        },
        {'type': 'content_block_stop', 'index': 1},
        {
          'type': 'message_delta',
          'delta': {'stop_reason': 'tool_use'},
          'usage': {'output_tokens': 40},
        },
        {'type': 'message_stop'},
      ]);
      final deltas = await run(ProviderKind.anthropic);
      expect(textOf(deltas), 'Writing.');
      final call = callsOf(deltas).single;
      expect(call.id, 'toolu_1');
      expect(call.arguments, {'field': 'name', 'value': 'Aria'});
    });

    test('a call with no input at all has empty arguments', () async {
      await serve([
        {
          'type': 'content_block_start',
          'index': 0,
          'content_block': {
            'type': 'tool_use',
            'id': 't',
            'name': 'get_draft',
            'input': <String, dynamic>{},
          },
        },
        {'type': 'content_block_stop', 'index': 0},
        {'type': 'message_stop'},
      ]);
      final call = callsOf(await run(ProviderKind.anthropic)).single;
      expect(call.argumentError, isNull);
      expect(call.arguments, isEmpty);
    });

    test('an error event mid-stream throws', () async {
      await serve([
        {
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
        },
      ]);
      await expectLater(
        run(ProviderKind.anthropic),
        throwsA(isA<ChatApiException>()
            .having((e) => e.message, 'message', 'Overloaded')),
      );
    });
  });

  group('Gemini', () {
    test('sends functionResponse parts and echoes the signature', () async {
      await serve(const <Object>[]);
      await run(ProviderKind.gemini, messages: history(signature: 'SIG'));
      expect(capturedUri!.path, '/v1/models/m:streamGenerateContent');
      expect(captured!['systemInstruction']['parts'][0]['text'],
          'You build characters.');
      final contents = (captured!['contents'] as List).cast<Map>();
      expect(contents.map((c) => c['role']), ['user', 'model', 'user']);
      final model = (contents[1]['parts'] as List).cast<Map>();
      expect(model[0], {'text': 'Naming her first.'});
      expect(model[1]['functionCall'], {
        'name': 'set_field',
        'args': {'field': 'name', 'value': 'Aria'},
        'id': 'call_1',
      });
      expect(model[1]['thoughtSignature'], 'SIG');
      final after = (contents[2]['parts'] as List).cast<Map>();
      expect(after[0]['functionResponse'], {
        'name': 'set_field',
        'id': 'call_1',
        'response': {'result': 'ok'},
      });
      expect(after[1], {'text': 'Make her older.'});
      final declarations =
          ((captured!['tools'] as List).single as Map)['functionDeclarations']
              as List;
      expect((declarations[0] as Map)['parameters']['type'], 'object');
      // Gemini rejects an empty parameters object; a no-argument tool omits it.
      expect((declarations[1] as Map).containsKey('parameters'), isFalse);
    });

    test('an id made up here is never sent back', () async {
      await serve(const <Object>[]);
      await run(ProviderKind.gemini, messages: history(synthetic: true));
      final contents = (captured!['contents'] as List).cast<Map>();
      final call = ((contents[1]['parts'] as List)[1] as Map)['functionCall']
          as Map;
      expect(call.containsKey('id'), isFalse);
      final response =
          ((contents[2]['parts'] as List)[0] as Map)['functionResponse'] as Map;
      expect(response.containsKey('id'), isFalse);
    });

    test('reads a whole functionCall part with its signature', () async {
      await serve([
        {
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {'text': 'Thinking it over', 'thought': true},
                  {'text': 'Here goes.'},
                ],
              },
            },
          ],
        },
        {
          'candidates': [
            {
              'content': {
                'role': 'model',
                'parts': [
                  {
                    'functionCall': {
                      'name': 'set_field',
                      'args': {'field': 'name', 'value': 'Aria'},
                    },
                    'thoughtSignature': 'SIG2',
                  },
                  {
                    'functionCall': {'name': 'get_draft', 'args': <String, dynamic>{}},
                  },
                ],
              },
            },
          ],
          'usageMetadata': {'promptTokenCount': 9, 'candidatesTokenCount': 4},
        },
      ]);
      final deltas = await run(ProviderKind.gemini);
      expect(textOf(deltas), 'Here goes.');
      expect(deltas.map((d) => d.reasoning).join(), 'Thinking it over');
      final calls = callsOf(deltas);
      expect(calls.map((c) => c.name), ['set_field', 'get_draft']);
      expect(calls[0].signature, 'SIG2');
      expect(calls[0].arguments['value'], 'Aria');
      // Gemini gave no ids, so the ones made here are marked as such.
      expect(calls.every((c) => c.syntheticId), isTrue);
      expect(calls[0].id, isNot(calls[1].id));
    });

    test('non-streamed reply carries its calls and text', () {
      final delta = AgentClient.parseWhole(
        WireFormat.gemini,
        jsonEncode({
          'candidates': [
            {
              'content': {
                'parts': [
                  {'text': 'Done.'},
                  {
                    'functionCall': {
                      'id': 'g1',
                      'name': 'get_draft',
                      'args': <String, dynamic>{},
                    },
                  },
                ],
              },
            },
          ],
        }),
      );
      expect(delta.text, 'Done.');
      expect(delta.toolCalls.single.id, 'g1');
      expect(delta.toolCalls.single.syntheticId, isFalse);
    });
  });

  test('non-streamed Anthropic and Responses replies carry their calls', () {
    final anthropic = AgentClient.parseWhole(
      WireFormat.anthropic,
      jsonEncode({
        'content': [
          {'type': 'text', 'text': 'Ok.'},
          {
            'type': 'tool_use',
            'id': 't1',
            'name': 'set_field',
            'input': {'field': 'name', 'value': 'Aria'},
          },
        ],
        'usage': {'input_tokens': 3, 'output_tokens': 2},
      }),
    );
    expect(anthropic.text, 'Ok.');
    expect(anthropic.toolCalls.single.arguments['value'], 'Aria');
    expect(anthropic.usage!.outputTokens, 2);

    final responses = AgentClient.parseWhole(
      WireFormat.openaiResponses,
      jsonEncode({
        'output': [
          {
            'type': 'message',
            'content': [
              {'type': 'output_text', 'text': 'Ok.'},
            ],
          },
          {
            'type': 'function_call',
            'call_id': 'r1',
            'name': 'get_draft',
            'arguments': '{}',
          },
        ],
      }),
    );
    expect(responses.text, 'Ok.');
    expect(responses.toolCalls.single.id, 'r1');
  });

  test('messages survive a save and load', () {
    final original = history(signature: 'S');
    final restored = [
      for (final m in original)
        AgentMessage.fromJson(
          jsonDecode(jsonEncode(m.toJson())) as Map<String, dynamic>,
        ),
    ];
    expect(restored.map((m) => m.role), original.map((m) => m.role));
    expect(restored[2].toolCalls.single.signature, 'S');
    expect(restored[2].toolCalls.single.arguments['value'], 'Aria');
    expect(restored[3].toolCallId, 'call_1');
    expect(restored[3].toolName, 'set_field');
  });
}
