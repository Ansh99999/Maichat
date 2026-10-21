import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/character.dart';
import 'package:maichat/models/lorebook.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/models/studio.dart';
import 'package:maichat/services/studio/custom_agents.dart';
import 'package:maichat/services/studio/preset_tools.dart';
import 'package:maichat/services/studio/studio_tools.dart';

class _Services implements StudioServices {
  @override
  int countTokens(String text) => (text.length / 4).ceil();
  @override
  List<Character> get libraryCharacters => const [];
  @override
  List<Lorebook> get libraryLorebooks => const [];
  @override
  bool get canGenerateImages => false;
  @override
  Future<String> generatePicture({
    required String prompt,
    required String characterId,
  }) async => throw UnimplementedError();
  @override
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
    List<StudioPlaytestTurn> earlier = const [],
    String scenario = '',
  }) async => const [];
  @override
  Future<StudioTaskOutcome> runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  }) async => throw UnimplementedError();
}

class _PresetServices extends _Services implements StudioPresetServices {
  @override
  final List<Preset> libraryPresets = [
    Preset(
      id: 'voice',
      name: 'Voice Study',
      providerId: 'provider-2',
      model: 'roleplay-model',
      colorBand: 0xff123456,
      temperature: 0.8,
      extensions: {
        'plugin': {'enabled': true},
      },
      raw: {
        'import_setting': [1, 2],
      },
      prompts: [
        PromptBlock(
          identifier: 'main',
          content: 'Stay in character.',
          raw: {
            'plugin': {'weight': 4},
          },
        ),
        PromptBlock(identifier: 'chatHistory', marker: true),
      ],
      promptOrder: [
        PromptOrderEntry(identifier: 'main'),
        PromptOrderEntry(identifier: 'chatHistory'),
      ],
    ),
    Preset(id: 'other', name: 'Other preset', model: 'another-model'),
  ];
}

Map<String, dynamic> _json(StudioToolResult result) =>
    jsonDecode(result.text) as Map<String, dynamic>;

