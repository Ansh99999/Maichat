import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/services/preset_io.dart';

/// The real SillyTavern default chat-completion preset, vendored into the repo
/// under test/fixtures so the suite runs anywhere (CI included), not just where
/// a local SillyTavern checkout exists.
const _stDefaultPath = 'test/fixtures/st_openai_default.json';

Map<String, dynamic> _loadStDefault() {
  final text = File(_stDefaultPath).readAsStringSync();
  return jsonDecode(text) as Map<String, dynamic>;
}

/// A minimal Agnai `GenSettings`-shaped object.
Map<String, dynamic> _agnaiSample() => <String, dynamic>{
      'temp': 0.9,
      'maxTokens': 250,
      'maxContextLength': 8192,
      'gaslight': 'You are {{char}}.',
      'presetMode': 'simple',
      'streamResponse': true,
    };

void main() {
  group('detectFormat', () {
    test('recognises the SillyTavern default preset', () {
      expect(detectFormat(_loadStDefault()), PresetFormat.sillyTavern);
    });

    test('recognises an Agnai gen-settings object', () {
      expect(detectFormat(_agnaiSample()), PresetFormat.agnai);
    });

    test('recognises our own native shape', () {
      expect(detectFormat(Preset.create().toJson()), PresetFormat.native);
    });

    test('empty / foreign maps are unknown', () {
      expect(detectFormat(<String, dynamic>{}), PresetFormat.unknown);
      expect(detectFormat({'hello': 'world'}), PresetFormat.unknown);
    });
  });

  group('SillyTavern import', () {
    test('parses gen params, blocks, and order from the real default', () {
      final json = _loadStDefault();
      final p = importPreset(json);

      expect(p.temperature, 1.0);
      expect(p.maxContext, 4095);
      expect(p.maxResponseTokens, 300);

      // 12 built-in blocks.
      expect(p.prompts.length, 12);

      // The global (character_id 100000) record has 11 order entries.
      expect(p.promptOrder.length, 11);

      final main =
          p.promptOrder.firstWhere((e) => e.identifier == PromptId.main);
      expect(main.enabled, isTrue);
      final enhance = p.promptOrder
          .firstWhere((e) => e.identifier == PromptId.enhanceDefinitions);
      expect(enhance.enabled, isFalse);

      expect(
        p.blockById(PromptId.main)!.content,
        contains("Write {{char}}'s next reply"),
      );
    });

    test('preserves unmodelled top-level keys in raw', () {
      final p = importPreset(_loadStDefault());
      expect(p.raw['chat_completion_source'], 'openai');
      expect(p.raw.containsKey('impersonation_prompt'), isTrue);
    });

    test('picks the customised order when a vanilla 100000 record shadows it',
        () {
      // Presets exported from older SillyTavern builds carry the real order
      // under the historical dummy id 100001, while a vanilla 11-entry 100000
      // record sits alongside it. Preferring 100000 silently imports only the
      // default blocks — the "230 blocks but nothing inside" bug (Writer's
      // Block). We must import the record that actually references the prompts.
      final custom = <Map<String, dynamic>>[
        for (var i = 0; i < 40; i++)
          {
            'identifier': 'uuid-$i',
            'name': 'Custom $i',
            'role': 'system',
            'content': 'Body $i',
          },
      ];
      final json = <String, dynamic>{
        'prompts': custom,
        'prompt_order': [
          {
            // Vanilla default record: references built-ins this preset doesn't
            // even define, so none of them resolve.
            'character_id': 100000,
            'order': [
              {'identifier': 'main', 'enabled': true},
              {'identifier': 'chatHistory', 'enabled': true},
            ],
          },
          {
            // The real order, under the legacy dummy id.
            'character_id': 100001,
            'order': [
              for (final b in custom)
                {'identifier': b['identifier'], 'enabled': true},
            ],
          },
        ],
      };

      final p = importPreset(json);
      expect(p.prompts.length, 40);
      // The 40-entry customised order wins over the 2-entry vanilla one.
      expect(p.promptOrder.length, 40);
      expect(p.promptOrder.first.identifier, 'uuid-0');
      // Every order entry resolves to an imported block.
      final ids = {for (final b in p.prompts) b.identifier};
      expect(p.promptOrder.every((e) => ids.contains(e.identifier)), isTrue);
    });

    test('round-trips through export/import', () {
      final original = importPreset(_loadStDefault());
      final exported = exportSillyTavern(original);

      // Still detected as SillyTavern after export.
      expect(detectFormat(exported), PresetFormat.sillyTavern);

      final reimported = importPreset(exported);

      expect(reimported.temperature, original.temperature);
      expect(reimported.maxContext, original.maxContext);
      expect(reimported.maxResponseTokens, original.maxResponseTokens);
      expect(reimported.topP, original.topP);
      expect(reimported.seed, original.seed);
      expect(reimported.n, original.n);
      expect(reimported.stream, original.stream);

      // Block identifiers survive.
      expect(
        reimported.prompts.map((b) => b.identifier).toList(),
        original.prompts.map((b) => b.identifier).toList(),
      );

      // Order identifiers + enabled flags survive.
      final origOrder = {
        for (final e in original.promptOrder) e.identifier: e.enabled,
      };
      final rtOrder = {
        for (final e in reimported.promptOrder) e.identifier: e.enabled,
      };
      expect(rtOrder, origOrder);

      // Preserved raw key survives the round trip.
      expect(reimported.raw['chat_completion_source'], 'openai');
    });
  });

  group('Agnai import', () {
    test('maps gen settings and the gaslight block', () {
      final json = _agnaiSample();
      expect(detectFormat(json), PresetFormat.agnai);

      final p = importPreset(json);
      expect(p.temperature, 0.9);
      expect(p.maxContext, 8192);
      expect(p.maxResponseTokens, 250);
      expect(p.stream, isTrue);
      expect(p.mode, PresetMode.simple);
      expect(p.blockById(PromptId.main)!.content, 'You are {{char}}.');

      // A full block library is synthesised.
      expect(p.prompts.length, 12);

      // The source object is preserved for lossless export.
      expect(p.raw['_agnai'], isA<Map>());
    });

    test('exportAgnai emits GenSettings-shaped keys', () {
      final p = importPreset(_agnaiSample());
      final out = exportAgnai(p);
      expect(out['temp'], 0.9);
      expect(out['maxContextLength'], 8192);
      expect(out['gaslight'], 'You are {{char}}.');
      expect(out['presetMode'], 'simple');
    });

    test('maps every prompt-order placeholder, not just scenario', () {
      // The real "OpenRouter - Imported" preset exported from Agnai. Its order
      // names sections by Agnai placeholders (system_prompt, personality,
      // history, ujb, …). A verbatim identifier match only ever caught
      // `scenario` and dropped the rest — the "only scenario imported" bug.
      final json = jsonDecode(
        File('test/fixtures/agnai_openrouter.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(detectFormat(json), PresetFormat.agnai);

      final p = importPreset(json);
      final order = {for (final e in p.promptOrder) e.identifier: e.enabled};

      // The Agnai placeholders resolved to our block identifiers.
      expect(order.containsKey(PromptId.scenario), isTrue);
      expect(order.containsKey(PromptId.charPersonality), isTrue);
      expect(order.containsKey(PromptId.charDescription), isTrue); // personality
      expect(order.containsKey(PromptId.dialogueExamples), isTrue); // example_dialogue
      expect(order.containsKey(PromptId.personaDescription), isTrue); // impersonating
      expect(order.containsKey(PromptId.worldInfoBefore), isTrue); // memory
      expect(order.containsKey(PromptId.chatHistory), isTrue); // history
      expect(order.containsKey(PromptId.jailbreak), isTrue); // ujb
      expect(order.containsKey(PromptId.main), isTrue); // system_prompt

      // Enabled flags carry across.
      expect(order[PromptId.scenario], isTrue);
      expect(order[PromptId.dialogueExamples], isFalse); // example_dialogue off
      // `main` is the gaslight and can't be disabled, so system_prompt: false
      // does not turn it off.
      expect(order[PromptId.main], isTrue);

      // Numeric gen settings survive.
      expect(p.maxContext, 92000);
      expect(p.useMaxContext, isFalse);
      expect(p.maxResponseTokens, 6000);
    });

    test('the block list stays complete after an Agnai import', () {
      final json = jsonDecode(
        File('test/fixtures/agnai_openrouter.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      final p = importPreset(json);

      // Every built-in block still exists in the library …
      expect(p.prompts.length, 12);
      // … and every one appears in the order (blocks the Agnai preset never
      // named are appended disabled rather than vanishing).
      final orderIds = {for (final e in p.promptOrder) e.identifier};
      for (final b in defaultPromptOrder()) {
        expect(orderIds, contains(b.identifier));
      }
    });
  });

  group('native round-trip', () {
    test('importPreset(exportNative(p)) matches on key fields', () {
      final p = Preset.create(name: 'My preset')
        ..temperature = 0.7
        ..maxContext = 16000
        ..topP = 0.95
        ..seed = 42;
      final rt = importPreset(exportNative(p));

      expect(rt.name, p.name);
      expect(rt.temperature, p.temperature);
      expect(rt.maxContext, p.maxContext);
      expect(rt.topP, p.topP);
      expect(rt.seed, p.seed);
      expect(rt.mode, p.mode);
      expect(rt.prompts.length, p.prompts.length);
      expect(rt.promptOrder.length, p.promptOrder.length);
    });

    test('name override is applied', () {
      final rt = importPreset(exportNative(Preset.create()), name: 'Renamed');
      expect(rt.name, 'Renamed');
    });
  });

  group('unknown', () {
    test('throws FormatException on an unrecognised map', () {
      expect(() => importPreset(<String, dynamic>{}),
          throwsA(isA<FormatException>()));
    });
  });

  group('thinking settings across formats', () {
    test('SillyTavern show_thoughts and reasoning_effort are read', () {
      final json = _loadStDefault()
        ..['show_thoughts'] = true
        ..['reasoning_effort'] = 'high';
      final p = importPreset(json);
      expect(p.thinking, isTrue);
      expect(p.reasoningEffort, 'high');
    });

    test('SillyTavern efforts outside our scale are normalised', () {
      String effortOf(String value) =>
          importPreset(_loadStDefault()..['reasoning_effort'] = value)
              .reasoningEffort;
      // ST's own extremes and its "leave it to the model" default.
      expect(effortOf('min'), 'low');
      expect(effortOf('max'), 'high');
      expect(effortOf('auto'), isEmpty);
      expect(effortOf('something-new'), isEmpty);
    });

    test('exportSillyTavern writes both keys back', () {
      final p = Preset.create()
        ..thinking = true
        ..reasoningEffort = 'medium';
      final out = exportSillyTavern(p);
      expect(out['show_thoughts'], isTrue);
      expect(out['reasoning_effort'], 'medium');
      // An unset effort goes back as ST's own "auto".
      expect(
        exportSillyTavern(Preset.create())['reasoning_effort'],
        'auto',
      );
    });

    test('Agnai carries the whole reasoning object', () {
      final json = _agnaiSample()
        ..['reasoning'] = {
          'start': '<reason>',
          'end': '</reason>',
          'effort': 'low',
          'enabled': true,
          'exclude': false,
          'maxTokens': 3000,
        };
      final p = importPreset(json);
      expect(p.thinking, isTrue);
      expect(p.thinkingBudget, 3000);
      expect(p.reasoningEffort, 'low');
      expect(p.thinkStartTag, '<reason>');
      expect(p.thinkEndTag, '</reason>');

      final out = exportAgnai(p);
      expect(out['reasoning'], {
        'start': '<reason>',
        'end': '</reason>',
        'effort': 'low',
        'enabled': true,
        'exclude': false,
        'maxTokens': 3000,
      });
    });

    test('native round-trip keeps every thinking field', () {
      final p = Preset.create()
        ..thinking = true
        ..thinkingBudget = 8192
        ..reasoningEffort = 'high'
        ..thinkStartTag = '<thinking>'
        ..thinkEndTag = '</thinking>'
        ..useMaxContext = true
        ..stream = false;
      final rt = importPreset(exportNative(p));

      expect(rt.thinking, isTrue);
      expect(rt.thinkingBudget, 8192);
      expect(rt.reasoningEffort, 'high');
      expect(rt.thinkStartTag, '<thinking>');
      expect(rt.thinkEndTag, '</thinking>');
      expect(rt.useMaxContext, isTrue);
      expect(rt.stream, isFalse);
    });

    test('a preset saved before thinking existed picks up the default tags', () {
      // No thinking keys at all — the shape an older save has.
      final rt = Preset.fromJson({'id': 'x', 'name': 'Old'});
      expect(rt.thinkStartTag, '<think>');
      expect(rt.thinkEndTag, '</think>');
      expect(rt.thinking, isFalse);
      expect(rt.thinkingBudget, 0);
    });
  });
}
