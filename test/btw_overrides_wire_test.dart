import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/btw_conversation.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/models/settings.dart';
import 'package:maichat/state/app_state.dart';
import 'package:maichat/services/backup_codec.dart';
import 'package:maichat/services/btw.dart';
import 'package:maichat/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Plain tests deliberately capture real HTTP; widget bindings replace it.
void main() {
  late AppState state;
  late HttpServer server;
  late List<({String path, Map<String, dynamic> body})> requests;
  bool toolCall = false;
  bool failTitle = false;
  Completer<void>? titleGate;
  Completer<void>? titleArrived;
  Completer<void>? sideGate;
  Completer<void>? sideArrived;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    requests = [];
    toolCall = false;
    failTitle = false;
    titleGate = null;
    titleArrived = null;
    sideGate = null;
    sideArrived = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add((path: request.uri.path, body: body));
      if (jsonEncode(body).contains('WAIT_SIDE')) {
        sideArrived?.complete();
        await sideGate?.future;
      }
      final title = jsonEncode(body).contains('concise title');
      if (title) {
        titleArrived?.complete();
        await titleGate?.future;
        if (failTitle) {
          request.response.statusCode = 500;
          await request.response.close();
          return;
        }
      }
      final offered =
          body['tools'] is List && (body['tools'] as List).isNotEmpty;
      final hasResult = (body['messages'] as List).any(
        (m) => m['role'] == 'tool',
      );
      final call = toolCall && offered && !hasResult;
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write(
        'data: ${jsonEncode({
          'choices': [
            {
              'delta': call ? {
                      'tool_calls': [
                        {
                          'index': 0,
                          'id': 'roll1',
                          'type': 'function',
                          'function': {'name': 'roll_dice', 'arguments': '{"formula":"d1"}'},
                        },
                      ],
                    } : {'content': title ? 'Useful Side Title' : 'SIDE_ANSWER'},
              'finish_reason': call ? 'tool_calls' : 'stop',
            },
          ],
        })}\n\n',
      );
      request.response.write('data: [DONE]\n\n');
      await request.response.close();
    });
    state = AppState();
    await state.init();
    for (final id in ['main', 'side']) {
      await state.addProvider(
        Provider(
          id: id,
          name: id,
          kind: ProviderKind.openai,
          baseUrl: 'http://127.0.0.1:${server.port}/$id/v1',
          model: '$id-model',
          apiKey: 'key',
        ),
      );
    }
    await state.selectProvider('main');
    state.active.systemPrompt = 'RP_SYSTEM';
    state.active.messages.add(ChatMessage(role: 'user', content: 'RP_CONTEXT'));
  });

  tearDown(() async {
    if (titleGate != null && !titleGate!.isCompleted) titleGate!.complete();
    if (sideGate != null && !sideGate!.isCompleted) sideGate!.complete();
    state.dispose();
    await server.close(force: true);
  });

  for (final window in [4096, 1024]) {
    for (final tools in [false, true]) {
      test(
        'custom side system budgets the resulting RP history: tools=$tools window=$window',
        () async {
          await state.saveChatToolConfig(
            ChatToolConfig(
              disabledTools: [
                for (final definition in state.chatToolDefinitionsFor(
                  state.active,
                ))
                  if (definition.name != 'roll_dice') definition.name,
              ],
            ),
          );
          final preset = Preset(
            id: 'heavy',
            maxContext: window,
            maxResponseTokens: 128,
            prompts: [
              PromptBlock(
                identifier: 'main',
                content: List.filled(2000, 'heavy instruction').join(' '),
              ),
              PromptBlock(identifier: 'chatHistory', marker: true),
              PromptBlock(
                identifier: 'kept-depth',
                content: 'KEPT_DEPTH',
                injectionPosition: InjectionPosition.absolute,
                injectionDepth: 2,
              ),
              PromptBlock(identifier: 'kept-tail', content: 'KEPT_TAIL'),
            ],
            promptOrder: [
              PromptOrderEntry(identifier: 'main'),
              PromptOrderEntry(identifier: 'chatHistory'),
              PromptOrderEntry(identifier: 'kept-depth'),
              PromptOrderEntry(identifier: 'kept-tail'),
            ],
          );
          await state.addPreset(preset);
          await state.setDefaultPreset(preset.id);
          state.active.messages.clear();
          for (var i = 0; i < 20; i++) {
            state.active.messages.add(
              ChatMessage(
                role: i.isEven ? 'user' : 'assistant',
                content:
                    '${i == 0 ? 'EARLIEST_DETAIL' : 'TURN_$i'} ${List.filled(80, 'context').join(' ')}',
              ),
            );
          }
          final thread = state.createBtwThread(state.active.id)
            ..systemPrompt = 'CUSTOM_SIDE_SYSTEM'
            ..toolsEnabled = tools;
          expect(
            await state.askAside('SIDE_QUESTION', thread: thread),
            'SIDE_ANSWER',
          );
          final messages = (requests.single.body['messages'] as List)
              .cast<Map<String, dynamic>>();
          expect(messages.first, {
            'role': 'system',
            'content': 'CUSTOM_SIDE_SYSTEM',
          });
          expect(messages.where((m) => m['role'] == 'system'), hasLength(1));
          final content = jsonEncode(messages);
          if (window == 4096) {
            expect(content, contains('EARLIEST_DETAIL'));
            for (var i = 1; i < 20; i++) {
              expect(content, contains('TURN_$i'));
            }
          } else {
            expect(content, isNot(contains('EARLIEST_DETAIL')));
            expect(content, contains('TURN_19'));
          }
          expect(content, contains('KEPT_DEPTH'));
          expect(content, contains('KEPT_TAIL'));
          expect(content, isNot(contains('heavy instruction')));
          expect(requests.single.body.containsKey('tools'), tools);
        },
      );
    }
  }

  for (final global in [false, true]) {
    for (final override in [null, false, true]) {
      test(
        'provider, prompt and tools reach the actual wire: global=$global override=$override',
        () async {
          await state.saveChatToolConfig(ChatToolConfig(enabled: global));
          final thread =
              state.createBtwThread(state.active.id, question: 'SIDE_QUESTION')
                ..systemPrompt = 'CUSTOM_SIDE_SYSTEM'
                ..providerId = 'side'
                ..toolsEnabled = override;
          final before = jsonEncode(state.active.toJson());
          expect(
            await state.askAside('SIDE_QUESTION', thread: thread),
            'SIDE_ANSWER',
          );
          final sent = requests.single;
          expect(sent.path, '/side/v1/chat/completions');
          expect(sent.body['model'], 'side-model');
          final messages = (sent.body['messages'] as List)
              .cast<Map<String, dynamic>>();
          expect(messages.first, {
            'role': 'system',
            'content': 'CUSTOM_SIDE_SYSTEM',
          });
          expect(messages.where((m) => m['role'] == 'system'), hasLength(1));
          expect(jsonEncode(messages), contains('RP_CONTEXT'));
          expect(jsonEncode(messages), isNot(contains('RP_SYSTEM')));
          expect(sent.body.containsKey('tools'), override ?? global);
          expect(jsonEncode(state.active.toJson()), before);
          requests.clear();
          await state.send('RP_NEXT');
          expect(requests.single.path, '/main/v1/chat/completions');
          expect(requests.single.body['model'], 'main-model');
          expect(jsonEncode(requests.single.body), contains('RP_SYSTEM'));
          expect(
            jsonEncode(requests.single.body),
            isNot(contains('SIDE_QUESTION')),
          );
          expect(
            jsonEncode(requests.single.body),
            isNot(contains('CUSTOM_SIDE_SYSTEM')),
          );
        },
      );
    }
  }

  test(
    'forcing tools on executes a call with the chosen side provider while RP tools remain off',
    () async {
      toolCall = true;
      final thread = state.createBtwThread(state.active.id)
        ..providerId = 'side'
        ..toolsEnabled = true;
      expect(
        await state.askAside('Roll one die', thread: thread),
        'SIDE_ANSWER',
      );
      expect(requests, hasLength(2));
      expect(requests.every((r) => r.path.startsWith('/side/')), isTrue);
      final followUp = jsonEncode(requests.last.body);
      expect(followUp, contains('roll_dice'));
      expect(
        (requests.last.body['messages'] as List).where(
          (m) => m['role'] == 'tool',
        ),
        isNotEmpty,
      );
      expect(state.chatToolConfigFor(state.active).enabled, isFalse);
      expect(
        state.active.messages.any((m) => m.content.contains('SIDE_ANSWER')),
        isFalse,
      );
    },
  );

  test(
    'only this thread’s completed history is carried to a follow-up and wrong-chat use fails',
    () async {
      final thread = state.createBtwThread(state.active.id);
      thread.exchanges.addAll([
        BtwExchange('OWN_FIRST', answer: 'OWN_ANSWER', done: true),
        BtwExchange(
          'FAILED',
          answer: 'FAILED_ANSWER',
          error: 'failure',
          done: true,
        ),
        BtwExchange(
          'STOPPED',
          answer: 'STOPPED_ANSWER',
          done: true,
          stopped: true,
        ),
      ]);
      state
          .createBtwThread(state.active.id)
          .exchanges
          .add(BtwExchange('OTHER_THREAD', answer: 'OTHER_ANSWER', done: true));
      await state.askAside('Follow up', thread: thread);
      final wire = jsonEncode(requests.single.body);
      expect(wire, contains('OWN_FIRST'));
      expect(wire, contains('OWN_ANSWER'));
      for (final excluded in [
        'FAILED',
        'STOPPED',
        'OTHER_THREAD',
        'OTHER_ANSWER',
      ]) {
        expect(wire, isNot(contains(excluded)));
      }
      final wrong = BtwConversation(id: 'wrong', conversationId: 'elsewhere');
      await expectLater(
        state.askAside('No', thread: wrong),
        throwsA(isA<Exception>()),
      );
      expect(requests, hasLength(1));
    },
  );

  for (final tools in [false, true]) {
    test(
      'thread deletion cancels its actual side request: tools=$tools',
      () async {
        final thread = state.createBtwThread(state.active.id)
          ..toolsEnabled = tools;
        await state.saveBtwThread(thread);
        sideGate = Completer<void>();
        sideArrived = Completer<void>();
        final pending = state.askAside('WAIT_SIDE', thread: thread);
        await sideArrived!.future;
        await state.deleteBtwThread(thread.id);
        sideGate!.complete();
        expect(await pending, '');
        expect(state.btwThreadById(thread.id), isNull);
        final loaded = AppState();
        await loaded.init();
        expect(loaded.btwThreadById(thread.id), isNull);
        loaded.dispose();
      },
    );
  }

  for (final replace in [false, true]) {
    for (final tools in [false, true]) {
      test(
        'restore cancels live side and title requests: replace=$replace tools=$tools',
        () async {
          await state.updateBtwSettings(
            const BtwSettings(titleMode: BtwTitleMode.generated),
          );
          final asideThread = state.createBtwThread(state.active.id)
            ..toolsEnabled = tools;
          final titleThread = state.createBtwThread(
            state.active.id,
            question: 'Restore title question',
          );
          titleThread.exchanges.add(
            BtwExchange(
              'Restore title question',
              answer: 'Completed first answer',
              done: true,
            ),
          );
          await state.saveBtwThread(asideThread);
          await state.saveBtwThread(titleThread);
          final raw = await Storage().dump();
          final archive = Uint8List.fromList(
            utf8.encode(
              jsonEncode(
                BackupPlan(
                  store: {
                    for (final entry in raw.entries)
                      entry.key: StoreEntry.of(entry.value),
                  },
                  createdAt: DateTime.now(),
                ).manifest,
              ),
            ),
          );
          sideGate = Completer<void>();
          sideArrived = Completer<void>();
          titleGate = Completer<void>();
          titleArrived = Completer<void>();
          final run = BtwRun();
          final asking = state.askAside(
            'WAIT_SIDE',
            thread: asideThread,
            run: run,
          );
          final naming = state.generateBtwTitle(titleThread);
          await sideArrived!.future;
          await titleArrived!.future;
          await state.restoreBackup(archive, replace: replace);
          expect(run.cancelled, isTrue);
          expect(await asking.timeout(const Duration(seconds: 2)), '');
          await naming.timeout(const Duration(seconds: 2));
          expect(
            state.btwThreadById(titleThread.id)!.title,
            'Restore title question',
          );
          expect(state.btwThreadById(titleThread.id)!.titleGenerated, isFalse);
          expect(sideGate!.isCompleted, isFalse);
          expect(titleGate!.isCompleted, isFalse);
          sideGate!.complete();
          titleGate!.complete();
        },
      );
    }
  }

  test(
    'generated titles use a separate metered no-tools request and persist once',
    () async {
      await state.updateBtwSettings(
        const BtwSettings(titleMode: BtwTitleMode.generated),
      );
      final thread =
          state.createBtwThread(state.active.id, question: 'What happens here?')
            ..providerId = 'side'
            ..toolsEnabled = true;
      thread.exchanges.add(
        BtwExchange(
          'What happens here?',
          answer: 'A detailed answer.',
          done: true,
        ),
      );
      await state.saveBtwThread(thread);
      await state.generateBtwTitle(thread);
      expect(thread.title, 'Useful Side Title');
      expect(thread.titleGenerated, isTrue);
      expect(requests.single.path, '/side/v1/chat/completions');
      expect(requests.single.body.containsKey('tools'), isFalse);
      expect(jsonEncode(requests.single.body), isNot(contains('RP_CONTEXT')));
      await state.generateBtwTitle(thread);
      expect(requests, hasLength(1));
      final loaded = AppState();
      await loaded.init();
      expect(loaded.btwThreadById(thread.id)!.title, 'Useful Side Title');
      loaded.dispose();
    },
  );

  test(
    'title failure keeps first-line fallback and late title cannot overwrite a rename',
    () async {
      await state.updateBtwSettings(
        const BtwSettings(titleMode: BtwTitleMode.generated),
      );
      final thread = state.createBtwThread(
        state.active.id,
        question: 'Original question',
      );
      thread.exchanges.add(
        BtwExchange('Original question', answer: 'Answer', done: true),
      );
      failTitle = true;
      await state.generateBtwTitle(thread);
      expect(thread.title, 'Original question');
      failTitle = false;
      titleGate = Completer<void>();
      titleArrived = Completer<void>();
      final pending = state.generateBtwTitle(thread);
      await titleArrived!.future;
      thread.title = 'My own title';
      await state.saveBtwThread(thread);
      titleGate!.complete();
      await pending;
      expect(thread.title, 'My own title');
    },
  );

  test(
    'deleting a thread cancels its pending title without resurrecting it',
    () async {
      await state.updateBtwSettings(
        const BtwSettings(titleMode: BtwTitleMode.generated),
      );
      final thread = state.createBtwThread(
        state.active.id,
        question: 'Delete question',
      );
      thread.exchanges.add(
        BtwExchange('Delete question', answer: 'Answer', done: true),
      );
      titleGate = Completer<void>();
      titleArrived = Completer<void>();
      final pending = state.generateBtwTitle(thread);
      await titleArrived!.future;
      await state.deleteBtwThread(thread.id);
      titleGate!.complete();
      await pending;
      expect(state.btwThreadById(thread.id), isNull);
      final loaded = AppState();
      await loaded.init();
      expect(loaded.btwThreadById(thread.id), isNull);
      loaded.dispose();
    },
  );
}
