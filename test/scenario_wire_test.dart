import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/message.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/scenario.dart';
import 'package:maichat/services/chat_client.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the three routes to a scenario actually put on the wire.
///
/// A scenario is only worth having if the model is told about it, and there are
/// three ways it can arrive (the character's card, a library scenario plugged
/// into the chat, one written for the chat) crossed with four shapes of preset
/// (one with a scenario marker, one with the rest of the definition but no
/// scenario marker, one with no definition markers at all, and no preset). Every
/// combination is asserted on the request rather than on the assembly, because
/// this is exactly the kind of feature that assembles beautifully and sends
/// nothing.
class _CaptureClient extends ChatClient {
  List<ChatMessage>? lastHistory;

  @override
  Stream<ChatDelta> streamChat({
    required Provider provider,
    required List<ChatMessage> history,
    GenParams params = const GenParams(),
  }) async* {
    lastHistory = history;
    yield const ChatDelta(text: 'ok');
  }

  @override
  Future<List<String>> listModels(Provider provider) async => const [];
}

const String kCard = 'CARD_SCEN a market at dawn.';
const String kLib = 'LIB_SCEN snowed in at the station.';
const String kOwn = 'OWN_SCEN a bright roof at noon.';

/// The four preset shapes under test.
enum _Shape { withMarker, withoutScenarioMarker, noDefinitionMarkers, noPreset }

Character _alice() => Character(
      id: 'alice',
      name: 'Alice',
      description: 'A curious explorer.',
      personality: 'Bold and kind.',
      scenario: kCard,
    );

Scenario _library({bool replace = true}) => Scenario(
      id: 'lib',
      name: 'Snowed in',
      text: kLib,
      overwriteCharacterScenario: replace,
    );

String _dump(List<ChatMessage>? h) => (h ?? const <ChatMessage>[])
    .map((m) => '[${m.role}] ${m.content}')
    .join('\n');

