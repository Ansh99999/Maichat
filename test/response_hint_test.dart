import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/chat_interface.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/services/macro_context.dart';
import 'package:maichat/services/prompt_builder.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The response hint: a line of steering typed beside a chat and injected into
/// every send at a configured depth from the newest turn.
///
/// Three layers are covered, because a hint that assembles is not a hint that
/// ships: the builder's placement, [AppState]'s resolution and persistence, and
/// the JSON that actually leaves the app.
class _FakeMacros implements MacroEngine {
  @override
  String evaluate(String text, MacroContext ctx) => text
      .replaceAll(RegExp(r'\{\{char\}\}', caseSensitive: false), ctx.charName)
      .replaceAll(RegExp(r'\{\{user\}\}', caseSensitive: false), ctx.userName);
}

List<ChatMessage> _history(int n) => [
      for (var i = 0; i < n; i++)
        ChatMessage(role: i.isEven ? 'user' : 'assistant', content: 'turn $i'),
    ];

/// Answers every send, so a chat driven by these tests has the alternating
/// user/assistant history a depth is measured against.
class _FakeClient extends ChatClient {
  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    yield const ChatDelta(text: 'Very well.');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const ['m'];
}

void main() {
  group('PromptBuilder', () {
    final builder = PromptBuilder(macros: _FakeMacros());

    test('no hint means nothing extra on the wire', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice'),
        history: _history(4),
      );
      expect(built.messages.map((m) => m.content).join(),
          isNot(contains('response_hint')));
    });

    test('a hint at depth 0 lands after the newest turn, as a user turn, and '
        'the one-leading-system rule survives it', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
        history: _history(6),
        hintText: 'she is lying',
        hintDepth: 0,
      );

      final whole = built.messages.map((m) => m.content).join('\n');
      expect(whole, contains('she is lying'));
      expect(whole, contains('<response_hint>'));

      // Exactly one system message, at position 0.
      expect(built.messages.where((m) => m.role == 'system').length, 1);
      expect(built.messages.first.role, 'system');
      expect(built.messages.first.content, isNot(contains('she is lying')));

      // At depth 0 nothing follows it, so it rides on the final turn.
      expect(built.messages.last.content, contains('she is lying'));
      expect(built.messages.last.role, 'user');
    });

    test('a hint at depth 2 sits two turns back', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
        history: _history(6),
        hintText: 'HINT_TOKEN',
        hintDepth: 2,
      );

      final carrier = built.messages
          .indexWhere((m) => m.content.contains('HINT_TOKEN'));
      expect(carrier, isNot(-1));
      // Depth 2 means two turns follow the hint — turn 4 and turn 5. Turn 4 is a
      // user turn and the hint went out as one too, so mergeSameRole folds them
      // into a single wire message with the hint first; the count is still two
      // turns' worth of conversation from the hint to the end.
      final fromHint =
          built.messages.skip(carrier).map((m) => m.content).join('\n');
      expect(fromHint, contains('turn 4'));
      expect(fromHint, contains('turn 5'));
      expect(fromHint, isNot(contains('turn 3')));
      final merged = built.messages[carrier].content;
      expect(merged.indexOf('HINT_TOKEN'), lessThan(merged.indexOf('turn 4')));
    });

    test('the deepest hint a chat can ask for still lands inside it', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
        history: _history(2),
        hintText: 'HINT_TOKEN',
        hintDepth: kMaxResponseHintDepth,
      );
      // Deeper than the conversation is long: it clamps to the front of the
      // history rather than vanishing or landing outside it.
      final whole = built.messages.map((m) => m.content).join('\n');
      expect(whole, contains('HINT_TOKEN'));
      expect(built.messages.where((m) => m.role == 'system').length, 1);
    });

    test('a hint sits last at its depth, behind lore and the summary', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
        history: _history(6),
        summaryText: 'SUMMARY_TOKEN',
        summaryDepth: 0,
        memoryText: 'MEMORY_TOKEN',
        memoryDepth: 0,
        hintText: 'HINT_TOKEN',
        hintDepth: 0,
      );
      // Everything injected at depth 0 is merged onto the tail user turn; within
      // it, the hint must come last — it is the thing steering the reply that
      // follows.
      final tail = built.messages.last.content;
      expect(tail, contains('SUMMARY_TOKEN'));
      expect(tail, contains('MEMORY_TOKEN'));
      expect(tail.indexOf('HINT_TOKEN'),
          greaterThan(tail.indexOf('SUMMARY_TOKEN')));
      expect(tail.indexOf('HINT_TOKEN'),
          greaterThan(tail.indexOf('MEMORY_TOKEN')));
    });

    test('macros resolve in a hint', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
        history: _history(2),
        userName: 'Ansh',
        hintText: '{{char}} is angry with {{user}}',
        hintDepth: 0,
      );
      expect(built.messages.last.content, contains('Alice is angry with Ansh'));
    });

    test('the breakdown names the hint and its depth', () {
      final built = builder.build(
        preset: Preset.create(),
        character: Character(id: 'a', name: 'Alice', description: 'Explorer.'),
        history: _history(4),
        hintText: 'HINT_TOKEN',
        hintDepth: 3,
      );
      expect(built.sections.map((s) => s.label),
          contains('Response hint (depth 3)'));
    });
  });

  group('AppState', () {
    late Directory dir;
    late _FakeClient client;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      dir = Directory.systemTemp.createTempSync('hint-state');
      client = _FakeClient();
    });
    tearDown(() => dir.deleteSync(recursive: true));

    Future<AppState> boot() async {
      final state = AppState(client: client);
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'https://host.tld/v1',
        model: 'm',
        apiKey: 'k',
      ));
      return state;
    }

    test('off by default, and a hint typed while off never reaches the model',
        () async {
      final state = await boot();
      expect(state.responseHintEnabled, isFalse);
      expect(state.responseHintDepth, kDefaultResponseHintDepth);

      await state.send('hello');
      state.setResponseHint(state.active.id, 'HINT_TOKEN');
      expect(state.responseHint(state.active.id), 'HINT_TOKEN');
      // Typed, remembered — and inert, because the feature is switched off.
      expect(state.activeResponseHint(state.active), isEmpty);
      final assembled = state.assemblePromptForMessage(
          state.active, state.active.messages.length);
      expect(assembled.messages.map((m) => m.content).join(),
          isNot(contains('HINT_TOKEN')));
    });

    test('switched on, the hint is assembled into the next request', () async {
      final state = await boot();
      await state.updateChatInterface(
          state.chatInterface.copyWith(responseHintEnabled: true));
      await state.send('hello');
      state.setResponseHint(state.active.id, 'HINT_TOKEN');

      final assembled = state.assemblePromptForMessage(
          state.active, state.active.messages.length);
      expect(assembled.messages.map((m) => m.content).join(),
          contains('HINT_TOKEN'));
      // Still one leading system message, whatever the depth put where.
      expect(assembled.messages.where((m) => m.role == 'system').length, 1);
      expect(assembled.messages.first.role, 'system');
      expect(assembled.sections.map((s) => s.label),
          contains('Response hint (depth 0)'));
    });

    test('the depth setting moves it', () async {
      final state = await boot();
      await state.updateChatInterface(state.chatInterface
          .copyWith(responseHintEnabled: true, responseHintDepth: 2));
      await state.send('one');
      await state.send('two');
      await state.send('three');
      state.setResponseHint(state.active.id, 'HINT_TOKEN');

      final assembled = state.assemblePromptForMessage(
          state.active, state.active.messages.length);
      final at =
          assembled.messages.indexWhere((m) => m.content.contains('HINT_TOKEN'));
      expect(at, isNot(-1));
      // Two turns follow the hint: the last user turn it was merged onto (a hint
      // goes out as a user turn, so adjacent ones fold together) and the reply
      // after it.
      final fromHint =
          assembled.messages.skip(at).map((m) => m.content).join('\n');
      expect(fromHint, contains('three'));
      expect(fromHint, contains('Very well.'));
      expect(fromHint, isNot(contains('two')));
    });

    test('a hint belongs to one chat and does not leak into another', () async {
      final state = await boot();
      await state.updateChatInterface(
          state.chatInterface.copyWith(responseHintEnabled: true));
      await state.send('first chat');
      final first = state.active.id;
      state.setResponseHint(first, 'FIRST_HINT');

      state.newConversation();
      await Future<void>.delayed(Duration.zero);
      final second = state.active.id;
      expect(state.responseHint(second), isEmpty);
      expect(state.activeResponseHint(state.active), isEmpty);
      expect(state.responseHint(first), 'FIRST_HINT');
    });

    test('erasing a hint takes it off the chat', () async {
      final state = await boot();
      await state.updateChatInterface(
          state.chatInterface.copyWith(responseHintEnabled: true));
      await state.send('hello');
      state.setResponseHint(state.active.id, 'HINT_TOKEN');
      state.setResponseHint(state.active.id, '   ');
      expect(state.responseHint(state.active.id), isEmpty);
      final assembled = state.assemblePromptForMessage(
          state.active, state.active.messages.length);
      expect(assembled.messages.map((m) => m.content).join(),
          isNot(contains('HINT_TOKEN')));
    });

    test('a saved hint comes back on the next launch, and one whose chat has '
        'gone does not', () async {
      final state = await boot();
      await state.send('hello');
      final id = state.active.id;
      state.setResponseHint(id, 'HINT_TOKEN');
      state.setResponseHint('a-chat-that-is-gone', 'STALE_TOKEN');
      await state.saveResponseHints();

      final next = AppState();
      await next.init();
      expect(next.responseHint(id), 'HINT_TOKEN');
      expect(next.responseHint('a-chat-that-is-gone'), isEmpty);
    });

    test('deleting a chat forgets its hint', () async {
      final state = await boot();
      await state.send('hello');
      final id = state.active.id;
      state.setResponseHint(id, 'HINT_TOKEN');
      await state.saveResponseHints();

      await state.deleteConversation(id);
      expect(state.responseHint(id), isEmpty);
    });

    test('a branch carries the hint it was branched under', () async {
      final state = await boot();
      await state.send('hello');
      final source = state.active.id;
      state.setResponseHint(source, 'HINT_TOKEN');

      final fork = await state.forkConversation(source, 0);
      expect(state.responseHint(fork), 'HINT_TOKEN');
      expect(state.responseHint(source), 'HINT_TOKEN');
    });

    test('a chat with no preset at all still carries its hint, at depth',
        () async {
      final state = await boot();
      await state.updateChatInterface(state.chatInterface
          .copyWith(responseHintEnabled: true, responseHintDepth: 1));
      // A fresh install seeds a default preset; this test is about the flat path
      // taken when there is none at all.
      for (final preset in state.presets.toList()) {
        await state.deletePreset(preset.id);
      }
      expect(state.presetFor(state.active), isNull,
          reason: 'this test is about the no-preset path');
      await state.send('one');
      await state.send('two');
      state.setResponseHint(state.active.id, 'HINT_TOKEN');

      final assembled = state.assemblePromptForMessage(
          state.active, state.active.messages.length);
      final at =
          assembled.messages.indexWhere((m) => m.content.contains('HINT_TOKEN'));
      expect(at, isNot(-1));
      // One turn follows it — the newest reply.
      final fromHint =
          assembled.messages.skip(at + 1).map((m) => m.content).join('\n');
      expect(fromHint, contains('Very well.'));
      // The hint went out as a user turn, not as a stray system message adrift
      // in the conversation (a plain chat with no character has no leading
      // system block at all here).
      expect(assembled.messages[at].role, 'user');
      expect(
          assembled.messages.where(
              (m) => m.role == 'system' && m.content.contains('HINT_TOKEN')),
          isEmpty);
      expect(assembled.sections.map((s) => s.label),
          contains('Response hint (depth 1)'));
    });
  });

  group('on the wire', () {
    late HttpServer server;
    Map<String, dynamic>? captured;

    Future<AppState> boot() async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      captured = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        if (request.method == 'POST') {
          captured = jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
        }
        request.response.headers.contentType =
            ContentType('text', 'event-stream');
        request.response.write('data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': 'ok'}
                }
              ]
            })}\n\n');
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });

      final state = AppState(); // the real ChatClient
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
        apiKey: 'k',
      ));
      await state.updateChatInterface(
          state.chatInterface.copyWith(responseHintEnabled: true));
      return state;
    }

    tearDown(() => server.close(force: true));

    test('the hint is in the request that leaves the app, and stays for the '
        'one after it', () async {
      final state = await boot();
      await state.send('hello');
      state.setResponseHint(state.active.id, 'HINT_TOKEN keep it short');

      await state.send('and again');
      expect(jsonEncode(captured), contains('HINT_TOKEN keep it short'));

      // Sending does not consume it: the next request carries it too. This is
      // the whole point of a hint over an out-of-band message.
      await state.send('once more');
      expect(jsonEncode(captured), contains('HINT_TOKEN keep it short'));

      // And the wire still holds exactly one system message, at position 0.
      final msgs =
          ((captured?['messages'] as List?) ?? const []).cast<Map<String, dynamic>>();
      expect(msgs.where((m) => m['role'] == 'system').length, 1);
      expect(msgs.first['role'], 'system');
    });

    test('a hint erased is a hint gone from the wire', () async {
      final state = await boot();
      await state.send('hello');
      state.setResponseHint(state.active.id, 'HINT_TOKEN');
      await state.send('with the hint');
      expect(jsonEncode(captured), contains('HINT_TOKEN'));

      state.setResponseHint(state.active.id, '');
      await state.send('without it');
      expect(jsonEncode(captured), isNot(contains('HINT_TOKEN')));
    });
  });
}
