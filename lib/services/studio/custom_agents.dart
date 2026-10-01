import '../../models/studio.dart';
import 'image_tools.dart';
import 'knowledge_tools.dart';
import 'runtime_tools.dart';
import 'skill_tools.dart';
import 'studio_memory.dart';
import 'studio_prompt.dart';
import 'studio_skills.dart';
import 'studio_tools.dart';
import 'workbench_tools.dart';

/// The groups a custom sub-agent's tools are picked from, in the order the
/// settings page lists them: a label and the tools in it. `todo_write`,
/// `count_tokens` and the notes are always given — they cost nothing — and
/// `task` never is: sub-agents do not
/// start sub-agents.
const Map<String, (String, List<String>)> kStudioToolGroups = {
  'read': (
    'Read the draft and library',
    ['get_draft', 'read_document', 'list_library', 'read_library_item'],
  ),
  'character': (
    'Character fields and greetings',
    ['set_fields', 'edit_field', 'add_greeting', 'remove_greeting'],
  ),
  'scenarios': ('Scenarios', ['upsert_scenario', 'delete_scenario']),
  'lore': (
    'Lorebooks',
    [
      'create_lorebook',
      'update_lorebook',
      'delete_lorebook',
      'upsert_lore_entry',
      'delete_lore_entry',
      'attach_library_lorebook',
    ],
  ),
  'documents': ('Documents', ['upsert_document', 'delete_document']),
  'pictures': ('Portraits and pictures', ['generate_avatar', ...kImageToolNames]),
  'playtest': ('Playtest', ['playtest', 'read_playtests']),
  'web': ('Web research', kWebToolNames),
  'memory': ('Memory', kMemoryToolNames),
};

/// The built-in sub-agent types, as settings shows them.
final List<StudioAgentType> kBuiltInAgentTypes = [
  for (final e in kStudioAgentTypes.entries)
    StudioAgentType(
      id: e.key,
      label: studioAgentTypeLabel(e.key),
      description: e.value,
      prompt: studioAgentPrompt(e.key),
      builtIn: true,
    ),
];

/// Every sub-agent type the `task` tool can start with [config]: the built-in
/// four, then the user's own. A custom type that reuses a built-in's id is
/// left out — the built-in wins, so the tools it expects are always there.
List<StudioAgentType> studioAgentTypes(StudioConfig config) {
  final builtIn = {for (final t in kBuiltInAgentTypes) t.id};
  return [
    ...kBuiltInAgentTypes,
    for (final t in config.customAgents)
      if (!builtIn.contains(t.id)) t,
  ];
}

/// The type named [id], or null.
StudioAgentType? studioAgentType(StudioConfig config, String id) {
  for (final t in studioAgentTypes(config)) {
    if (t.id == id) return t;
  }
  return null;
}

/// Why [id] is not a type the `task` tool can start, written for the model —
/// or null when it is one.
String? studioAgentTypeProblem(StudioConfig config, String id) {
  if (studioAgentType(config, id) != null) return null;
  return 'Unknown agent_type "$id". Use one of: '
      '${studioAgentTypes(config).map((t) => t.id).join(', ')}.';
}

/// The `agent_type` choices and what each is for, one per line — for the
/// `task` tool's description and its enum.
String describeAgentTypes(StudioConfig config) => [
      for (final t in studioAgentTypes(config)) '${t.id} — ${t.description}',
    ].join('\n');

/// The tools an agent of [type] gets under [config]. `studio` is the main
/// agent. Web and memory tools are left out when settings switch them off;
/// sub-agents never get the memory tools (the main agent keeps it) nor
/// `task`.
List<StudioTool> studioToolsForType(
  String type,
  StudioConfig config, {
  bool subAgents = true,
}) {
  final custom = type == 'studio'
      ? null
      : config.customAgents.where((t) => t.id == type).firstOrNull;
  final builtIn = type == 'studio' || kStudioAgentTypes.containsKey(type);
  List<StudioTool> tools;
  if (builtIn || custom == null) {
    tools = studioToolsFor(
      builtIn ? type : 'general',
      subAgents: subAgents && config.subAgents,
    );
  } else {
    final names = <String>{
      for (final g in custom.toolGroups) ...?kStudioToolGroups[g]?.$2,
      'todo_write',
      // Counting and the notes cost nothing and are every agent's.
      ...kWorkbenchAlways,
      ...?kWorkbenchToolsFor['custom'],
      // Like the plan, skills are given to every type: they are advice, and
      // cost nothing until one is loaded.
      ...kSkillToolNames,
      ...?kRuntimeToolsFor['custom'],
    };
    tools = [
      for (final name in names)
        if (kStudioTools[name] != null) kStudioTools[name]!,
    ];
  }
  tools = withoutIdleSkillTools(withoutDisabledKnowledge(tools, config));
  if (type != 'studio') {
    tools = [
      for (final t in tools)
        if (t.name != 'task' && !kMemoryToolNames.contains(t.name)) t,
    ];
  }
  return tools;
}

