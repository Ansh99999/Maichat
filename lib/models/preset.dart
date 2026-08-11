import 'prompt_block.dart';

/// How much of the editor is exposed.
enum PresetMode {
  simple,
  advanced;

  static PresetMode byName(String? name) =>
      name == 'advanced' ? PresetMode.advanced : PresetMode.simple;
}

/// A generation preset: sampling settings plus an ordered set of prompt blocks
/// (SillyTavern's model) plus binding metadata (name, colour band, the provider
/// and model it runs on). Designed as a superset that round-trips both
/// SillyTavern and Agnai presets — see `services/preset_io.dart`.
///
/// Fields are mutable so the editor can drive them directly, mirroring
/// [Character]. Unknown keys from imports live in [extensions]/[raw] so export
/// stays lossless.
class Preset {
  Preset({
    required this.id,
    this.name = '',
    this.colorBand,
    this.providerId,
    this.model = '',
    this.mode = PresetMode.simple,
    // Core sampling
    this.temperature = 1.0,
    this.maxResponseTokens = 300,
    this.maxContext = 4095,
    this.useMaxContext = false,
    this.topP = 1.0,
    this.topK = 0,
    this.topA = 0,
    this.minP = 0.0,
    this.frequencyPenalty = 0.0,
    this.presencePenalty = 0.0,
    this.repetitionPenalty = 1.0,
    this.seed = -1,
    this.n = 1,
    this.stream = true,
    List<String>? stopSequences,
    // Behaviour
    this.namesBehavior = 0,
    this.wrapInQuotes = false,
    this.squashSystemMessages = false,
    this.maxContextUnlocked = false,
    this.reasoningEffort = '',
    // Prompt blocks
    List<PromptBlock>? prompts,
    List<PromptOrderEntry>? promptOrder,
    Map<String, dynamic>? extensions,
    Map<String, dynamic>? raw,
  })  : stopSequences = stopSequences ?? <String>[],
        prompts = prompts ?? defaultPromptLibrary(),
        promptOrder = promptOrder ?? defaultPromptOrder(),
        extensions = extensions ?? <String, dynamic>{},
        raw = raw ?? <String, dynamic>{};

  /// A fresh preset with SillyTavern's default block library and order.
  factory Preset.create({String name = 'New preset'}) => Preset(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
      );

  final String id;
  String name;

  /// ARGB colour for the list row's band; null means "no band".
  int? colorBand;

  /// The provider this preset runs on (by [Provider.id]); null = use the active
  /// provider. The model to request.
  String? providerId;
  String model;

  PresetMode mode;

  // --- Core sampling -------------------------------------------------------
  double temperature;
  int maxResponseTokens;
  int maxContext;

  /// Prefer the model's known max context over [maxContext] when available.
  bool useMaxContext;
  double topP;
  int topK;
  int topA;
  double minP;
  double frequencyPenalty;
  double presencePenalty;
  double repetitionPenalty;
  int seed;
  int n;
  bool stream;
  List<String> stopSequences;

  // --- Behaviour -----------------------------------------------------------
  /// SillyTavern `names_behavior` (0 none / 1 default / 2 completion / -1 …).
  int namesBehavior;
  bool wrapInQuotes;
  bool squashSystemMessages;
  bool maxContextUnlocked;

  /// `''` | `low` | `medium` | `high` (empty = model default).
  String reasoningEffort;

  // --- Prompt blocks -------------------------------------------------------
  final List<PromptBlock> prompts;
  final List<PromptOrderEntry> promptOrder;

  /// Extension/plugin settings from imports, preserved verbatim.
  final Map<String, dynamic> extensions;

  /// Unmodelled top-level keys from imports, preserved for lossless export.
  final Map<String, dynamic> raw;

  String get displayName => name.trim().isEmpty ? 'Untitled preset' : name.trim();

  PromptBlock? blockById(String identifier) {
    for (final b in prompts) {
      if (b.identifier == identifier) return b;
    }
    return null;
  }

  /// Duplicate under a new id/name for the "copy" action.
  Preset duplicate({String? newName}) => Preset(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: newName ?? '$displayName (copy)',
        colorBand: colorBand,
        providerId: providerId,
        model: model,
        mode: mode,
        temperature: temperature,
        maxResponseTokens: maxResponseTokens,
        maxContext: maxContext,
        useMaxContext: useMaxContext,
        topP: topP,
        topK: topK,
        topA: topA,
        minP: minP,
        frequencyPenalty: frequencyPenalty,
        presencePenalty: presencePenalty,
        repetitionPenalty: repetitionPenalty,
        seed: seed,
        n: n,
        stream: stream,
        stopSequences: List<String>.from(stopSequences),
        namesBehavior: namesBehavior,
        wrapInQuotes: wrapInQuotes,
        squashSystemMessages: squashSystemMessages,
        maxContextUnlocked: maxContextUnlocked,
        reasoningEffort: reasoningEffort,
        prompts: prompts.map((b) => b.copy()).toList(),
        promptOrder: promptOrder.map((e) => e.copy()).toList(),
        extensions: Map<String, dynamic>.from(extensions),
        raw: Map<String, dynamic>.from(raw),
      );

