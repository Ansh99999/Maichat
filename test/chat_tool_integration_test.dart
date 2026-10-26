import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/models/conversation.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/image_gen.dart';
import 'package:maichat/services/avatar_store.dart';
import 'package:maichat/services/image_client.dart';
import 'package:maichat/services/storage.dart';
import 'package:maichat/services/chat_codec.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Images extends ImageClient {
  int count = 0;
  @override
  Future<ImageResult> generate({
    required ImageGenConfig config,
    required String prompt,
    List<ImageReference> references = const [],
  }) async {
    count++;
    return ImageResult(
      images: [
        Uint8List.fromList(
          base64Decode(
            'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j1ioAAAAASUVORK5CYII=',
          ),
        ),
      ],
    );
  }
}

class _FailToolSaveOnce extends Storage {
  bool fail = true;
  @override
  Future<void> saveConversations(List<Conversation> conversations) async {
    for (final c in conversations) {
      final run = c.messages.isEmpty ? null : c.messages.last.toolRun;
      if (fail &&
          run?.status == 'running' &&
          run!.history.isNotEmpty &&
          run.history.last.role == AgentRole.tool &&
          !run.history.last.isError) {
        fail = false;
        throw StateError('Fixture save failure');
      }
    }
    await super.saveConversations(conversations);
  }
}

