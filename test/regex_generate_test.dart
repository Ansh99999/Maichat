import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/regex_rule.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The real [AppState] + [ChatClient] over a loopback server that always replies
/// with the word "ok" — so a permanent AI-output regex rule that rewrites "ok"
/// proves the finalize path actually applies the rule.
void main() {
  late HttpServer server;

  Future<AppState> boot() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
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

  test('a permanent AI-output rule rewrites a newly generated reply', () async {
    final state = await boot();
    final card = Character(id: 'c', name: 'Aria');
    await state.addCharacter(card);
    state.startChatWithCharacter(card);

    await state.saveRegexRule(RegexRule(
      id: 'r',
      name: 'shout',
      find: '/ok/gi',
      replace: 'REGEXED',
      placement: [RegexTarget.aiOutput.code],
    ));

    await state.send('hello');

    final messages = state.active.messages;
    final reply = messages.lastWhere((m) => !m.isUser);
    expect(reply.content, 'REGEXED');
  });

  test('a permanent user-input rule rewrites the stored user turn', () async {
    final state = await boot();
    final card = Character(id: 'c', name: 'Aria');
    await state.addCharacter(card);
    state.startChatWithCharacter(card);

    await state.saveRegexRule(RegexRule(
      id: 'r',
      name: 'redact',
      find: '/secret/gi',
      replace: '[redacted]',
      placement: [RegexTarget.userInput.code],
    ));

    await state.send('my secret plan');

    final userTurn = state.active.messages.firstWhere((m) => m.isUser);
    expect(userTurn.content, 'my [redacted] plan');
  });
}
