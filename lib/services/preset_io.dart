/// Import/export of generation presets across the formats the app accepts:
/// SillyTavern chat-completion presets, Agnai `GenSettings`, and our own native
/// shape. Import is tolerant (missing keys fall back to [Preset.create]
/// defaults); export is lossless where the target format allows, with unmodelled
/// keys tucked into [Preset.raw]/[Preset.extensions] on the way in and merged
/// back on the way out.
///
/// The public surface is a handful of top-level functions:
/// [detectFormat], [importPreset], [exportSillyTavern], [exportAgnai] and
/// [exportNative].
library;

import '../models/preset.dart';
import '../models/prompt_block.dart';

/// The preset interchange formats this app can read.
enum PresetFormat {
  /// SillyTavern chat-completion preset (`prompts` + snake_case `prompt_order`).
  sillyTavern,

  /// Agnai `GenSettings` object (`temp` / `maxContextLength` / `gaslight` / …).
  agnai,

  /// Our own persistence shape (see [Preset.toJson]).
  native,

  /// Nothing we recognise.
  unknown,
}

// --- Detection --------------------------------------------------------------

/// Sniffs [json] and returns the best-matching [PresetFormat]. Native is
/// checked first because it and SillyTavern both carry a `prompts` list; native
/// is distinguished by its camelCase `promptOrder` or a `mode` key.
PresetFormat detectFormat(Map<String, dynamic> json) {
  final hasPromptsList = json['prompts'] is List;

  // Native: our own camelCase order, or the `mode` discriminator.
  if ((hasPromptsList && json['promptOrder'] is List) ||
      json.containsKey('mode')) {
    return PresetFormat.native;
  }

  // SillyTavern: prompts + snake_case prompt_order.
  if (hasPromptsList && json['prompt_order'] is List) {
    return PresetFormat.sillyTavern;
  }

  // Agnai: GenSettings-only signals, and definitely no ST prompt_order.
  const agnaiSignals = ['temp', 'maxContextLength', 'gaslight', 'presetMode'];
  if (!json.containsKey('prompt_order') &&
      agnaiSignals.any(json.containsKey)) {
    return PresetFormat.agnai;
  }

  return PresetFormat.unknown;
}

// --- Import -----------------------------------------------------------------

/// Parses [json] into a [Preset], dispatching on [detectFormat]. When [name] is
/// given it overrides whatever name the source carried. Throws a
/// [FormatException] on [PresetFormat.unknown].
Preset importPreset(Map<String, dynamic> json, {String? name}) {
  final Preset preset;
  switch (detectFormat(json)) {
    case PresetFormat.native:
      preset = Preset.fromJson(json);
    case PresetFormat.sillyTavern:
      preset = _importSillyTavern(json);
    case PresetFormat.agnai:
      preset = _importAgnai(json);
    case PresetFormat.unknown:
      throw const FormatException(
        'Unrecognised preset format: expected a SillyTavern, Agnai, or native '
        'preset (no "prompts"/"prompt_order", "mode", or Agnai gen settings '
        'were found).',
      );
  }
  if (name != null) preset.name = name;
  return preset;
}

/// Top-level ST keys consumed into typed [Preset] fields; anything else is kept
/// verbatim in [Preset.raw] so round-trips stay lossless.
const _stConsumed = <String>{
  'temperature',
  'frequency_penalty',
  'presence_penalty',
  'top_p',
  'top_k',
  'top_a',
  'min_p',
  'repetition_penalty',
  'openai_max_context',
  'openai_max_tokens',
  'seed',
  'n',
  'stream_openai',
  'names_behavior',
  'wrap_in_quotes',
  'squash_system_messages',
  'max_context_unlocked',
  'show_thoughts',
  'reasoning_effort',
  'prompts',
  'prompt_order',
  'extensions',
};