void main() {
  late _PresetServices services;
  late StudioSession session;
  late StudioToolContext ctx;

  Future<StudioToolResult> call(
    String name, [
    Map<String, dynamic> args = const {},
    StudioToolContext? context,
  ]) => kStudioTools[name]!.call(context ?? ctx, args);

  Future<void> load() async {
    final result = await call('load_preset', {'id': 'voice'});
    expect(result.isError, isFalse, reason: result.text);
  }

  setUp(() {
    services = _PresetServices();
    session = StudioSession(
      id: 'session',
      title: '',
      workspace: StudioWorkspace(
        character: Character(id: 'draft', name: 'Wren'),
      ),
    );
    ctx = StudioToolContext(session: session, services: services);
  });

  test(
    'old service hosts have an empty preset library; no selection is explicit',
    () async {
      final oldHost = StudioToolContext(
        session: session,
        services: _Services(),
      );
      expect(libraryPresetsOf(oldHost.services), isEmpty);
      final list = _json(await call('list_presets', {}, oldHost));
      expect(list['presets'], isEmpty);
      final selected = _json(await call('get_preset', {}, oldHost));
      expect(selected['preset'], isNull);
      expect(selected['uses_active_preset'], isTrue);
      expect(
        (await call('update_preset', {
          'changes': {'temperature': 1},
        })).isError,
        isTrue,
      );
      expect((await call('clear_preset')).isError, isFalse);
      expect(session.ops, isEmpty);
    },
  );

  test('list and inspect the library without selecting it', () async {
    final list = _json(await call('list_presets'));
    expect((list['presets'] as List).map((p) => p['id']), ['voice', 'other']);
    final search = _json(await call('list_presets', {'search': 'ROLEPLAY'}));
    expect((search['presets'] as List).single['id'], 'voice');
    final read = _json(await call('get_preset', {'id': 'voice'}));
    expect(read['preset'], services.libraryPresets.first.toJson());
    expect(session.workspace.preset, isNull);
    expect(session.ops, isEmpty);
  });

  test(
    'load keeps the id, makes a deep copy, records a change and rewinds',
    () async {
      final original = jsonEncode(services.libraryPresets.first.toJson());
      await load();
      expect(session.workspace.preset!.id, 'voice');
      expect(session.ops.single.tool, 'load_preset');
      expect(session.revisions['preset']!.by, 'the main agent');
      expect(
        _json(await call('get_draft', {'section': 'preset'}))['preset'],
        session.workspace.preset!.toJson(),
      );
      final p = session.workspace.preset!;
      (p.extensions['plugin'] as Map)['enabled'] = false;
      (p.raw['import_setting'] as List).add(3);
      (p.prompts.first.raw['plugin'] as Map)['weight'] = 99;
      p.promptOrder.first.enabled = false;
      expect(jsonEncode(services.libraryPresets.first.toJson()), original);
      session.rewindTo(0);
      expect(session.workspace.preset, isNull);
    },
  );

  test(
    'as_copy selects a separate id and leaves the original intact',
    () async {
      final result = await call('load_preset', {
        'id': 'voice',
        'as_copy': true,
      });
      expect(result.isError, isFalse, reason: result.text);
      expect(session.workspace.preset!.id, isNot('voice'));
      expect(session.workspace.preset!.name, 'Voice Study (copy)');
      expect(services.libraryPresets.first.name, 'Voice Study');
      final list = _json(await call('list_presets'));
      expect(
        (list['presets'] as List).any((p) => p['selected'] == true),
        isFalse,
      );
    },
  );

  test(
    'partial sampling and nullable binding edits preserve imported settings',
    () async {
      await load();
      final before = jsonEncode(services.libraryPresets.first.toJson());
      final result = await call('update_preset', {
        'changes': {
          'temperature': 0.3,
          'maxResponseTokens': 1800,
          'topP': 0.95,
          'thinking': true,
          'reasoningEffort': 'high',
          'thinkingBudget': 2048,
          'stream': false,
          'stopSequences': ['\nUser:', 'END'],
          'model': '',
        },
        'clear': ['providerId', 'colorBand'],
      });
      expect(result.isError, isFalse, reason: result.text);
      final p = session.workspace.preset!;
      expect(p.id, 'voice');
      expect(p.temperature, 0.3);
      expect(p.maxResponseTokens, 1800);
      expect(p.providerId, isNull);
      expect(p.colorBand, isNull);
      expect(p.model, '');
      expect(p.thinking, isTrue);
      expect(p.reasoningEffort, 'high');
      expect(p.thinkingBudget, 2048);
      expect(p.stopSequences, ['\nUser:', 'END']);
      expect(p.extensions['plugin'], {'enabled': true});
      expect(p.raw['import_setting'], [1, 2]);
      expect(p.prompts.first.raw['plugin'], {'weight': 4});
      expect(jsonEncode(services.libraryPresets.first.toJson()), before);
      expect(session.ops, hasLength(2));
    },
  );

  test(
    'native prompt blocks/order replace together and keep unknown block data',
    () async {
      await load();
      final blocks = [
        {
          'identifier': 'main',
          'role': 'system',
          'content': 'Be concise.',
          'injection_position': 1,
          'injection_depth': 0,
          'injection_order': 5,
          'injection_trigger': ['normal'],
          'forbid_overrides': true,
        },
        {'identifier': 'chatHistory', 'marker': true},
        {
          'identifier': 'extra',
          'role': 'user',
          'content': 'A final instruction.',
        },
      ];
      final result = await call('update_preset', {
        'changes': {
          'prompts': blocks,
          'promptOrder': [
            {'identifier': 'chatHistory'},
            {'identifier': 'extra', 'enabled': false},
            {'identifier': 'main'},
          ],
        },
      });
      expect(result.isError, isFalse, reason: result.text);
      final p = session.workspace.preset!;
      expect(p.prompts.first.content, 'Be concise.');
      expect(p.prompts.first.injectionPosition, InjectionPosition.absolute);
      expect(p.prompts.first.injectionDepth, 0);
      expect(p.prompts.first.raw['plugin'], {'weight': 4});
      expect(p.promptOrder.map((e) => e.identifier), [
        'chatHistory',
        'extra',
        'main',
      ]);
      expect(p.promptOrder[1].enabled, isFalse);
      blocks.first['content'] = 'Edited after the call';
      expect(p.prompts.first.content, 'Be concise.');
      expect(
        services.libraryPresets.first.prompts.first.content,
        'Stay in character.',
      );
    },
  );

  test('empty block and order arrays are deliberate replacements', () async {
    await load();
    final result = await call('update_preset', {
      'changes': {'prompts': [], 'promptOrder': []},
    });
    expect(result.isError, isFalse, reason: result.text);
    expect(session.workspace.preset!.prompts, isEmpty);
    expect(session.workspace.preset!.promptOrder, isEmpty);
    await call('update_preset', {
      'changes': {'name': 'Blank template'},
    });
    expect(session.workspace.preset!.prompts, isEmpty);
    expect(session.workspace.preset!.promptOrder, isEmpty);
  });

  test(
    'all supported scalar settings round-trip through native JSON',
    () async {
      await load();
      final changes = <String, dynamic>{
        'name': 'Tuned Voice',
        'providerId': 'provider-3',
        'model': 'test-model',
        'mode': 'advanced',
        'temperature': 0.6,
        'maxResponseTokens': 4096,
        'maxContext': 100000,
        'useMaxContext': true,
        'topP': 0.9,
        'topK': 40,
        'topA': 20,
        'minP': 0.05,
        'frequencyPenalty': -0.25,
        'presencePenalty': 0.4,
        'repetitionPenalty': 1.1,
        'seed': 42,
        'n': 2,
        'stream': false,
        'stopSequences': ['END'],
        'namesBehavior': -1,
        'wrapInQuotes': true,
        'squashSystemMessages': true,
        'maxContextUnlocked': true,
        'reasoningEffort': 'medium',
        'thinking': true,
        'thinkingBudget': 2048,
        'thinkStartTag': '',
        'thinkEndTag': '',
        'summaryBudget': 1024,
        'colorBand': 0xff445566,
      };
      final result = await call('update_preset', {'changes': changes});
      expect(result.isError, isFalse, reason: result.text);
      final json = session.workspace.preset!.toJson();
      expect({for (final key in changes.keys) key: json[key]}, changes);
      expect(json['id'], 'voice');
      expect(services.libraryPresets.first.name, 'Voice Study');
    },
  );

  test(
    'invalid sampling/options fail atomically and keep the selected preset',
    () async {
      await load();
      final before = jsonEncode(session.workspace.preset!.toJson());
      for (final bad in <Map<String, dynamic>>[
        {},
        {'changes': {}},
        {'changes': 'bad'},
        {
          'changes': {'id': 'new-id'},
        },
        {
          'changes': {'temperature': -0.1},
        },
        {
          'changes': {'temperature': 2.1},
        },
        {
          'changes': {'temperature': double.nan},
        },
        {
          'changes': {'temperature': double.infinity},
        },
        {
          'changes': {'topP': 1.1},
        },
        {
          'changes': {'maxResponseTokens': 0},
        },
        {
          'changes': {'maxContext': 1.5},
        },
        {
          'changes': {'maxContext': 1e100},
        },
        {
          'changes': {'maxResponseTokens': '100'},
        },
        {
          'changes': {'topK': -1},
        },
        {
          'changes': {'topA': 1001},
        },
        {
          'changes': {'minP': -0.1},
        },
        {
          'changes': {'frequencyPenalty': -2.1},
        },
        {
          'changes': {'presencePenalty': 2.1},
        },
        {
          'changes': {'repetitionPenalty': -0.1},
        },
        {
          'changes': {'seed': -2},
        },
        {
          'changes': {'n': 9},
        },
        {
          'changes': {'namesBehavior': 3},
        },
        {
          'changes': {'summaryBudget': 0},
        },
        {
          'changes': {'stream': 'false'},
        },
        {
          'changes': {'thinkingBudget': -1},
        },
        {
          'changes': {'reasoningEffort': 'invented'},
        },
        {
          'changes': {'mode': 'expert'},
        },
        {
          'changes': {
            'stopSequences': [1],
          },
        },
        {
          'changes': {
            'stopSequences': ['END', ''],
          },
        },
        {
          'changes': {'providerId': ''},
        },
        {
          'changes': {'colorBand': null},
        },
        {
          'changes': {'colorBand': 0x100000000},
        },
        {
          'changes': {'model': false},
        },
        {
          'changes': {'extensions': {}},
        },
        {
          'changes': {'temperature': null},
        },
        {
          'changes': {'name': 'partial', 'maxContext': -1},
        },
        {
          'clear': ['model'],
        },
        {'clear': 'providerId'},
        {
          'changes': {'providerId': 'p'},
          'clear': ['providerId'],
        },
        {
          'changes': {'name': 'partial'},
          'as_copy': true,
        },
      ]) {
        final result = await call('update_preset', bad);
        expect(result.isError, isTrue, reason: '$bad: ${result.text}');
        expect(
          jsonEncode(session.workspace.preset!.toJson()),
          before,
          reason: '$bad',
        );
        expect(session.ops, hasLength(1));
      }
    },
  );

  test(
    'malformed prompt arrays cannot remove or silently alter blocks',
    () async {
      await load();
      final before = jsonEncode(session.workspace.preset!.toJson());
      for (final changes in <Map<String, dynamic>>[
        {'prompts': 'bad'},
        {
          'prompts': [1],
        },
        {
          'prompts': [
            {'content': 'missing id'},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'role': 'developer'},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'content': 7},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'contnet': 'misspelled'},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'marker': 'true'},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'injection_position': 2},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'injection_depth': -1},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'injection_depth': 1.5},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'injection_order': -1},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main', 'forbid_overrides': null},
          ],
        },
        {
          'prompts': [
            {
              'identifier': 'main',
              'injection_trigger': [1],
            },
          ],
        },
        {
          'prompts': [
            {'identifier': 'main'},
            {'identifier': 'main'},
          ],
        },
        {
          'promptOrder': [
            {'identifier': 'missing'},
          ],
        },
        {
          'promptOrder': [
            {'identifier': 'main', 'enabled': 'yes'},
          ],
        },
        {
          'promptOrder': [
            {'identifier': 'main'},
            {'identifier': 'main'},
          ],
        },
        {
          'promptOrder': [
            {'identifier': 'main', 'enable': true},
          ],
        },
        {
          'prompts': [
            {'identifier': 'main'},
          ],
        },
      ]) {
        final result = await call('update_preset', {'changes': changes});
        expect(result.isError, isTrue, reason: '$changes: ${result.text}');
        expect(jsonEncode(session.workspace.preset!.toJson()), before);
        expect(session.ops, hasLength(1));
      }
    },
  );

  test(
    'invalid reads and loads have useful errors and never select a preset',
    () async {
      for (final (tool, args) in <(String, Map<String, dynamic>)>[
        ('load_preset', {}),
        ('load_preset', {'id': ''}),
        ('load_preset', {'id': 'missing'}),
        ('get_preset', {'id': 'missing'}),
        ('load_preset', {'id': 'voice', 'as_copy': 'yes'}),
        ('load_preset', {'id': 'voice', 'mode': 'replace'}),
        ('get_preset', {'id': 17}),
        ('list_presets', {'search': false}),
      ]) {
        final result = await call(tool, args);
        expect(result.isError, isTrue, reason: '$tool $args');
        expect(_json(result)['error'], isA<String>());
        expect(session.workspace.preset, isNull);
        expect(session.ops, isEmpty);
      }
    },
  );

  test(
    'stale writes require reading the draft preset; library reads do not unlock it',
    () async {
      await load();
      final writer = ctx.as('Subagent 1');
      await call('get_preset', {}, writer);
      session.edit(
        'manual',
        'Edited preset',
        (ws) => ws.preset!.temperature = 1.7,
      );
      for (final (tool, args) in <(String, Map<String, dynamic>)>[
        (
          'update_preset',
          {
            'changes': {'temperature': 0.2},
          },
        ),
        ('load_preset', {'id': 'other'}),
        ('clear_preset', {}),
      ]) {
        final result = await call(tool, args, writer);
        expect(result.isError, isTrue);
        expect(result.text, contains('get_preset'));
        expect(result.text, contains('the user'));
      }
      await call('get_preset', {'id': 'voice'}, writer);
      await call('list_presets', {}, writer);
      await call('get_draft', {'section': 'character'}, writer);
      expect((await call('clear_preset', {}, writer)).isError, isTrue);
      await call('get_draft', {'section': 'preset'}, writer);
      expect(
        (await call('update_preset', {
          'changes': {'temperature': 0.2},
        }, writer)).isError,
        isFalse,
      );
      expect(
        (await call('update_preset', {
          'changes': {'temperature': 0.4},
        }, writer)).isError,
        isFalse,
      );
      expect(session.workspace.preset!.temperature, 0.4);
    },
  );

  test(
    'replacement and clear invalidate reads of the previous selection',
    () async {
      await load();
      final writer = ctx.as('Subagent 3');
      await call('get_preset', {}, writer);
      await call('load_preset', {'id': 'other'});
      final staleReplacement = await call('update_preset', {
        'changes': {'name': 'Old selection edit'},
      }, writer);
      expect(staleReplacement.isError, isTrue);
      expect(staleReplacement.text, contains('get_preset'));
      expect(session.workspace.preset!.id, 'other');

      await call('get_preset', {}, writer);
      await call('clear_preset');
      for (final (tool, args) in <(String, Map<String, dynamic>)>[
        (
          'update_preset',
          {
            'changes': {'name': 'Old selection edit'},
          },
        ),
        ('load_preset', {'id': 'voice'}),
        ('clear_preset', {}),
      ]) {
        final result = await call(tool, args, writer);
        expect(result.isError, isTrue, reason: '$tool: ${result.text}');
        expect(result.text, contains('get_preset'));
        expect(session.workspace.preset, isNull);
      }
      await call('get_preset', {}, writer);
      expect(
        (await call('load_preset', {'id': 'voice'}, writer)).isError,
        isFalse,
      );
      expect(session.workspace.preset!.id, 'voice');
    },
  );

  test(
    'all-draft and selected-preset reads authorize fresh writes, including clear',
    () async {
      await load();
      final writer = ctx.as('Subagent 2');
      await call('get_draft', {}, writer);
      expect((await call('clear_preset', {}, writer)).isError, isFalse);
      expect(session.workspace.preset, isNull);
      expect(services.libraryPresets, hasLength(2));
      session.rewindTo(1);
      expect(session.workspace.preset!.id, 'voice');
      expect((await call('clear_preset', {}, writer)).isError, isTrue);
      await call('get_preset', {}, writer);
      expect((await call('clear_preset', {}, writer)).isError, isFalse);
    },
  );

  test(
    'critic gets preset reads; writers/general/custom editors get bounded tools',
    () {
      Set<String> names(String type, [StudioConfig? config]) =>
          studioToolsForType(
            type,
            config ?? StudioConfig(),
          ).map((t) => t.name).toSet();
      for (final type in ['critic', 'lore_writer']) {
        expect(names(type), containsAll(kPresetReadToolNames));
        expect(names(type).intersection(kPresetEditToolNames.toSet()), isEmpty);
      }
      for (final type in ['studio', 'general', 'writer']) {
        expect(
          names(type),
          containsAll([...kPresetReadToolNames, ...kPresetEditToolNames]),
        );
      }
      final config = StudioConfig(
        customAgents: const [
          StudioAgentType(
            id: 'reader',
            label: 'Reader',
            description: '',
            toolGroups: {'read'},
          ),
          StudioAgentType(
            id: 'tuner',
            label: 'Tuner',
            description: '',
            toolGroups: {'read', 'presets'},
          ),
        ],
      );
      expect(names('reader', config), containsAll(kPresetReadToolNames));
      expect(
        names('reader', config).intersection(kPresetEditToolNames.toSet()),
        isEmpty,
      );
      expect(
        names('tuner', config),
        containsAll([...kPresetReadToolNames, ...kPresetEditToolNames]),
      );
    },
  );
}
