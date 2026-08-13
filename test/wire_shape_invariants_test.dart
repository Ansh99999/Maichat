import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/services/preset_io.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Properties the outgoing request must hold for EVERY preset, not only the one
/// that happened to expose a bug. Each case drives a real [AppState] through the
/// real [ChatClient] to a loopback socket, so these assert on the JSON that
/// leaves the app.
///
/// Two groups, deliberately separated:
///
///  * UNIVERSAL — true of any correct client, whatever policy it adopts. Safe to
///    freeze forever. The content-loss check is the important one: it fails when
///    prompt content goes missing for *any* reason, including causes nobody has
///    thought of yet.
///  * POLICY — MaiChat's host-compatibility choice, verified against SillyTavern
///    `release` @ 8172dcd: exactly what its Prompt Post-Processing "Strict" mode
///    does (`src/prompt-converters.js:932-947`, "Force mid-prompt system messages
///    to be user messages") and what its native Claude conversion always does
///    (`src/prompt-converters.js:232-268`). SillyTavern leaves it OFF by default
///    for OpenAI-format targets, so this is a divergence in default, not in
///    semantics. Change this group only with that context in hand.
void main() {
  late HttpServer server;
  Map<String, dynamic>? captured;

  setUpAll(() async {
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
  });

  tearDownAll(() => server.close(force: true));

  Preset fixture(String name) => importPreset(
        jsonDecode(File('test/fixtures/$name').readAsStringSync())
            as Map<String, dynamic>,
      );

  /// Every definition marker switched off — the shape that used to lose the
  /// character sheet entirely.
  Preset definitionsDisabled() {
    final preset = Preset.create(name: 'DefsOff');
    const markers = {
      PromptId.charDescription,
      PromptId.charPersonality,
      PromptId.scenario,
      PromptId.dialogueExamples,
    };
    for (final e in preset.promptOrder) {
      if (markers.contains(e.identifier)) e.enabled = false;
    }
    return preset;
  }

  /// Depth injections of every role at two depths, to exercise the placement and
  /// role-normalisation path rather than the all-`system` case Marinara covers.
  Preset mixedRoleInjections() {
    final preset = Preset.create(name: 'Mixed');
    var i = 0;
    for (final role in ['system', 'user', 'assistant']) {
      for (final depth in [0, 1]) {
        final id = 'inj_${role}_$depth';
        preset.prompts.add(PromptBlock(
          identifier: id,
          name: id,
          role: role,
          content: 'INJECT_${role.toUpperCase()}_$depth',
          injectionPosition: InjectionPosition.absolute,
          injectionDepth: depth,
          injectionOrder: 100 - i++,
        ));
        preset.promptOrder.add(PromptOrderEntry(identifier: id));
      }
    }
    return preset;
  }

  final cases = <String, Preset Function()>{
    'built-in default': () => Preset.create(name: 'Default'),
    'SillyTavern default export': () => fixture('st_openai_default.json'),
    "Marinara's Spaghetti": () => fixture('marinara_spaghetti.json'),
    'definition markers disabled': definitionsDisabled,
    'mixed-role depth injections': mixedRoleInjections,
  };

  /// Literal (macro-free) content of every enabled non-marker block. Each must
  /// survive assembly verbatim — this is the content-loss tripwire.
  ///
  /// Only the legacy angle-bracket macros are excluded, not every `<`: the tag
  /// blocks a framing preset is built from (`<role>`, `</lore>`, …) are precisely
  /// the ones most likely to be dropped silently, so they must stay in scope.
  Iterable<String> literalBlocks(Preset preset) {
    final legacyMacro =
        RegExp(r'<(USER|BOT|CHAR|GROUP|CHARIFNOTGROUP)>', caseSensitive: false);
    final out = <String>[];
    for (final entry in preset.promptOrder) {
      if (!entry.enabled) continue;
      final block = preset.blockById(entry.identifier);
      if (block == null || block.marker) continue;
      final content = block.content.trim();
      if (content.isEmpty ||
          content.contains('{{') ||
          legacyMacro.hasMatch(content)) {
        continue; // rewritten by the macro engine by design
      }
      out.add(content);
    }
    return out;
  }

  for (final entry in cases.entries) {
    test('wire invariants — ${entry.key}', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      captured = null;
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
      final preset = entry.value();
      await state.addPreset(preset);
      await state.setDefaultPreset(preset.id);

      final card = Character(
        id: 'c',
        name: 'Shiori',
        description: 'DESC_TOKEN a maid.',
        personality: 'PERS_TOKEN devoted.',
        scenario: 'SCEN_TOKEN a manor.',
        mesExample: 'EXAMPLE_TOKEN Shiori: yes, master.',
        firstMes: 'GREET_TOKEN welcome home.',
      );
      await state.addCharacter(card);
      state.startChatWithCharacter(card);
      await state.send('HIST_ONE hello');
      await state.send('HIST_TWO who are you?');

      final msgs = ((captured?['messages'] as List?) ?? const [])
          .cast<Map<String, dynamic>>();
      expect(msgs, isNotEmpty, reason: 'a request must have been sent');
      final joined = msgs.map((m) => m['content'] as String).join('\n');

      // --- UNIVERSAL ------------------------------------------------------
      for (var i = 1; i < msgs.length; i++) {
        expect(msgs[i]['role'], isNot(msgs[i - 1]['role']),
            reason: 'adjacent turns at $i share a role');
      }
      for (final token in ['GREET_TOKEN', 'HIST_ONE', 'HIST_TWO']) {
        expect(joined, contains(token), reason: '$token was dropped');
      }
      expect(joined.indexOf('HIST_ONE'), lessThan(joined.indexOf('HIST_TWO')),
          reason: 'history must stay chronological');
      for (final content in literalBlocks(preset)) {
        expect(joined, contains(content),
            reason: 'a preset block was lost: '
                '${content.length > 40 ? '${content.substring(0, 40)}…' : content}');
      }
      expect(joined, isNot(contains('{{')),
          reason: 'unresolved macros must not be sent as literal text');
      for (final m in msgs) {
        expect((m['content'] as String).trim(), isNotEmpty,
            reason: 'empty turns must not be sent');
        expect(const ['system', 'user', 'assistant'], contains(m['role']));
      }

      // --- POLICY ---------------------------------------------------------
      final systems = msgs.where((m) => m['role'] == 'system').toList();
      expect(systems.length, lessThanOrEqualTo(1),
          reason: 'at most one system message');
      if (systems.isNotEmpty) {
        expect(msgs.first['role'], 'system',
            reason: 'the system message must lead the request');
      }
    });
  }

  test('the definition reaches the model under every preset', () async {
    // Narrower than the invariants above, and the thing the user actually cares
    // about: whichever preset is active, the character sheet is in the payload.
    for (final entry in cases.entries) {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      captured = null;
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
      final preset = entry.value();
      await state.addPreset(preset);
      await state.setDefaultPreset(preset.id);
      final card = Character(
        id: 'c',
        name: 'Shiori',
        description: 'DESC_TOKEN a maid.',
        personality: 'PERS_TOKEN devoted.',
      );
      await state.addCharacter(card);
      state.startChatWithCharacter(card);
      await state.send('who are you?');

      final whole = jsonEncode(captured);
      expect(whole, contains('DESC_TOKEN'),
          reason: 'description missing under "${entry.key}"');
      expect(whole, contains('PERS_TOKEN'),
          reason: 'personality missing under "${entry.key}"');
    }
  });
}
