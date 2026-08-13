import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/preset_io.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A heavy preset frame plus a large character sheet used to consume the whole
/// context budget, so chat history was silently truncated to nothing: the model
/// received the instructions and the newest message only — no greeting, no prior
/// turns. Reproduced with the real "Marinara's Spaghetti" preset (a partial
/// export, so it imports with the era-old 4095 default) and a character sheet
/// the size of a real V3 card.
void main() {
  late HttpServer server;
  Map<String, dynamic>? captured;

  /// A character sheet as large as a real card's (~8.5 KB of JSON).
  String bigSheet() {
    final traits = [
      for (var i = 0; i < 90; i++)
        '    "Trait$i": "SHEET_BODY a long descriptive clause about the '
            'character, entry number $i, padded to resemble a real sheet."'
    ].join(',\n');
    return '{\n  "Character Sheet": {\n$traits\n  }\n}';
  }

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
    return state;
  }

  tearDown(() => server.close(force: true));

  test('a heavy frame plus a big sheet still sends the conversation', () async {
    final state = await boot();
    final preset = importPreset(jsonDecode(
      File('test/fixtures/marinara_spaghetti.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    // The preset omits openai_max_context, so it lands on the old 4095 that
    // triggered the starvation. Pin it so this test keeps reproducing the case
    // regardless of what the default becomes.
    preset.maxContext = 4095;
    await state.addPreset(preset);
    await state.setDefaultPreset(preset.id);

    final card = Character(
      id: 'k',
      name: 'Kallen',
      description: bigSheet(),
      firstMes: 'GREETING_TOKEN the camp is quiet tonight.',
    );
    expect(card.description.length, greaterThan(8000));

    await state.addCharacter(card);
    state.startChatWithCharacter(card);
    await state.send('TURN_ONE my name is Ansh.');
    await state.send('TURN_TWO what is my name?');

    final whole = jsonEncode(captured);
    // The definition still rides in the first system message.
    final msgs = ((captured?['messages'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    expect(msgs.firstWhere((m) => m['role'] == 'system')['content'] as String,
        contains('SHEET_BODY'));
    // ...and the conversation is not starved away.
    expect(whole, contains('GREETING_TOKEN'),
        reason: 'the greeting must survive a heavy frame');
    expect(whole, contains('TURN_ONE'),
        reason: 'prior turns must survive a heavy frame');
    expect(whole, contains('TURN_TWO'));
  });

  test('a preset omitting the context size imports with a modern default', () {
    final preset = importPreset(jsonDecode(
      File('test/fixtures/marinara_spaghetti.json').readAsStringSync(),
    ) as Map<String, dynamic>);
    expect(preset.maxContext, Preset.defaultMaxContext);
    expect(Preset.defaultMaxContext, greaterThanOrEqualTo(32768));
  });
}