Future<(AppState, _CaptureClient)> _boot(_Shape shape) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final client = _CaptureClient();
  final state = AppState(client: client);
  await state.init();
  await state.addProvider(Provider(
    id: 'p',
    name: 'p',
    kind: ProviderKind.openai,
    baseUrl: 'https://example.com/v1',
    model: 'gpt',
    apiKey: 'k',
  ));

  switch (shape) {
    case _Shape.withMarker:
      // The stock preset already carries every definition marker.
      final preset = Preset.create(name: 'Full');
      await state.addPreset(preset);
      await state.setDefaultPreset(preset.id);
    case _Shape.withoutScenarioMarker:
      final preset = Preset.create(name: 'No scenario slot')
        ..promptOrder.removeWhere((e) => e.identifier == PromptId.scenario);
      await state.addPreset(preset);
      await state.setDefaultPreset(preset.id);
    case _Shape.noDefinitionMarkers:
      final preset = Preset.create(name: 'Minimal')
        ..promptOrder.clear()
        ..promptOrder.addAll([
          PromptOrderEntry(identifier: PromptId.main),
          PromptOrderEntry(identifier: PromptId.chatHistory),
        ]);
      await state.addPreset(preset);
      await state.setDefaultPreset(preset.id);
    case _Shape.noPreset:
      // The flat, preset-less path: strip the seeded default so nothing resolves.
      for (final p in state.presets) {
        await state.deletePreset(p.id);
      }
  }
  return (state, client);
}
void main() {
  /// Sends one turn and returns the whole outgoing request as text.
  Future<String> sent(
    _Shape shape, {
    Scenario? library,
    bool plugIn = false,
    String own = '',
  }) async {
    final (state, client) = await _boot(shape);
    if (library != null) await state.addScenario(library);
    final alice = _alice();
    await state.addCharacter(alice);
    final chatId = state.startChatWithCharacter(alice);
    if (plugIn || own.isNotEmpty) {
      await state.setChatScenario(
        chatId,
        scenarioId: plugIn ? library?.id : null,
        text: own,
      );
    }
    await state.send('Who are you?');
    return _dump(client.lastHistory);
  }

  group('the matrix', () {
    // Every preset shape, every route in. The expectations differ per shape only
    // where they must: a preset with no scenario slot has never carried the
    // *card's* scenario, and that is left exactly as it was.
    for (final shape in _Shape.values) {
      final marker = shape == _Shape.withMarker;

      group(shape.name, () {
        test('with nothing chosen, the card\'s scenario is what travels',
            () async {
          final wire = await sent(shape);
          if (marker ||
              shape == _Shape.noDefinitionMarkers ||
              shape == _Shape.noPreset) {
            expect(wire, contains(kCard));
          } else {
            // Unchanged long-standing behaviour: no scenario slot, no scenario.
            expect(wire, isNot(contains(kCard)));
          }
          expect(wire, isNot(contains(kLib)));
          expect(wire, isNot(contains(kOwn)));
        });

        test('a plugged-in scenario that replaces sets the card aside',
            () async {
          final wire = await sent(shape, library: _library(), plugIn: true);
          expect(wire, contains(kLib));
          expect(wire, isNot(contains(kCard)),
              reason: "the card's scenario reached the model as well");
          expect(wire, isNot(contains(kOwn)));
        });

        test('a plugged-in scenario that adds to it sends both', () async {
          final wire = await sent(
            shape,
            library: _library(replace: false),
            plugIn: true,
          );
          expect(wire, contains(kLib));
          expect(wire, contains(kCard));
        });

        test('one written for this chat wins over everything', () async {
          final wire = await sent(
            shape,
            library: _library(),
            plugIn: true,
            own: kOwn,
          );
          expect(wire, contains(kOwn));
          expect(wire, isNot(contains(kLib)));
          expect(wire, isNot(contains(kCard)));
        });
      });
    }
  });

  group('resolution', () {
    test('the ranked order, read straight off AppState', () async {
      final (state, _) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await state.addCharacter(alice);
      await state.addScenario(_library());
      final chatId = state.startChatWithCharacter(alice);
      final chat = state.conversationById(chatId)!;

      expect(state.scenarioFor(chat, alice), kCard);
      expect(state.scenarioSourceFor(chat), "The character's own");

      await state.setChatScenario(chatId, scenarioId: 'lib');
      expect(state.scenarioFor(chat, alice), kLib);
      expect(state.scenarioSourceFor(chat), 'Snowed in');

      await state.setChatScenario(chatId, scenarioId: 'lib', text: kOwn);
      expect(state.scenarioFor(chat, alice), kOwn);
      expect(state.scenarioSourceFor(chat), 'Written for this chat');

      await state.clearChatScenario(chatId);
      expect(state.scenarioFor(chat, alice), kCard);
      expect(chat.hasScenarioOfItsOwn, isFalse);
    });

    test('a character with no scenario at all resolves to nothing', () async {
      final (state, _) = await _boot(_Shape.withMarker);
      final bare = Character(id: 'b', name: 'Bare');
      await state.addCharacter(bare);
      final chatId = state.startChatWithCharacter(bare);
      expect(state.scenarioFor(state.conversationById(chatId), bare), isEmpty);
    });

    test('a blank library scenario does not blank out the card\'s', () async {
      final (state, _) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await state.addCharacter(alice);
      await state.addScenario(Scenario(id: 'empty', name: 'Empty', text: '  '));
      final chatId = state.startChatWithCharacter(alice);
      await state.setChatScenario(chatId, scenarioId: 'empty');
      expect(state.scenarioFor(state.conversationById(chatId), alice), kCard);
    });
  });
  group('the library and the chats using it', () {
    test('deleting a scenario unplugs it and the card takes over', () async {
      final (state, client) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await state.addCharacter(alice);
      await state.addScenario(_library());
      final chatId = state.startChatWithCharacter(alice);
      await state.setChatScenario(chatId, scenarioId: 'lib');

      await state.deleteScenario('lib');
      expect(state.conversationById(chatId)!.scenarioId, isNull);
      await state.send('Who are you?');
      final wire = _dump(client.lastHistory);
      expect(wire, contains(kCard));
      expect(wire, isNot(contains(kLib)));
    });

    test('a chat that had edited it keeps its own copy after the delete',
        () async {
      final (state, _) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await state.addCharacter(alice);
      await state.addScenario(_library());
      final chatId = state.startChatWithCharacter(alice);
      await state.setChatScenario(chatId, scenarioId: 'lib', text: kOwn);

      await state.deleteScenario('lib');
      expect(state.scenarioFor(state.conversationById(chatId), alice), kOwn);
    });

    test('editing the library scenario reaches the chat plugged into it',
        () async {
      final (state, _) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await state.addCharacter(alice);
      final scenario = _library();
      await state.addScenario(scenario);
      final chatId = state.startChatWithCharacter(alice);
      await state.setChatScenario(chatId, scenarioId: 'lib');

      await state.saveScenario(scenario.copyWith(text: 'REWRITTEN.'));
      expect(state.scenarioFor(state.conversationById(chatId), alice),
          'REWRITTEN.');
    });

    test('a scenario, and the chat pointing at it, survive a restart',
        () async {
      final (first, _) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await first.addCharacter(alice);
      await first.addScenario(_library(replace: false));
      final chatId = first.startChatWithCharacter(alice);
      await first.setChatScenario(chatId, scenarioId: 'lib');

      final second = AppState(client: _CaptureClient());
      await second.init();
      final chat = second.conversationById(chatId);
      expect(chat, isNotNull);
      expect(chat!.scenarioId, 'lib');
      expect(second.scenarioById('lib')!.overwriteCharacterScenario, isFalse);
      expect(second.scenarioFor(chat, second.characterById('alice')),
          '$kCard\n\n$kLib');
    });

    test('a fork carries the chat\'s scenario with it', () async {
      final (state, _) = await _boot(_Shape.withMarker);
      final alice = _alice();
      await state.addCharacter(alice);
      await state.addScenario(_library());
      final chatId = state.startChatWithCharacter(alice);
      await state.setChatScenario(chatId, scenarioId: 'lib', text: kOwn);
      await state.send('hello');

      final forkId = await state.forkConversation(chatId, 0);
      final fork = state.conversationById(forkId)!;
      expect(fork.scenarioId, 'lib');
      expect(fork.scenarioOverride, kOwn);
    });
  });

  group('the real wire', () {
    late HttpServer server;
    Map<String, dynamic>? captured;

    tearDown(() => server.close(force: true));

    test('the chosen scenario is in the JSON that leaves the app', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
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

      // The real ChatClient, over a real socket.
      final state = AppState();
      await state.init();
      await state.addProvider(Provider(
        id: 'p',
        name: 'local',
        kind: ProviderKind.openai,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'test-model',
        apiKey: 'k',
      ));
      final alice = _alice();
      await state.addCharacter(alice);
      await state.addScenario(_library());
      final chatId = state.startChatWithCharacter(alice);
      await state.setChatScenario(chatId, scenarioId: 'lib');
      await state.send('Who are you?');

      final messages =
          ((captured?['messages'] as List?) ?? const []).cast<Map>();
      expect(messages, isNotEmpty, reason: 'a request must have been sent');
      final body = messages.map((m) => '${m['content']}').join('\n');
      expect(body, contains(kLib));
      expect(body, isNot(contains(kCard)));
      // The one-leading-system invariant still holds with a scenario in play.
      final systems = messages.where((m) => m['role'] == 'system').toList();
      expect(systems.length, 1);
      expect(messages.first['role'], 'system');
      expect('${messages.first['content']}', contains(kLib));
    });
  });
}