/// SillyTavern's effort scale is wider than ours: `auto` means "leave it to the
/// model", and `min`/`max` are its own extremes. Map them onto what this app
/// sends, and drop anything unrecognised rather than forwarding it to a host.
String _importEffort(Object? value) {
  final effort = value?.toString().trim().toLowerCase() ?? '';
  switch (effort) {
    case 'min':
      return 'low';
    case 'max':
      return 'high';
    case 'low':
    case 'medium':
    case 'high':
      return effort;
    default:
      // 'auto', 'none', 'custom', empty, anything new.
      return '';
  }
}

Preset _importSillyTavern(Map<String, dynamic> json) {
  final d = Preset.create();

  final prompts = (json['prompts'] as List)
      .whereType<Map<String, dynamic>>()
      .map(PromptBlock.fromJson)
      .toList();
  final promptIds = {for (final b in prompts) b.identifier};
  final builtinIds = {for (final b in defaultPromptLibrary()) b.identifier};

  // Pick the prompt-order record that actually drives this preset. SillyTavern
  // keys the global/default order under a dummy character id, but the value has
  // changed across builds: newer ones use 100000, older ones used 100001, and a
  // preset can ship BOTH — a vanilla built-ins-only record next to the real,
  // customised one. Blindly preferring 100000 then imports only the default
  // blocks and silently drops everything the preset defines ("230 blocks but
  // nothing inside" — the Writer's Block bug).
  //
  // A record earns its keep by referencing the preset's *custom* (non-built-in)
  // blocks, so score records by how many custom blocks they wire up and take the
  // richest. When no record touches custom blocks (e.g. the vanilla default,
  // which only reorders built-ins), fall back to ST's modern dummy id 100000,
  // then the first record.
  final orderRecords = (json['prompt_order'] as List)
      .whereType<Map<String, dynamic>>()
      .toList();

  int customRefs(Map<String, dynamic> r) {
    final order = r['order'];
    if (order is! List) return 0;
    return order.whereType<Map<String, dynamic>>().where((e) {
      final id = e['identifier'];
      return promptIds.contains(id) && !builtinIds.contains(id);
    }).length;
  }

  Map<String, dynamic>? chosen;
  var bestCustom = 0;
  for (final r in orderRecords) {
    final c = customRefs(r);
    if (c > bestCustom) {
      bestCustom = c;
      chosen = r;
    }
  }
  if (chosen == null) {
    for (final r in orderRecords) {
      if ((r['character_id'] as num?)?.toInt() == 100000) {
        chosen = r;
        break;
      }
    }
    chosen ??= orderRecords.isNotEmpty ? orderRecords.first : null;
  }
  final promptOrder = <PromptOrderEntry>[
    if (chosen != null && chosen['order'] is List)
      ...(chosen['order'] as List)
          .whereType<Map<String, dynamic>>()
          .map(PromptOrderEntry.fromJson),
  ];

  final raw = <String, dynamic>{
    for (final e in json.entries)
      if (!_stConsumed.contains(e.key)) e.key: e.value,
  };

  return Preset(
    id: d.id,
    name: json['name'] as String? ?? '',
    temperature: (json['temperature'] as num?)?.toDouble() ?? d.temperature,
    maxResponseTokens:
        (json['openai_max_tokens'] as num?)?.toInt() ?? d.maxResponseTokens,
    maxContext: (json['openai_max_context'] as num?)?.toInt() ?? d.maxContext,
    topP: (json['top_p'] as num?)?.toDouble() ?? d.topP,
    topK: (json['top_k'] as num?)?.toInt() ?? d.topK,
    topA: (json['top_a'] as num?)?.toInt() ?? d.topA,
    minP: (json['min_p'] as num?)?.toDouble() ?? d.minP,
    frequencyPenalty:
        (json['frequency_penalty'] as num?)?.toDouble() ?? d.frequencyPenalty,
    presencePenalty:
        (json['presence_penalty'] as num?)?.toDouble() ?? d.presencePenalty,
    repetitionPenalty:
        (json['repetition_penalty'] as num?)?.toDouble() ?? d.repetitionPenalty,
    seed: (json['seed'] as num?)?.toInt() ?? d.seed,
    n: (json['n'] as num?)?.toInt() ?? d.n,
    stream: json['stream_openai'] as bool? ?? d.stream,
    namesBehavior: (json['names_behavior'] as num?)?.toInt() ?? d.namesBehavior,
    wrapInQuotes: json['wrap_in_quotes'] as bool? ?? d.wrapInQuotes,
    squashSystemMessages:
        json['squash_system_messages'] as bool? ?? d.squashSystemMessages,
    maxContextUnlocked:
        json['max_context_unlocked'] as bool? ?? d.maxContextUnlocked,
    // SillyTavern's `show_thoughts` is the same intent: ask the model for its
    // reasoning and display it.
    thinking: json['show_thoughts'] as bool? ?? d.thinking,
    reasoningEffort: json.containsKey('reasoning_effort')
        ? _importEffort(json['reasoning_effort'])
        : d.reasoningEffort,
    prompts: prompts.isNotEmpty ? prompts : null,
    promptOrder: promptOrder.isNotEmpty ? promptOrder : null,
    extensions: (json['extensions'] as Map?)?.cast<String, dynamic>(),
    raw: raw.isNotEmpty ? raw : null,
  );
}