/// Which part of an agent's instructions a piece of text is — how the context
/// inspector says where the tokens of a system prompt go.
enum StudioPromptPart {
  instructions,
  web,
  agentTypes,
  memory,
  skills,
}

/// The main agent's instructions, as the parts they are made of: the user's
/// own (or the built-in ones), then what it is told about the web, the user's
/// own sub-agent types and its memory — each only when it is on.
/// [studioSystemPrompt] is these joined; the context inspector reads them
/// apart.
List<(StudioPromptPart, String)> studioSystemPromptParts(
  StudioConfig config, [
  StudioMemory? memory,
]) {
  final base = config.systemPrompt.trim().isEmpty
      ? defaultStudioPrompt()
      : config.systemPrompt.trim();
  final custom = [
    for (final t in studioAgentTypes(config))
      if (!t.builtIn) '- ${t.id}: ${t.description}',
  ];
  return [
    (StudioPromptPart.instructions, base),
    if (config.webTools) (StudioPromptPart.web, kStudioWebPrompt.trim()),
    if (config.subAgents && custom.isNotEmpty)
      (
        StudioPromptPart.agentTypes,
        'Sub-agent types the user defined (pass as agent_type)\n'
            '${custom.join('\n')}',
      ),
    if (config.memoryEnabled && memory != null)
      (StudioPromptPart.memory, studioMemoryPrompt(memory.notes)),
    ?_skillsPart(),
  ];
}

/// The main agent's instructions — [studioSystemPromptParts], joined.
String studioSystemPrompt(StudioConfig config, [StudioMemory? memory]) =>
    joinPromptParts(studioSystemPromptParts(config, memory));

/// A sub-agent's instructions for [type], as parts: a built-in's own, or the
/// user's prompt for a type they defined, ahead of the rules every sub-agent
/// shares — then research guidance when it has the web, and the user's
/// remembered preferences (read-only).
List<(StudioPromptPart, String)> studioAgentSystemPromptParts(
  String type,
  StudioConfig config, [
  StudioMemory? memory,
]) {
  final custom = kStudioAgentTypes.containsKey(type)
      ? null
      : config.customAgents.where((t) => t.id == type).firstOrNull;
  final base = custom == null
      ? studioAgentPrompt(type)
      : studioAgentPrompt(
          'general',
          role: [
            'You are ${custom.label} on a character-building team: '
                '${custom.description}',
            if (custom.prompt.trim().isNotEmpty) custom.prompt.trim(),
          ].join('\n\n'),
        );
  final tools = studioToolsForType(type, config);
  final hasWeb = tools.any((t) => kWebToolNames.contains(t.name));
  final notes = config.memoryEnabled && memory != null
      ? studioMemoryNotesPrompt(memory.notes)
      : '';
  return [
    (StudioPromptPart.instructions, base),
    if (hasWeb) (StudioPromptPart.web, kStudioWebPrompt.trim()),
    if (notes.isNotEmpty) (StudioPromptPart.memory, notes),
    ?_skillsPart(),
  ];
}

/// The skills switched on, as every agent is told about them — names and
/// descriptions only — or null when there are none.
(StudioPromptPart, String)? _skillsPart() {
  final text = studioSkillsPrompt(
    StudioSkillLibrary.active?.enabled ?? const [],
  );
  return text.isEmpty ? null : (StudioPromptPart.skills, text);
}

/// A sub-agent's instructions — [studioAgentSystemPromptParts], joined.
String studioAgentSystemPrompt(
  String type,
  StudioConfig config, [
  StudioMemory? memory,
]) =>
    joinPromptParts(studioAgentSystemPromptParts(type, config, memory));

/// How the parts of a system prompt are put together into one.
String joinPromptParts(List<(StudioPromptPart, String)> parts) =>
    [for (final p in parts) p.$2].join('\n\n');

/// The model a sub-agent of [type] runs on, when its type names one of its
/// own; null means the Studio's model.
String? studioAgentModel(String type, StudioConfig config) {
  final custom = config.customAgents.where((t) => t.id == type).firstOrNull;
  final model = custom?.model.trim() ?? '';
  return model.isEmpty ? null : model;
}

/// Which [kStudioToolGroups] a built-in type's tools fall in — how settings
/// shows what a built-in can do.
Set<String> toolGroupsOf(String type) {
  final names = {for (final t in studioToolsFor(type)) t.name};
  return {
    for (final g in kStudioToolGroups.entries)
      if (g.value.$2.any(names.contains)) g.key,
  };
}
