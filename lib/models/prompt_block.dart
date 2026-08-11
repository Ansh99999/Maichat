/// One prompt block in a preset, modelled on SillyTavern's Prompt object.
///
/// A preset holds a *library* of these keyed by [identifier]; the order in which
/// they are assembled and whether each is on lives separately in the preset's
/// prompt order (see [PromptOrderEntry]) — exactly SillyTavern's split, so its
/// presets round-trip losslessly.
library;

/// Where a block lands in the assembled prompt.
enum InjectionPosition {
  /// Placed inline, in prompt-order position (SillyTavern `0`).
  relative,

  /// Injected into the chat history at [PromptBlock.injectionDepth] messages
  /// from the end (SillyTavern `1`).
  absolute;

  int get wire => index; // 0 / 1, matching SillyTavern

  static InjectionPosition fromWire(Object? value) =>
      value == 1 || value == '1' ? InjectionPosition.absolute : InjectionPosition.relative;
}

/// Canonical SillyTavern chat-completion roles.
const kPromptRoles = <String>['system', 'user', 'assistant'];

class PromptBlock {
  PromptBlock({
    required this.identifier,
    this.name = '',
    this.role = 'system',
    this.content = '',
    this.systemPrompt = false,
    this.marker = false,
    this.injectionPosition = InjectionPosition.relative,
    this.injectionDepth = defaultDepth,
    this.injectionOrder = defaultOrder,
    this.injectionTrigger = const <String>[],
    this.forbidOverrides = false,
    Map<String, dynamic>? raw,
  }) : raw = raw ?? <String, dynamic>{};

  static const int defaultDepth = 4;
  static const int defaultOrder = 100;

  /// Unique key referenced by the prompt order (e.g. `main`, `chatHistory`, or a
  /// generated id for a user-made block).
  final String identifier;
  String name;

  /// `system` | `user` | `assistant`.
  String role;

  /// The block text (may contain macros). Empty for [marker] blocks.
  String content;

  /// True for the built-in library blocks (vs. user-created ones); mirrors
  /// SillyTavern's `system_prompt` flag and gates a few UI affordances.
  bool systemPrompt;

  /// A placeholder whose real content is supplied at assembly time from live
  /// data (character fields, chat history, examples, …).
  bool marker;

  InjectionPosition injectionPosition;

  /// For [InjectionPosition.absolute]: how many messages from the end to inject.
  int injectionDepth;

  /// Tiebreaker within a depth bucket; higher wins.
  int injectionOrder;

  /// Generation-type triggers gating injection; empty means always.
  List<String> injectionTrigger;

  /// When true, a character card's main/jailbreak override is ignored.
  bool forbidOverrides;

  /// Any keys we do not model, kept so export stays lossless.
  final Map<String, dynamic> raw;

  bool get isOverridable =>
      identifier == PromptId.main || identifier == PromptId.jailbreak;

  PromptBlock copy() => PromptBlock(
        identifier: identifier,
        name: name,
        role: role,
        content: content,
        systemPrompt: systemPrompt,
        marker: marker,
        injectionPosition: injectionPosition,
        injectionDepth: injectionDepth,
        injectionOrder: injectionOrder,
        injectionTrigger: List<String>.from(injectionTrigger),
        forbidOverrides: forbidOverrides,
        raw: Map<String, dynamic>.from(raw),
      );

  /// SillyTavern-compatible JSON: only marker blocks omit role/content, matching
  /// how ST serializes them.
  Map<String, dynamic> toJson() => {
        ...raw,
        'identifier': identifier,
        'name': name,
        if (systemPrompt) 'system_prompt': true,
        if (marker) 'marker': true,
        if (!marker) 'role': role,
        if (!marker) 'content': content,
        if (injectionPosition == InjectionPosition.absolute)
          'injection_position': injectionPosition.wire,
        if (injectionPosition == InjectionPosition.absolute)
          'injection_depth': injectionDepth,
        if (injectionOrder != defaultOrder) 'injection_order': injectionOrder,
        if (injectionTrigger.isNotEmpty) 'injection_trigger': injectionTrigger,
        if (forbidOverrides) 'forbid_overrides': true,
      };