Preset _importAgnai(Map<String, dynamic> json) {
  final d = Preset.create();

  // Start from the full built-in block library, then override the two blocks
  // Agnai models directly.
  final prompts = defaultPromptLibrary();
  PromptBlock blockOf(String id) => prompts.firstWhere((b) => b.identifier == id);

  final gaslight =
      (json['gaslight'] as String?) ?? (json['systemPrompt'] as String?);
  if (gaslight != null && gaslight.isNotEmpty) {
    blockOf(PromptId.main).content = gaslight;
  }
  final jailbreak = json['ultimeJailbreak'] as String?;
  if (jailbreak != null && jailbreak.isNotEmpty) {
    blockOf(PromptId.jailbreak).content = jailbreak;
  }

  // Map Agnai's placeholder order onto our identifiers where they line up;
  // otherwise fall back to the default order.
  List<PromptOrderEntry>? promptOrder;
  final agnaiOrder = json['promptOrder'];
  if (agnaiOrder is List) {
    final known = {for (final b in prompts) b.identifier};
    final mapped = <PromptOrderEntry>[
      for (final e in agnaiOrder.whereType<Map<String, dynamic>>())
        if (known.contains(e['placeholder']))
          PromptOrderEntry(
            identifier: e['placeholder'] as String,
            enabled: e['enabled'] as bool? ?? true,
          ),
    ];
    if (mapped.isNotEmpty) promptOrder = mapped;
  }

  final stops = json['stopSequences'];

  // Agnai groups this under one `reasoning` object (common/types/presets.ts:
  // {start, end, effort, enabled, exclude, maxTokens}), which lines up field for
  // field with ours.
  final reasoning = json['reasoning'];
  final r = reasoning is Map ? reasoning.cast<String, dynamic>() : null;

  return Preset(
    id: d.id,
    name: json['name'] as String? ?? '',
    mode: PresetMode.byName(json['presetMode'] as String?),
    temperature: (json['temp'] as num?)?.toDouble() ?? d.temperature,
    maxResponseTokens:
        (json['maxTokens'] as num?)?.toInt() ?? d.maxResponseTokens,
    maxContext: (json['maxContextLength'] as num?)?.toInt() ?? d.maxContext,
    topP: (json['topP'] as num?)?.toDouble() ?? d.topP,
    topK: (json['topK'] as num?)?.toInt() ?? d.topK,
    topA: (json['topA'] as num?)?.toInt() ?? d.topA,
    minP: (json['minP'] as num?)?.toDouble() ?? d.minP,
    frequencyPenalty:
        (json['frequencyPenalty'] as num?)?.toDouble() ?? d.frequencyPenalty,
    presencePenalty:
        (json['presencePenalty'] as num?)?.toDouble() ?? d.presencePenalty,
    repetitionPenalty:
        (json['repetitionPenalty'] as num?)?.toDouble() ?? d.repetitionPenalty,
    stream: json['streamResponse'] as bool? ?? d.stream,
    thinking: r?['enabled'] as bool? ?? d.thinking,
    thinkingBudget: (r?['maxTokens'] as num?)?.toInt() ?? d.thinkingBudget,
    reasoningEffort:
        r != null ? _importEffort(r['effort']) : d.reasoningEffort,
    thinkStartTag: r?['start'] as String? ?? d.thinkStartTag,
    thinkEndTag: r?['end'] as String? ?? d.thinkEndTag,
    stopSequences: stops is List
        ? stops.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : null,
    prompts: prompts,
    promptOrder: promptOrder,
    // Keep the whole source object so nothing Agnai-specific is lost.
    raw: {'_agnai': json},
  );
}

