import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/preset_io.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// End-to-end coverage of the *actual wire payload*: a real [AppState] driving
/// the real [ChatClient] over a loopback server, so these assertions are on the
/// JSON that leaves the app — not on an intermediate representation.
///
/// This exists because a preset can assemble perfectly and still fail in the
/// real world: the "Marinara's Spaghetti" preset frames the prompt with dozens
/// of tiny blocks, which used to leave as ~38 separate `system` messages whose
/// first one was a bare `<role>` tag. Any host that honours only the first
/// system message then saw none of the character definition.
void main() {
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
    final preset = importPreset(jsonDecode(
      File('test/fixtures/marinara_spaghetti.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    await state.addPreset(preset);
    await state.setDefaultPreset(preset.id);
    return state;
  }

  tearDown(() => server.close(force: true));

  Character alice() => Character(
        id: 'alice',
        name: 'Alice',
        description: 'DESC_TOKEN a curious explorer.',
        personality: 'PERS_TOKEN bold and kind.',
        scenario: 'SCEN_TOKEN a market at dawn.',
        firstMes: 'GREET_TOKEN hello there.',
        mesExample: 'EXAMPLE_TOKEN Alice: Onward!',
      );

  List<Map<String, dynamic>> wireMessages() =>
      ((captured?['messages'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();

  test('the definition rides in the FIRST system message on the wire',
      () async {
    final state = await boot();
    final character = alice();
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.send('Who are you?');

    final msgs = wireMessages();
    expect(msgs, isNotEmpty, reason: 'a request must have been sent');

    final firstSystem = msgs.firstWhere((m) => m['role'] == 'system');
    final content = firstSystem['content'] as String;
    expect(content, contains('DESC_TOKEN'));
    expect(content, contains('PERS_TOKEN'));
    expect(content, contains('SCEN_TOKEN'));
    expect(content, contains('EXAMPLE_TOKEN'));

    // Not fragmented into dozens of turns, and never two same-role in a row.
    expect(msgs.length, lessThan(12));
    for (var i = 1; i < msgs.length; i++) {
      expect(msgs[i]['role'], isNot(msgs[i - 1]['role']),
          reason: 'adjacent wire turns at $i share a role');
    }
  });

  test('a full conversation reaches the wire: greeting and every turn',
      () async {
    final state = await boot();
    final character = alice();
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.send('TURN_ONE my name is Ansh.');
    await state.send('TURN_TWO remember it?');
    await state.send('TURN_THREE what is my name?');

    final whole = jsonEncode(captured);
    for (final token in [
      'GREET_TOKEN',
      'TURN_ONE',
      'TURN_TWO',
      'TURN_THREE',
      'DESC_TOKEN',
    ]) {
      expect(whole, contains(token), reason: '$token must reach the model');
    }
  });

  test('no unresolved macro braces leak into the payload', () async {
    final state = await boot();
    final character = alice();
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.send('hi');

    for (final m in wireMessages()) {
      expect(m['content'] as String, isNot(contains('{{')),
          reason: 'unresolved macros must not be sent as literal text');
    }
  });

  test('exactly one system message, at the front, carrying the definition',
      () async {
    // The framing this preset injects at a chat depth (</chat_history>,
    // <last_message>, and a trailing <task>/<output_format>) used to be sent as
    // `system` messages scattered after the conversation. A host that folds
    // several system messages into one field could then keep only the last —
    // the task block — so the model was told to roleplay with no sheet, read the
    // chat for clues, and reported having no character definition. The same
    // character worked under a preset with no depth injections, which is what
    // pinned it down.
    final state = await boot();
    final character = alice();
    await state.addCharacter(character);
    state.startChatWithCharacter(character);
    await state.send('TURN_ONE hi');
    await state.send('TURN_TWO who are you?');

    final msgs = wireMessages();
    final systems = msgs.where((m) => m['role'] == 'system').toList();
    expect(systems.length, 1, reason: 'exactly one system message');
    expect(msgs.first['role'], 'system', reason: 'and it leads the request');
    expect(systems.single['content'] as String, contains('DESC_TOKEN'));

    // The in-chat framing still travels, still in place, as a user turn — the
    // task block stays last so it is the freshest instruction before generation.
    final last = msgs.last;
    expect(last['role'], 'user');
    expect(last['content'] as String, contains('<task>'));
    expect(last['content'] as String, contains('TURN_TWO'));

    for (var i = 1; i < msgs.length; i++) {
      expect(msgs[i]['role'], isNot(msgs[i - 1]['role']));
    }
  });
}