  // PLACEHOLDER_JSON
  /// Our own persistence shape (a superset of every import format), so nothing
  /// is lost across app restarts.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (colorBand != null) 'colorBand': colorBand,
        if (providerId != null) 'providerId': providerId,
        'model': model,
        'mode': mode.name,
        'temperature': temperature,
        'maxResponseTokens': maxResponseTokens,
        'maxContext': maxContext,
        'useMaxContext': useMaxContext,
        'topP': topP,
        'topK': topK,
        'topA': topA,
        'minP': minP,
        'frequencyPenalty': frequencyPenalty,
        'presencePenalty': presencePenalty,
        'repetitionPenalty': repetitionPenalty,
        'seed': seed,
        'n': n,
        'stream': stream,
        'stopSequences': stopSequences,
        'namesBehavior': namesBehavior,
        'wrapInQuotes': wrapInQuotes,
        'squashSystemMessages': squashSystemMessages,
        'maxContextUnlocked': maxContextUnlocked,
        'reasoningEffort': reasoningEffort,
        'prompts': prompts.map((b) => b.toJson()).toList(),
        'promptOrder': promptOrder.map((e) => e.toJson()).toList(),
        if (extensions.isNotEmpty) 'extensions': extensions,
        if (raw.isNotEmpty) 'raw': raw,
      };

  factory Preset.fromJson(Map<String, dynamic> json) {
    List<PromptBlock> blocks() {
      final list = json['prompts'];
      if (list is List && list.isNotEmpty) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(PromptBlock.fromJson)
            .toList();
      }
      return defaultPromptLibrary();
    }

    List<PromptOrderEntry> order() {
      final list = json['promptOrder'];
      if (list is List && list.isNotEmpty) {
        return list
            .whereType<Map<String, dynamic>>()
            .map(PromptOrderEntry.fromJson)
            .toList();
      }
      return defaultPromptOrder();
    }

    List<String> strings(Object? value) => value is List
        ? value.map((e) => e.toString()).where((e) => e.isNotEmpty).toList()
        : <String>[];

    return Preset(
      id: json['id'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '',
      colorBand: (json['colorBand'] as num?)?.toInt(),
      providerId: json['providerId'] as String?,
      model: json['model'] as String? ?? '',
      mode: PresetMode.byName(json['mode'] as String?),
      temperature: (json['temperature'] as num?)?.toDouble() ?? 1.0,
      maxResponseTokens: (json['maxResponseTokens'] as num?)?.toInt() ?? 300,
      maxContext: (json['maxContext'] as num?)?.toInt() ?? 4095,
      useMaxContext: json['useMaxContext'] as bool? ?? false,
      topP: (json['topP'] as num?)?.toDouble() ?? 1.0,
      topK: (json['topK'] as num?)?.toInt() ?? 0,
      topA: (json['topA'] as num?)?.toInt() ?? 0,
      minP: (json['minP'] as num?)?.toDouble() ?? 0.0,
      frequencyPenalty: (json['frequencyPenalty'] as num?)?.toDouble() ?? 0.0,
      presencePenalty: (json['presencePenalty'] as num?)?.toDouble() ?? 0.0,
      repetitionPenalty: (json['repetitionPenalty'] as num?)?.toDouble() ?? 1.0,
      seed: (json['seed'] as num?)?.toInt() ?? -1,
      n: (json['n'] as num?)?.toInt() ?? 1,
      stream: json['stream'] as bool? ?? true,
      stopSequences: strings(json['stopSequences']),
      namesBehavior: (json['namesBehavior'] as num?)?.toInt() ?? 0,
      wrapInQuotes: json['wrapInQuotes'] as bool? ?? false,
      squashSystemMessages: json['squashSystemMessages'] as bool? ?? false,
      maxContextUnlocked: json['maxContextUnlocked'] as bool? ?? false,
      reasoningEffort: json['reasoningEffort'] as String? ?? '',
      prompts: blocks(),
      promptOrder: order(),
      extensions: (json['extensions'] as Map?)?.cast<String, dynamic>(),
      raw: (json['raw'] as Map?)?.cast<String, dynamic>(),
    );
  }
}
