import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/folder.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/models/provider.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/studio/studio_controller.dart';
import 'package:maichat/services/studio/studio_store.dart';
import 'package:maichat/state/app_state.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Plain tests: a widget binding would intercept the real loopback requests.
void main() {
  late Directory directory;
  late HttpServer server;
  late AppState state;
  late List<Map<String, dynamic>> requests;
  late List<Map<String, dynamic>> script;

  Map<String, dynamic> words(String text) => {
    'choices': [
      {
        'delta': {'content': text},
      },
    ],
  };

  Map<String, dynamic> tool(
    String id,
    String name,
    Map<String, dynamic> args,
  ) => {
    'choices': [
      {
        'delta': {
          'tool_calls': [
            {
              'index': 0,
              'id': id,
              'type': 'function',
              'function': {'name': name, 'arguments': jsonEncode(args)},
            },
          ],
        },
      },
    ],
  };

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('studio_presets');
    requests = [];
    script = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>;
      requests.add(body);
      final event = script.isEmpty
          ? words('The lantern is lit.')
          : script.removeAt(0);
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
      );
      request.response.write('data: ${jsonEncode(event)}\n\ndata: [DONE]\n\n');
      await request.response.close();
    });
    state = AppState();
    await state.init();
    await state.addProvider(
      Provider(
        id: 'local',
        name: 'Loopback',
        kind: ProviderKind.openai,
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'chat-model',
        apiKey: 'test-key',
      ),
    );
  });

  tearDown(() async {
    state.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  StudioController controllerFor(StudioSession session) {
    final controller = StudioController(
      state: state,
      store: StudioStore(directory),
      session: session,
    );
    addTearDown(() async {
      await controller.flush();
      controller.dispose();
    });
    return controller;
  }

  StudioSession draft() => newStudioSession()
    ..workspace.character.name = 'Maren'
    ..workspace.character.description = 'CARD_MARKER: keeper of the lighthouse'
    ..workspace.character.firstMes = 'You came back.';

  List<Map> messages(Map<String, dynamic> body) =>
      (body['messages'] as List).cast<Map>();

  void expectWire(
    Map<String, dynamic> body,
    String marker,
    double temperature,
  ) {
    expect(body['temperature'], temperature);
    expect(messages(body).first['role'], 'system');
    expect(messages(body).where((m) => m['role'] == 'system'), hasLength(1));
    expect(jsonEncode(messages(body)), contains(marker));
    expect(jsonEncode(messages(body)), contains('CARD_MARKER'));
  }

  test(
    'preset drafts survive save and rewind, including empty prompts and nested imports',
    () async {
      final session = draft();
      final preset = Preset(
        id: 'p',
        name: 'Imported',
        prompts: [],
        promptOrder: [],
        raw: {
          'plugin': {
            'values': [1, 2],
          },
        },
      );
      final controller = controllerFor(session);
      controller.editByHand('Load preset', (ws) => ws.preset = preset.clone());
      controller.editByHand(
        'Change preset',
        (ws) => ws.preset!.temperature = 0.4,
      );
      ((session.workspace.preset!.raw['plugin'] as Map)['values'] as List).add(
        3,
      );
      expect(((preset.raw['plugin'] as Map)['values'] as List), [1, 2]);
      await controller.flush();
      final reloaded = (await StudioStore(directory).read(session.id))!;
      expect(reloaded.workspace.preset!.temperature, 0.4);
      expect(reloaded.workspace.preset!.prompts, isEmpty);
      expect(reloaded.workspace.preset!.promptOrder, isEmpty);
      reloaded.rewindTo(1);
      expect(reloaded.workspace.preset!.temperature, 1);
      expect(reloaded.workspace.preset!.raw, preset.raw);
      reloaded.rewindTo(0);
      expect(reloaded.workspace.preset, isNull);
      final legacy = session.toJson();
      (legacy['workspace'] as Map).remove('preset');
      expect(StudioSession.fromJson(legacy).workspace.preset, isNull);
    },
  );

  test(
    'the model loads and edits a preset, playtests the real wire, then Apply saves it',
    () async {
      final selected = Preset(id: 'selected', name: 'Lighthouse')
        ..temperature = 0.2
        ..maxContext = 8192;
      selected.blockById('main')!.content = 'ORIGINAL_PRESET';
      await state.addPreset(selected);
      final originalDefault = state.defaultPresetId;
      final blocks = selected.prompts.map((p) => p.toJson()).toList();
      blocks.firstWhere((b) => b['identifier'] == 'main')['content'] =
          'EDITED_PRESET for {{char}}';
      blocks.add(
        PromptBlock(
          identifier: 'tail',
          name: 'Tail',
          role: 'system',
          content: 'TAIL_MARKER',
          injectionPosition: InjectionPosition.absolute,
          injectionDepth: 0,
        ).toJson(),
      );
      script = [
        tool('list', 'list_presets', {}),
        tool('load', 'load_preset', {'id': selected.id}),
        tool('edit', 'update_preset', {
          'changes': {
            'temperature': 0.65,
            'maxResponseTokens': 777,
            'prompts': blocks,
            'promptOrder': [
              ...selected.promptOrder.map((e) => e.toJson()),
              {'identifier': 'tail', 'enabled': true},
            ],
          },
        }),
        tool('size', 'count_tokens', {
          'parts': ['prompt'],
        }),
        tool('play', 'playtest', {
          'messages': ['Is the lamp safe?'],
        }),
        words('It is safe tonight.'),
        words('The preset is ready for review.'),
      ];
      final session = draft();
      final controller = controllerFor(session);
      await controller.send(
        'Load Lighthouse, improve its prompt, and playtest it.',
      );
      expect(controller.notice, isNull);
      expect(script, isEmpty);
      expect(session.workspace.preset!.temperature, 0.65);
      expect(state.presetById(selected.id)!.temperature, 0.2);
      expect(
        state.presetById(selected.id)!.blockById('main')!.content,
        'ORIGINAL_PRESET',
      );
      final playRequest = requests.singleWhere((r) => !r.containsKey('tools'));
      expectWire(playRequest, 'EDITED_PRESET for Maren', 0.65);
      expect(playRequest['max_tokens'], 777);
      expect(jsonEncode(playRequest), contains('TAIL_MARKER'));
      expect(jsonEncode(playRequest), isNot(contains('ORIGINAL_PRESET')));
      final results = (requests.last['messages'] as List).whereType<Map>();
      final size = results.singleWhere((m) => m['tool_call_id'] == 'size');
      expect(
        (jsonDecode(size['content'] as String) as Map)['prompt']['context'],
        8192,
      );
      expect(state.conversations, isEmpty);
      expect(
        controller.playtests.single.turns.last.text,
        'It is safe tonight.',
      );

      final result = await controller.apply(bundleFolder: true);
      expect(result.presetName, 'Lighthouse');
      expect(state.presetById(selected.id)!.temperature, 0.65);
      expect(state.defaultPresetId, originalDefault);
      expect(state.folders.single.presetIds, [selected.id]);
      expect(state.folders.single.defaultPresetId, selected.id);
      controller.editByHand(
        'Another adjustment',
        (ws) => ws.preset!.temperature = 0.8,
      );
      expect(state.presetById(selected.id)!.temperature, 0.65);
      await controller.flush();
      expect(
        (await StudioStore(
          directory,
        ).read(session.id))!.workspace.preset!.temperature,
        0.8,
      );
    },
  );

  test(
    'Playground sends follow preset edits, clearing and rewind without touching ordinary chats',
    () async {
      final defaultPreset = state.defaultPreset!;
      defaultPreset.blockById('main')!.content = 'DEFAULT_PRESET';
      await state.savePreset(defaultPreset);
      final selected = Preset(id: 'selected', name: 'Lighthouse')
        ..temperature = 0.3;
      selected.blockById('main')!.content = 'STUDIO_PRESET';
      final session = draft();
      final controller = controllerFor(session);
      controller.editByHand(
        'Load preset',
        (ws) => ws.preset = selected.clone(),
      );
      controller.playground.open();
      await state.send('Hello.');
      expectWire(requests.last, 'STUDIO_PRESET', 0.3);
      controller.editByHand('Edit preset', (ws) {
        ws.preset!.temperature = 0.7;
        ws.preset!.blockById('main')!.content = 'FRESH_PRESET';
      });
      await state.send('And now?');
      expectWire(requests.last, 'FRESH_PRESET', 0.7);
      expect(jsonEncode(requests.last), isNot(contains('STUDIO_PRESET')));
      controller.editByHand('Clear preset', (ws) => ws.preset = null);
      await state.send('Use the default.');
      expectWire(requests.last, 'DEFAULT_PRESET', defaultPreset.temperature);
      await controller.rewindTo(2);
      await state.send('Try again.');
      expectWire(requests.last, 'FRESH_PRESET', 0.7);
      final override = selected.clone()..temperature = 0.9;
      await state.saveChatPresetOverride(state.active.id, override);
      await state.send('With my chat settings.');
      expectWire(requests.last, 'STUDIO_PRESET', 0.9);
      expect(state.conversations, isEmpty);
      controller.playground.close();
      final ordinaryId = state.startChatWithCharacter(
        Character(id: 'ordinary', name: 'Other'),
      );
      expect(state.active.id, ordinaryId);
      expect(state.presetFor(state.active)!.id, defaultPreset.id);
      expect(
        state.presetFor(state.active)!.blockById('main')!.content,
        'DEFAULT_PRESET',
      );
    },
  );

  test(
    'standalone playtest and prompt sizing use the supplied preset without changing the default',
    () async {
      final preset = Preset(id: 'sizing', name: 'Sizing')
        ..maxContext = 4096
        ..temperature = 0.45;
      preset.blockById('main')!.content = 'DIRECT_PRESET';
      final character = draft().workspace.character;
      final before = state.defaultPresetId;
      final size = state.playtestPromptSize(
        character: character,
        preset: preset,
      );
      expect(size!.context, 4096);
      expect(requests, isEmpty);
      await state.playtestCharacter(
        character: character,
        preset: preset,
        userTurns: ['Hello.'],
      );
      expectWire(requests.single, 'DIRECT_PRESET', 0.45);
      expect(state.defaultPresetId, before);
      expect(state.conversations, isEmpty);
    },
  );

  test(
    'agent tests and Playground use the same folder connection and persona',
    () async {
      final session = draft();
      final character = session.workspace.character;
      final folderPreset = Preset(id: 'folder-preset', name: 'Folder preset')
        ..temperature = 0.15
        ..maxContext = 12345;
      folderPreset.blockById('main')!.content = 'FOLDER_PRESET';
      await state.savePreset(folderPreset);
      await state.addProvider(
        Provider(
          id: 'folder-provider',
          name: 'Folder connection',
          kind: ProviderKind.openai,
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'folder-model',
          apiKey: 'k',
        ),
      );
      await state.selectProvider('local');
      await state.saveFolder(
        Folder(
          id: 'folder',
          name: 'Lighthouse',
          characterIds: [character.id],
          presetIds: [folderPreset.id],
          defaultPresetId: folderPreset.id,
          providerIds: ['folder-provider'],
          defaultProviderId: 'folder-provider',
        ),
      );
      await state.addCharacter(
        Character(id: 'me', name: 'Ash', description: 'PERSONA_MARKER'),
      );
      await state.setDefaultPersona('me');
      final controller = controllerFor(session);
      final size = state.playtestPromptSize(character: character);
      expect(size!.context, 12345);
      await state.playtestCharacter(
        character: character,
        userTurns: ['Hello.'],
      );
      expectWire(requests.last, 'FOLDER_PRESET', 0.15);
      expect(requests.last['model'], 'folder-model');
      expect(jsonEncode(requests.last), contains('PERSONA_MARKER'));
      controller.playground.open();
      await state.send('Hello.');
      expectWire(requests.last, 'FOLDER_PRESET', 0.15);
      expect(requests.last['model'], 'folder-model');
      expect(jsonEncode(requests.last), contains('PERSONA_MARKER'));

      final preset = Preset(id: 'studio', name: 'Studio')
        ..temperature = 0.55
        ..providerId = 'local'
        ..model = 'stale-model';
      preset.blockById('main')!.content = 'SELECTED_PRESET';
      controller.editByHand('Load preset', (ws) => ws.preset = preset);
      await state.playtestCharacter(
        character: character,
        preset: preset,
        userTurns: ['Again.'],
      );
      expectWire(requests.last, 'SELECTED_PRESET', 0.55);
      expect(requests.last['model'], 'folder-model');
      await state.send('Again.');
      expectWire(requests.last, 'SELECTED_PRESET', 0.55);
      expect(requests.last['model'], 'folder-model');
    },
  );

  test(
    'applying into a session folder replaces a stale shadow of the same preset',
    () async {
      final session = draft()..folderId = 'bundle';
      final preset = Preset(id: 'p', name: 'Current')..temperature = 0.75;
      final other = Preset(id: 'other', name: 'Keep this override');
      session.workspace.preset = preset;
      await state.saveFolder(
        Folder(
          id: 'bundle',
          name: 'Bundle',
          presetIds: [preset.id, other.id],
          presetOverrides: {
            preset.id: preset.clone()..temperature = 0.1,
            other.id: other,
          },
        ),
      );
      final controller = controllerFor(session);
      await controller.apply(bundleFolder: true);
      final folder = state.folderById('bundle')!;
      expect(folder.presetOverrides.containsKey(preset.id), isFalse);
      expect(folder.presetOverrides[other.id], same(other));
      expect(state.folderPreset(folder, preset.id)!.temperature, 0.75);
    },
  );
}
