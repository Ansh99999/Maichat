import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/preset.dart';
import 'package:maichat/models/prompt_block.dart';
import 'package:maichat/services/preset_io.dart';

/// The real SillyTavern default chat-completion preset, read from disk.
const _stDefaultPath =
    '/home/ubuntu/SillyTavern/default/content/presets/openai/Default.json';

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
}