// --- Export -----------------------------------------------------------------

/// Emits a SillyTavern chat-completion preset. Preserved keys from [Preset.raw]
/// are merged back underneath the modelled fields.
Map<String, dynamic> exportSillyTavern(Preset p) {
  return <String, dynamic>{
    ...p.raw,
    'temperature': p.temperature,
    'frequency_penalty': p.frequencyPenalty,
    'presence_penalty': p.presencePenalty,
    'top_p': p.topP,
    'top_k': p.topK,
    'top_a': p.topA,
    'min_p': p.minP,
    'repetition_penalty': p.repetitionPenalty,
    'openai_max_context': p.maxContext,
    'openai_max_tokens': p.maxResponseTokens,
    'seed': p.seed,
    'n': p.n,
    'stream_openai': p.stream,
    'names_behavior': p.namesBehavior,
    'wrap_in_quotes': p.wrapInQuotes,
    'squash_system_messages': p.squashSystemMessages,
    'max_context_unlocked': p.maxContextUnlocked,
    'show_thoughts': p.thinking,
    'reasoning_effort': p.reasoningEffort.isEmpty ? 'auto' : p.reasoningEffort,
    'prompts': p.prompts.map((b) => b.toJson()).toList(),
    'prompt_order': [
      {
        'character_id': 100000,
        'order': p.promptOrder.map((e) => e.toJson()).toList(),
      },
    ],
    'extensions': p.extensions,
  };
}

/// Emits an Agnai `GenSettings`-shaped object. The `main` block feeds
/// `gaslight`/`systemPrompt` and the `jailbreak` block feeds `ultimeJailbreak`.
Map<String, dynamic> exportAgnai(Preset p) {
  final main = p.blockById(PromptId.main)?.content ?? '';
  final jailbreak = p.blockById(PromptId.jailbreak)?.content ?? '';
  return <String, dynamic>{
    'name': p.name,
    'presetMode': p.mode.name,
    'temp': p.temperature,
    'maxTokens': p.maxResponseTokens,
    'maxContextLength': p.maxContext,
    'topP': p.topP,
    'topK': p.topK,
    'topA': p.topA,
    'minP': p.minP,
    'frequencyPenalty': p.frequencyPenalty,
    'presencePenalty': p.presencePenalty,
    'repetitionPenalty': p.repetitionPenalty,
    'streamResponse': p.stream,
    'stopSequences': p.stopSequences,
    'reasoning': <String, dynamic>{
      'start': p.thinkStartTag,
      'end': p.thinkEndTag,
      'effort': p.reasoningEffort.isEmpty ? 'none' : p.reasoningEffort,
      'enabled': p.thinking,
      'exclude': false,
      'maxTokens': p.thinkingBudget,
    },
    'gaslight': main,
    'systemPrompt': main,
    'ultimeJailbreak': jailbreak,
    'promptOrder': [
      for (final e in p.promptOrder)
        {'placeholder': e.identifier, 'enabled': e.enabled},
    ],
  };
}

/// Our own lossless persistence shape.
Map<String, dynamic> exportNative(Preset p) => p.toJson();