  factory PromptBlock.fromJson(Map<String, dynamic> json) {
    // Preserve unknown keys for lossless round-trip.
    const known = {
      'identifier', 'name', 'role', 'content', 'system_prompt', 'marker',
      'injection_position', 'injection_depth', 'injection_order',
      'injection_trigger', 'forbid_overrides',
    };
    final raw = <String, dynamic>{
      for (final e in json.entries)
        if (!known.contains(e.key)) e.key: e.value,
    };
    return PromptBlock(
      identifier: json['identifier'] as String? ??
          DateTime.now().microsecondsSinceEpoch.toString(),
      name: json['name'] as String? ?? '',
      role: json['role'] as String? ?? 'system',
      content: json['content'] as String? ?? '',
      systemPrompt: json['system_prompt'] as bool? ?? false,
      marker: json['marker'] as bool? ?? false,
      injectionPosition: InjectionPosition.fromWire(json['injection_position']),
      injectionDepth: (json['injection_depth'] as num?)?.toInt() ?? defaultDepth,
      injectionOrder: (json['injection_order'] as num?)?.toInt() ?? defaultOrder,
      injectionTrigger: (json['injection_trigger'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          const <String>[],
      forbidOverrides: json['forbid_overrides'] as bool? ?? false,
      raw: raw,
    );
  }
}

/// The identifiers of SillyTavern's built-in blocks. Presets reference these by
/// string; markers among them are filled from live data at assembly time.
abstract final class PromptId {
  static const main = 'main';
  static const nsfw = 'nsfw';
  static const dialogueExamples = 'dialogueExamples';
  static const jailbreak = 'jailbreak';
  static const chatHistory = 'chatHistory';
  static const worldInfoAfter = 'worldInfoAfter';
  static const worldInfoBefore = 'worldInfoBefore';
  static const enhanceDefinitions = 'enhanceDefinitions';
  static const charDescription = 'charDescription';
  static const charPersonality = 'charPersonality';
  static const scenario = 'scenario';
  static const personaDescription = 'personaDescription';

  /// Marker identifiers whose content comes from live data, not the block body.
  static const markers = <String>{
    dialogueExamples,
    chatHistory,
    worldInfoAfter,
    worldInfoBefore,
    charDescription,
    charPersonality,
    scenario,
    personaDescription,
  };
}

/// The 12 built-in blocks, matching SillyTavern's `chatCompletionDefaultPrompts`
/// (identifier / marker / role / seed content) so its presets line up exactly.
List<PromptBlock> defaultPromptLibrary() => [
      PromptBlock(
        identifier: PromptId.main,
        name: 'Main Prompt',
        systemPrompt: true,
        content:
            "Write {{char}}'s next reply in a fictional chat between {{char}} and {{user}}.",
      ),
      PromptBlock(identifier: PromptId.nsfw, name: 'Auxiliary Prompt', systemPrompt: true),
      PromptBlock(
          identifier: PromptId.dialogueExamples,
          name: 'Chat Examples',
          systemPrompt: true,
          marker: true),
      PromptBlock(
          identifier: PromptId.jailbreak,
          name: 'Post-History Instructions',
          systemPrompt: true),
      PromptBlock(
          identifier: PromptId.chatHistory,
          name: 'Chat History',
          systemPrompt: true,
          marker: true),
      PromptBlock(
          identifier: PromptId.worldInfoAfter,
          name: 'World Info (after)',
          systemPrompt: true,
          marker: true),
      PromptBlock(
          identifier: PromptId.worldInfoBefore,
          name: 'World Info (before)',
          systemPrompt: true,
          marker: true),
      PromptBlock(
        identifier: PromptId.enhanceDefinitions,
        name: 'Enhance Definitions',
        systemPrompt: true,
        content:
            "If you have more knowledge of {{char}}, add to the character's lore and personality to enhance them but keep the Character Sheet's definitions absolute.",
      ),
      PromptBlock(
          identifier: PromptId.charDescription,
          name: 'Char Description',
          systemPrompt: true,
          marker: true),
      PromptBlock(
          identifier: PromptId.charPersonality,
          name: 'Char Personality',
          systemPrompt: true,
          marker: true),
      PromptBlock(
          identifier: PromptId.scenario, name: 'Scenario', systemPrompt: true, marker: true),
      PromptBlock(
          identifier: PromptId.personaDescription,
          name: 'Persona Description',
          systemPrompt: true,
          marker: true),
    ];

/// The default global prompt order (SillyTavern's `character_id: 100000` record).
List<PromptOrderEntry> defaultPromptOrder() => [
      PromptOrderEntry(identifier: PromptId.main),
      PromptOrderEntry(identifier: PromptId.worldInfoBefore),
      PromptOrderEntry(identifier: PromptId.charDescription),
      PromptOrderEntry(identifier: PromptId.charPersonality),
      PromptOrderEntry(identifier: PromptId.scenario),
      PromptOrderEntry(identifier: PromptId.enhanceDefinitions, enabled: false),
      PromptOrderEntry(identifier: PromptId.nsfw),
      PromptOrderEntry(identifier: PromptId.worldInfoAfter),
      PromptOrderEntry(identifier: PromptId.dialogueExamples),
      PromptOrderEntry(identifier: PromptId.chatHistory),
      PromptOrderEntry(identifier: PromptId.jailbreak),
    ];

/// One entry in a preset's prompt order: which block, and whether it is on.
/// Enabled state lives here (not on the block), matching SillyTavern.
class PromptOrderEntry {
  PromptOrderEntry({required this.identifier, this.enabled = true});

  final String identifier;
  bool enabled;

  PromptOrderEntry copy() =>
      PromptOrderEntry(identifier: identifier, enabled: enabled);

  Map<String, dynamic> toJson() => {'identifier': identifier, 'enabled': enabled};

  factory PromptOrderEntry.fromJson(Map<String, dynamic> json) =>
      PromptOrderEntry(
        identifier: json['identifier'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );
}
