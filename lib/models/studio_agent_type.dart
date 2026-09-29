/// A kind of sub-agent the Studio's `task` tool can start: what it is for, what
/// it is told, which tools it gets, and optionally a model of its own.
///
/// The four built-ins (`general`, `writer`, `lore_writer`, `critic`) are made
/// in code; the rest are the user's, defined in Studio settings ▸ Agents and
/// kept in `StudioConfig.customAgents`.
class StudioAgentType {
  const StudioAgentType({
    required this.id,
    required this.label,
    required this.description,
    this.prompt = '',
    this.toolGroups = const <String>{},
    this.model = '',
    this.builtIn = false,
  });

  /// What the `task` tool's `agent_type` names it by: lower-case words joined
  /// by underscores (`voice_coach`).
  final String id;

  /// How it is shown: "Voice coach".
  final String label;

  /// One or two sentences on what it is for — shown to the main agent in the
  /// `task` tool, which is how the main agent decides to use it.
  final String description;

  /// What the sub-agent is told, before the shared rules every sub-agent gets.
  final String prompt;

  /// The groups of tools it may use (see `kStudioToolGroups`). Empty for a
  /// built-in, whose tools are fixed in code.
  final Set<String> toolGroups;

  /// A model to use instead of the Studio's own, or empty for the Studio's.
  final String model;

  final bool builtIn;

  StudioAgentType copyWith({
    String? id,
    String? label,
    String? description,
    String? prompt,
    Set<String>? toolGroups,
    String? model,
  }) =>
      StudioAgentType(
        id: id ?? this.id,
        label: label ?? this.label,
        description: description ?? this.description,
        prompt: prompt ?? this.prompt,
        toolGroups: toolGroups ?? this.toolGroups,
        model: model ?? this.model,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'description': description,
        if (prompt.isNotEmpty) 'prompt': prompt,
        'tools': (toolGroups.toList()..sort()),
        if (model.isNotEmpty) 'model': model,
      };

  static StudioAgentType? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = studioAgentId(json['id']?.toString() ?? '');
    if (id.isEmpty) return null;
    final label = (json['label']?.toString() ?? '').trim();
    return StudioAgentType(
      id: id,
      label: label.isEmpty ? id.replaceAll('_', ' ') : label,
      description: json['description']?.toString() ?? '',
      prompt: json['prompt']?.toString() ?? '',
      toolGroups: {
        if (json['tools'] is List)
          for (final t in json['tools'] as List) t.toString(),
      },
      model: json['model']?.toString() ?? '',
    );
  }

  static List<StudioAgentType> listFrom(Object? json) => [
        if (json is List)
          for (final item in json) ?fromJson(item),
      ];
}

/// The `agent_type` a label is known by: "Voice Coach!" → `voice_coach`.
String studioAgentId(String label) => label
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
    .replaceAll(RegExp(r'^_+|_+$'), '');

/// Where the Studio's web search goes.
enum StudioSearchProvider {
  /// Wikipedia, and a Fandom wiki when the agent names one — no key needed.
  wiki('Wikipedia & Fandom'),

  /// Brave Search's API, with the user's key.
  brave('Brave Search'),

  /// A SearXNG instance the user points it at (with JSON output enabled).
  searxng('SearXNG');

  const StudioSearchProvider(this.label);
  final String label;

  static StudioSearchProvider byName(Object? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return StudioSearchProvider.wiki;
  }
}