// Plain tests: widget bindings replace real HTTP with a 400 responder.
void main() {
  late HttpServer server;
  late AppState state;
  late List<Map<String, dynamic>> requests;
  var kind = ProviderKind.openai;
  var stream = true;
  var incomplete = false;
  var argumentError = false;
  var eof = false;
  List<ToolCall> calls = [];
  Completer<void>? gate;
  Completer<void>? arrived;
  ImageClient? imageClient;
  Directory? pictureDirectory;
  Storage? storage;

  Future<void> boot() async {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      if (arrived != null && !arrived!.isCompleted) arrived!.complete();
      await gate?.future;
      final first = requests.length == 1;
      final useCalls = first ? calls : <ToolCall>[];
      final text = useCalls.isEmpty ? 'FINAL_REPLY' : '';
      final reason = incomplete
          ? 'length'
          : (useCalls.isEmpty ? 'stop' : 'tool_calls');
      final openAiCalls = useCalls
          .map(
            (c) => {
              'id': c.id,
              'index': 0,
              'type': 'function',
              'function': {
                'name': c.name,
                'arguments': argumentError ? '{bad' : jsonEncode(c.arguments),
              },
            },
          )
          .toList();
      Map<String, dynamic> response;
      List<Map<String, dynamic>> events;
      switch (kind.wire) {
        case WireFormat.openaiChat:
          response = {
            'choices': [
              {
                'message': {'content': text, 'tool_calls': openAiCalls},
                'finish_reason': reason,
              },
            ],
          };
          events = [
            {
              'choices': [
                {
                  'delta': {'content': text, 'tool_calls': openAiCalls},
                },
              ],
            },
            {
              'choices': [
                {'delta': {}, 'finish_reason': reason},
              ],
            },
          ];
        case WireFormat.openaiResponses:
          final items = useCalls
              .map(
                (c) => {
                  'type': 'function_call',
                  'call_id': c.id,
                  'name': c.name,
                  'arguments': jsonEncode(c.arguments),
                },
              )
              .toList();
          response = {
            'status': incomplete ? 'incomplete' : 'completed',
            'output': [
              ...items,
              if (text.isNotEmpty)
                {
                  'type': 'message',
                  'content': [
                    {'type': 'output_text', 'text': text},
                  ],
                },
            ],
          };
          events = [
            for (var i = 0; i < items.length; i++)
              {
                'type': 'response.output_item.done',
                'output_index': i,
                'item': items[i],
              },
            if (text.isNotEmpty)
              {'type': 'response.output_text.delta', 'delta': text},
            {
              'type': incomplete ? 'response.incomplete' : 'response.completed',
              'response': response,
            },
          ];
        case WireFormat.anthropic:
          final blocks = useCalls
              .map(
                (c) => {
                  'type': 'tool_use',
                  'id': c.id,
                  'name': c.name,
                  'input': c.arguments,
                },
              )
              .toList();
          response = {
            'content': [
              ...blocks,
              if (text.isNotEmpty) {'type': 'text', 'text': text},
            ],
            'stop_reason': incomplete
                ? 'max_tokens'
                : (useCalls.isEmpty ? 'end_turn' : 'tool_use'),
          };
          events = [
            for (var i = 0; i < blocks.length; i++) ...[
              {
                'type': 'content_block_start',
                'index': i,
                'content_block': {...blocks[i], 'input': {}},
              },
              {
                'type': 'content_block_delta',
                'index': i,
                'delta': {
                  'type': 'input_json_delta',
                  'partial_json': jsonEncode(useCalls[i].arguments),
                },
              },
              {'type': 'content_block_stop', 'index': i},
            ],
            if (text.isNotEmpty)
              {
                'type': 'content_block_delta',
                'index': 99,
                'delta': {'type': 'text_delta', 'text': text},
              },
            {
              'type': 'message_delta',
              'delta': {'stop_reason': response['stop_reason']},
            },
            {'type': 'message_stop'},
          ];
        case WireFormat.gemini:
          response = {
            'candidates': [
              {
                'finishReason': incomplete ? 'MAX_TOKENS' : 'STOP',
                'content': {
                  'role': 'model',
                  'parts': [
                    for (final c in useCalls)
                      {
                        'functionCall': {
                          'id': c.id,
                          'name': c.name,
                          'args': c.arguments,
                        },
                        'thoughtSignature': 'signature',
                      },
                    if (text.isNotEmpty) {'text': text},
                  ],
                },
              },
            ],
          };
          events = [response];
      }
      if (stream) {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        for (final event in eof ? events.take(1) : events) {
          request.response.write('data: ${jsonEncode(event)}\n\n');
        }
        if (kind.wire == WireFormat.openaiChat && !eof) {
          request.response.write('data: [DONE]\n\n');
        }
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(response));
      }
      await request.response.close();
    });
    state = AppState(
      storage: storage,
      imageClient: imageClient,
      avatars: pictureDirectory == null ? null : AvatarStore(pictureDirectory!),
    );
    await state.init();
    await state.addProvider(
      Provider(
        id: 'p',
        name: 'test',
        kind: kind,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'fixture',
        apiKey: 'key',
      ),
    );
    final preset = Preset(
      id: 'tool-preset',
      stream: stream,
      topP: 0.7,
      presencePenalty: 0.3,
      seed: 42,
      n: 3,
    );
    await state.addPreset(preset);
    await state.setDefaultPreset(preset.id);
    await state.saveChatToolConfig(const ChatToolConfig(enabled: true));
  }

  setUp(() {
    kind = ProviderKind.openai;
    stream = true;
    incomplete = false;
    argumentError = false;
    eof = false;
    gate = null;
    arrived = null;
    imageClient = null;
    pictureDirectory = null;
    storage = null;
    calls = [
      const ToolCall(
        id: 'roll1',
        name: 'roll_dice',
        arguments: {'formula': 'd1'},
      ),
    ];
  });
  tearDown(() async {
    gate?.complete();
    state.dispose();
    await server.close(force: true);
    pictureDirectory?.deleteSync(recursive: true);
    if (pictureDirectory != null) avatarDirectory = null;
  });

  for (final providerKind in [
    ProviderKind.openai,
    ProviderKind.openaiResponses,
    ProviderKind.anthropic,
    ProviderKind.gemini,
  ]) {
    test(
      'ordinary chat executes and replays a saved roll: ${providerKind.name}',
      () async {
        kind = providerKind;
        await boot();
        await state.send('Roll a die.');
        expect(requests, hasLength(2));
        final message = state.active.messages.last;
        expect(message.content, 'FINAL_REPLY');
        expect(message.toolRun!.status, 'completed');
        final result = message.toolRun!.history.singleWhere(
          (v) => v.role == AgentRole.tool,
        );
        expect(jsonDecode(result.text)['total'], 1);
        expect(result.toolCallId, 'roll1');
        expect(jsonEncode(requests[1]), contains('roll1'));
        final preview = state.requestPreview(
          state.assemblePromptForMessage(state.active, 1),
        );
        expect(preview, contains('Request 2'));
        expect(preview, contains('roll1'));
        expect(preview, isNot(contains('Bearer key')));
        if (kind.wire == WireFormat.openaiChat) {
          final messages = (requests[1]['messages'] as List).cast<Map>();
          expect(messages.where((m) => m['role'] == 'system'), hasLength(1));
          expect(messages.first['role'], 'system');
          expect(messages.where((m) => m['role'] == 'user'), hasLength(1));
        }
        await state.send('Remember the roll.');
        expect(requests, hasLength(3));
        expect(
          jsonEncode(requests.last),
          contains(result.text.replaceAll('"', '\\"')),
        );
        final restored = AppState();
        await restored.init();
        expect(
          restored.active.messages[1].toolRun!.history.last.text,
          result.text,
        );
        restored.dispose();
        expect(
          requests,
          hasLength(3),
          reason: 'Reload must not execute saved tools.',
        );
      },
    );

    test('incomplete calls do not execute: ${providerKind.name}', () async {
      kind = providerKind;
      incomplete = true;
      calls = [
        const ToolCall(
          id: 'stat',
          name: 'define_tracker',
          arguments: {'id': 'health', 'label': 'Health', 'value': 100},
        ),
      ];
      await boot();
      await state.send('Track health.');
      expect(requests, hasLength(1));
      expect(state.chatToolProjection(state.active).values, isEmpty);
      expect(state.active.messages.last.toolRun!.status, 'failed');
    });

    test(
      'whole response calls preserve chat sampling: ${providerKind.name}',
      () async {
        kind = providerKind;
        stream = false;
        await boot();
        await state.send('Roll.');
        expect(requests, hasLength(2));
        expect(state.active.messages.last.content, 'FINAL_REPLY');
        expect(
          state.active.messages.last.toolRun!.history.last.isError,
          isFalse,
        );
        if (kind.wire == WireFormat.openaiChat) {
          expect(requests.first['top_p'], 0.7);
          expect(requests.first['presence_penalty'], 0.3);
          expect(requests.first['seed'], 42);
          expect(requests.first.containsKey('n'), isFalse);
          expect(requests.first['stream'], isFalse);
        }
        final exported = ChatCodec.exportNative(state.active);
        expect(
          jsonDecode(exported)['messages'].last['toolRun']['history'],
          hasLength(2),
        );
      },
    );
  }

  test(
    'sequential effects in one run survive restart, swipes and historical forks',
    () async {
      calls = [
        const ToolCall(
          id: 'a',
          name: 'define_tracker',
          arguments: {
            'id': 'health',
            'label': 'Health',
            'value': 100,
            'min': 0,
            'max': 100,
          },
        ),
        const ToolCall(
          id: 'b',
          name: 'update_tracker',
          arguments: {'id': 'health', 'delta': -10},
        ),
      ];
      await boot();
      await state.send('An attack.');
      final c = state.active;
      expect(
        (state.chatToolProjection(c).values['tracker:health'] as Map)['value'],
        90,
      );
      c.messages[1] = c.messages[1].addSwipe(
        const MessageVariant(content: 'Another outcome'),
      );
      expect(state.chatToolProjection(c).values, isEmpty);
      await state.setSwipe(c.id, 1, 0);
      expect(
        (state.chatToolProjection(c).values['tracker:health'] as Map)['value'],
        90,
      );
      final forkId = await state.forkConversation(c.id, 0);
      expect(
        state.chatToolProjection(state.conversationById(forkId)!).values,
        isEmpty,
      );
      final restored = AppState();
      await restored.init();
      expect(
        (restored
                .chatToolProjection(restored.conversationById(c.id)!)
                .values['tracker:health']
            as Map)['value'],
        90,
      );
      restored.dispose();
    },
  );

  test(
    'malformed arguments return an error result without invoking a handler',
    () async {
      argumentError = true;
      await boot();
      await state.send('Roll.');
      expect(requests, hasLength(2));
      expect(state.active.messages.last.toolRun!.history.last.isError, isTrue);
    },
  );

  test(
    'btw correction persists outside RP and expires after a complete reply',
    () async {
      calls = [
        const ToolCall(
          id: 'ooc',
          name: 'set_prompt_injection',
          arguments: {
            'text': 'She already knows his name.',
            'depth': 0,
            'lifetime': 'next_reply',
          },
        ),
      ];
      await boot();
      final count = state.active.messages.length;
      final answer = await state.askAside('OOC: correct her knowledge.');
      expect(answer, 'FINAL_REPLY');
      expect(state.active.messages, hasLength(count));
      expect(
        state.chatToolProjection(state.active).values['injection:correction'],
        isA<Map>(),
      );
      await state.send('Continue.');
      expect(
        jsonEncode(requests.last),
        contains('She already knows his name.'),
      );
      expect(
        state
            .chatToolProjection(state.active)
            .values
            .containsKey('injection:correction'),
        isFalse,
      );
    },
  );

  test(
    'custom recipe import/export executes through shared operations',
    () async {
      await boot();
      await state.importChatTools(
        jsonEncode({
          'format': 'maichat-tools',
          'version': 1,
          'tools': [
            {
              'name': 'lucky',
              'description': 'Roll one guaranteed point.',
              'action': {
                'call': 'roll_dice',
                'arguments': {'formula': 'd1'},
              },
            },
          ],
        }),
      );
      final result = await state.testChatTool('lucky', {});
      expect((result as Map)['total'], 1);
      expect(
        jsonDecode(state.exportChatTools())['tools'].single['action']['call'],
        'roll_dice',
      );
      await expectLater(
        state.importChatTools(state.exportChatTools()),
        throwsFormatException,
      );
    },
  );

  test('btw authors an executable tool in chat scope', () async {
    calls = [
      const ToolCall(
        id: 'create',
        name: 'save_tool',
        arguments: {
          'definition': {
            'name': 'lucky',
            'description': 'Roll one.',
            'action': {
              'call': 'roll_dice',
              'arguments': {'formula': 'd1'},
            },
          },
          'scope': 'chat',
        },
      ),
    ];
    await boot();
    expect(
      await state.askAside('Create a lucky die tool for this chat.'),
      'FINAL_REPLY',
    );
    expect(state.active.messages, isEmpty);
    expect(
      state.chatToolDefinitionsFor(state.active).any((v) => v.name == 'lucky'),
      isTrue,
    );
    expect(
      state.chatToolDefinitionsFor(null).any((v) => v.name == 'lucky'),
      isFalse,
    );
    expect(
      (await state.testChatTool('lucky', {}, conversationId: state.active.id)
          as Map)['total'],
      1,
    );
  });

  test(
    'generated images belong to a variant and survive an inactive swipe',
    () async {
      final images = _Images();
      imageClient = images;
      pictureDirectory = Directory.systemTemp.createTempSync(
        'chat-tool-image-',
      );
      calls = [
        const ToolCall(
          id: 'image',
          name: 'generate_image',
          arguments: {'prompt': 'A lighthouse.'},
        ),
      ];
      await boot();
      await state.updateImageGen(
        const ImageGenConfig(
          baseUrl: 'https://fixture.invalid/v1',
          model: 'image',
        ),
      );
      await state.send('Show the lighthouse.');
      final c = state.active;
      final message = c.messages.last;
      expect(message.role, 'assistant');
      expect(message.images, isEmpty);
      expect(message.toolRun!.images, hasLength(1));
      final ref = message.visibleImages.single.ref;
      c.messages[c.messages.length - 1] = message.addSwipe(
        const MessageVariant(content: 'No picture here.'),
      );
      expect(c.messages.last.visibleImages, isEmpty);
      expect(c.pictureRefs, contains(ref));
      await state.setSwipe(c.id, c.messages.length - 1, 0);
      expect(c.messages.last.visibleImages.single.ref, ref);
      expect(
        File('${pictureDirectory!.path}/${avatarRefName(ref)}').existsSync(),
        isTrue,
      );
      expect(images.count, 1);
      expect(
        jsonDecode(
          ChatCodec.exportNative(c),
        )['messages'].last['toolRun']['images'],
        hasLength(1),
      );
    },
  );

  test(
    'continuation retains tracker effects without executing them again',
    () async {
      calls = [
        const ToolCall(
          id: 'health',
          name: 'define_tracker',
          arguments: {'id': 'hp', 'label': 'Health', 'value': 90},
        ),
      ];
      await boot();
      await state.send('Set health.');
      await state.continueReply();
      expect(
        (state.chatToolProjection(state.active).values['tracker:hp']
            as Map)['value'],
        90,
      );
      expect(state.active.messages.last.swipeCount, 2);
      expect(state.active.messages.last.toolRun!.effects, hasLength(1));
    },
  );

  test(
    'EOF with complete JSON but no completion marker does not execute',
    () async {
      eof = true;
      calls = [
        const ToolCall(
          id: 'hp',
          name: 'define_tracker',
          arguments: {'id': 'hp', 'label': 'Health', 'value': 100},
        ),
      ];
      await boot();
      await state.send('Track health.');
      expect(state.chatToolProjection(state.active).values, isEmpty);
      expect(requests, hasLength(1));
    },
  );

  test('duplicate delivery of a call executes the action once', () async {
    const update = ToolCall(
      id: 'same',
      name: 'update_tracker',
      arguments: {'id': 'hp', 'delta': -10},
    );
    calls = [update, update];
    await boot();
    await state.testChatTool('define_tracker', {
      'id': 'hp',
      'label': 'Health',
      'value': 100,
    });
    await state.send('Attack.');
    expect(
      (state.chatToolProjection(state.active).values['tracker:hp']
          as Map)['value'],
      90,
    );
    expect(
      state.active.messages.last.toolRun!.history.first.toolCalls,
      hasLength(1),
    );
  });

  test(
    'a failed custom recipe does not commit partial tracker writes',
    () async {
      calls = [const ToolCall(id: 'bad', name: 'bad_recipe')];
      await boot();
      await state.saveChatToolConfig(
        const ChatToolConfig(
          enabled: true,
          customTools: [
            ChatToolDefinition(
              name: 'bad_recipe',
              description: 'A failing recipe.',
              action: {
                'steps': [
                  {
                    'call': 'define_tracker',
                    'arguments': {'id': 'hp', 'label': 'Health', 'value': 100},
                  },
                  {'call': 'missing_operation', 'arguments': {}},
                ],
              },
            ),
          ],
        ),
      );
      await state.send('Try it.');
      expect(state.chatToolProjection(state.active).values, isEmpty);
      expect(state.active.messages.last.toolRun!.history.last.isError, isTrue);
    },
  );

  test(
    'an incomplete character reply does not consume a next-reply correction',
    () async {
      calls = [
        const ToolCall(
          id: 'ooc',
          name: 'set_prompt_injection',
          arguments: {
            'text': 'She knows his name.',
            'depth': 0,
            'lifetime': 'next_reply',
          },
        ),
      ];
      await boot();
      await state.askAside('Fix her knowledge.');
      incomplete = true;
      await state.send('Continue.');
      expect(
        state.chatToolProjection(state.active).values['injection:correction'],
        isA<Map>(),
      );
      incomplete = false;
      await state.send('Try again.');
      expect(
        state
            .chatToolProjection(state.active)
            .values
            .containsKey('injection:correction'),
        isFalse,
      );
    },
  );

  test(
    'an earlier dice alternative invalidates dependent tracker effects',
    () async {
      await boot();
      await state.testChatTool('define_tracker', {
        'id': 'hp',
        'label': 'Health',
        'value': 100,
      });
      await state.send('Roll.');
      requests.clear();
      calls = [
        const ToolCall(
          id: 'damage',
          name: 'update_tracker',
          arguments: {'id': 'hp', 'delta': -10},
        ),
      ];
      await state.send('Apply damage.');
      final dependent = state.active.messages.last.toolRun!;
      expect(
        (state.chatToolProjection(state.active).values['tracker:hp']
            as Map)['value'],
        90,
      );
      state.active.messages[1] = state.active.messages[1].addSwipe(
        const MessageVariant(content: 'The attack misses.'),
      );
      await state.setSwipe(state.active.id, 1, 1);
      final projection = state.chatToolProjection(state.active);
      expect(projection.staleRuns, contains(dependent.id));
      expect((projection.values['tracker:hp'] as Map)['value'], 100);
    },
  );

  test('deep OOC corrections survive history context trimming', () async {
    calls = [];
    await boot();
    state.defaultPreset!.maxContext = 8192;
    state.active.messages.addAll(
      List.generate(
        200,
        (i) => ChatMessage(
          role: i.isEven ? 'user' : 'assistant',
          content: 'History $i ${List.filled(100, 'word').join(' ')}',
        ),
      ),
    );
    await state.testChatTool('set_prompt_injection', {
      'text': 'KEEP_THIS_CORRECTION',
      'depth': 1000,
      'lifetime': 'next_reply',
    });
    await state.send('Continue.');
    expect(requests, hasLength(1));
    expect(jsonEncode(requests.single), contains('KEEP_THIS_CORRECTION'));
    expect(state.active.messages.last.toolRun!.status, 'completed');
  });

  test(
    'an unsuccessful save does not commit a tracker or tell the model it succeeded',
    () async {
      storage = _FailToolSaveOnce();
      calls = [
        const ToolCall(
          id: 'hp',
          name: 'define_tracker',
          arguments: {'id': 'hp', 'label': 'Health', 'value': 100},
        ),
      ];
      await boot();
      await state.send('Track health.');
      expect(requests, hasLength(1));
      expect(state.chatToolProjection(state.active).values, isEmpty);
      expect(state.active.messages.last.toolRun!.history.last.isError, isTrue);
      expect(
        state.active.messages.last.toolRun!.history.last.text,
        contains('not saved'),
      );
    },
  );

  test('Stop during request prevents tools and clears logical run', () async {
    await boot();
    gate = Completer<void>();
    arrived = Completer<void>();
    final sending = state.send('Roll.');
    await arrived!.future;
    state.stop();
    gate!.complete();
    gate = null;
    await sending;
    expect(state.streaming, isFalse);
    expect(state.active.messages.last.role, 'user');
    expect(state.active.messages.last.toolRun, isNull);
  });
}
