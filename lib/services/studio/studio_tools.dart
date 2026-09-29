import 'dart:convert';

import '../../models/agent_message.dart';
import '../../models/character.dart';
import '../../models/character_scenario.dart';
import '../../models/lorebook.dart';
import '../../models/studio.dart';
import '../../models/studio_revisions.dart';
import 'custom_agents.dart';
import 'image_tools.dart';
import 'knowledge_tools.dart';
import 'runtime_tools.dart';
import 'skill_tools.dart';
import 'studio_knowledge.dart';

/// What a Studio tool can reach beyond the workspace: the library to read from,
/// and the three things that need the rest of the app — a picture, a playtest,
/// and a helper agent. An interface so every tool can be tested against a fake,
/// with no [AppState] and no network.
abstract class StudioServices {
  int countTokens(String text);

  List<Character> get libraryCharacters;
  List<Lorebook> get libraryLorebooks;

  /// Whether pictures can be made (the image studio is set up).
  bool get canGenerateImages;

  /// Makes a picture for [prompt] and returns its stored ref.
  Future<String> generatePicture({
    required String prompt,
    required String characterId,
  });

  /// The draft's replies to each of [userTurns], through the real chat path.
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
  });

  /// Runs a sub-agent of [agentType] on [prompt] — or, with [taskId], carries
  /// on the sub-agent that already has that id — and returns how it went.
  /// [callId] is the `task` call being answered.
  Future<StudioTaskOutcome> runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  });
}

/// How a sub-agent's run ended, as the `task` tool reports it back.
class StudioTaskOutcome {
  const StudioTaskOutcome({
    required this.label,
    required this.taskId,
    required this.status,
    required this.report,
  });

  /// "Subagent 3".
  final String label;

  /// Its id, which a later `task` call can pass to carry it on.
  final String taskId;

  /// `done`, `failed` or `cancelled`.
  final String status;
  final String report;

  bool get failed => status != 'done';
}

/// What running a tool produced: the text the model is sent back, and whether
/// it reports a failure.
class StudioToolResult {
  const StudioToolResult(this.text, {this.isError = false});

  factory StudioToolResult.json(Map<String, dynamic> value) =>
      StudioToolResult(jsonEncode(value));

  factory StudioToolResult.error(String message) =>
      StudioToolResult(jsonEncode({'error': message}), isError: true);

  final String text;
  final bool isError;
}

/// A tool's arguments were wrong. Thrown inside a tool and turned into an error
/// result, so the model reads what to fix instead of the run failing.
class StudioToolError implements Exception {
  StudioToolError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Everything a tool runs against.
class StudioToolContext {
  StudioToolContext({
    required this.session,
    required this.services,
    this.agent = 'studio',
    this.subagent,
    this.call,
    StudioKnowledge? knowledge,
    // A private field cannot be a named initializing formal.
    // ignore: prefer_initializing_formals
  }) : _knowledge = knowledge;

  final StudioSession session;
  final StudioServices services;

  final StudioKnowledge? _knowledge;

  /// The web, the memory and the settings behind them: the one handed in, or
  /// the app's own ([StudioKnowledge.shared]).
  StudioKnowledge get knowledge => _knowledge ?? StudioKnowledge.shared;

  /// Which agent is calling, recorded on its changes (`Subagent 3`, …).
  final String agent;

  /// The sub-agent calling, or null for the main agent.
  final StudioSubagent? subagent;

  /// The call being answered, when the runner says.
  final ToolCall? call;

  /// This context for answering [call].
  StudioToolContext forCall(ToolCall call) => StudioToolContext(
        session: session,
        services: services,
        agent: agent,
        subagent: subagent,
        call: call,
        knowledge: _knowledge,
      );

  /// The calling agent's own plan: the sub-agent's, or the session's.
  List<StudioTodo> get todos => subagent?.todos ?? session.todos;

  StudioWorkspace get ws => session.workspace;
  Character get character => session.workspace.character;

  /// Makes a change, recorded for the Changes tab and for rewinding. What it
  /// touched counts as seen by this agent at its new revision — an agent's own
  /// writes never make its next write stale.
  void edit(String tool, String summary, void Function(StudioWorkspace ws) change) {
    final touched =
        session.edit(agent == 'studio' ? tool : '$agent · $tool', summary, change);
    markSeen(touched);
  }

  StudioToolContext as(String agentName, {StudioSubagent? subagent}) =>
      StudioToolContext(
        session: session,
        services: services,
        agent: agentName,
        subagent: subagent,
        knowledge: _knowledge,
      );

  // --- stale-edit protection ------------------------------------------------

  /// Records that this agent has now seen [parts] as they are.
  void markSeen(Iterable<String> parts) {
    final seen = session.seenBy(agent);
    for (final key in parts) {
      seen[key] = session.revisions[key]?.rev ?? 0;
    }
  }

  /// Refuses a write to any of [parts] that somebody else changed after this
  /// agent last read it — the draft's version of "file modified since read".
  /// The message says who, and what to read again ([reread]).
  void ensureFresh(Iterable<String> parts, {String reread = 'get_draft'}) {
    final seen = session.seenBy(agent);
    final me = editorForAgent(agent);
    for (final key in parts) {
      final latest = session.revisions[key];
      if (latest == null || latest.by == me) continue;
      if (latest.rev <= (seen[key] ?? 0)) continue;
      final what = describePart(ws, key);
      throw StudioToolError(
        '${what[0].toUpperCase()}${what.substring(1)} was changed by '
        '${latest.by} since you last read it. Call $reread and redo the '
        'change on the current text.',
      );
    }
  }
}

typedef StudioToolRun = Future<StudioToolResult> Function(
  StudioToolContext ctx,
  Map<String, dynamic> args,
);

class StudioTool {
  const StudioTool(this.spec, this.run);

  final ToolSpec spec;
  final StudioToolRun run;

  String get name => spec.name;

  /// Runs the tool, turning a bad argument (or anything else it throws) into an
  /// error result the model can read and act on.
  Future<StudioToolResult> call(
    StudioToolContext ctx,
    Map<String, dynamic> args,
  ) async {
    try {
      return await run(ctx, args);
    } on StudioToolError catch (e) {
      return StudioToolResult.error(e.message);
    } catch (e) {
      return StudioToolResult.error('$name failed: $e');
    }
  }
}

// --- argument readers --------------------------------------------------------

String _str(Map<String, dynamic> args, String key, {bool required = false}) {
  final value = args[key];
  if (value == null) {
    if (required) throw StudioToolError('"$key" is required.');
    return '';
  }
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  throw StudioToolError('"$key" must be a string.');
}

String? _optStr(Map<String, dynamic> args, String key) =>
    args.containsKey(key) && args[key] != null ? _str(args, key) : null;

int? _optInt(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  throw StudioToolError('"$key" must be a whole number.');
}

bool? _optBool(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is bool) return value;
  if (value is String) {
    if (value.toLowerCase() == 'true') return true;
    if (value.toLowerCase() == 'false') return false;
  }
  throw StudioToolError('"$key" must be true or false.');
}

List<String>? _optList(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is List) {
    return [
      for (final v in value)
        if (v != null && v.toString().trim().isNotEmpty) v.toString().trim(),
    ];
  }
  // A model that sends "a, b, c" for a list meant the obvious thing.
  if (value is String) {
    return value
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }
  throw StudioToolError('"$key" must be a list of strings.');
}

String _newId() => DateTime.now().microsecondsSinceEpoch.toString();

String _preview(String text, [int max = 280]) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}

// --- character fields ---------------------------------------------------------

/// A text field of the card, as tools name it.
class _TextField {
  const _TextField(this.key, this.label, this.read, this.write);

  final String key;
  final String label;
  final String Function(Character c) read;
  final void Function(Character c, String value) write;
}

final List<_TextField> _textFields = [
  _TextField('name', 'name', (c) => c.name, (c, v) => c.name = v),
  _TextField('title', 'title', (c) => c.title, (c, v) {
    c.title = v;
    c.titleShown = v.trim().isNotEmpty;
  }),
  _TextField('description', 'description', (c) => c.description,
      (c, v) => c.description = v),
  _TextField('personality', 'personality', (c) => c.personality,
      (c, v) => c.personality = v),
  _TextField('scenario', 'scenario', (c) => c.scenario, (c, v) => c.scenario = v),
  _TextField('first_message', 'first message', (c) => c.firstMes,
      (c, v) => c.firstMes = v),
  _TextField('example_dialogue', 'example dialogue', (c) => c.mesExample,
      (c, v) => c.mesExample = v),
  _TextField('system_prompt', 'system prompt', (c) => c.systemPrompt,
      (c, v) => c.systemPrompt = v),
  _TextField('post_history_instructions', 'post-history instructions',
      (c) => c.postHistoryInstructions, (c, v) => c.postHistoryInstructions = v),
  _TextField('creator_notes', 'creator notes', (c) => c.creatorNotes,
      (c, v) => c.creatorNotes = v),
  _TextField('creator', 'creator', (c) => c.creator, (c, v) => c.creator = v),
  _TextField('character_version', 'version', (c) => c.characterVersion,
      (c, v) => c.characterVersion = v),
];

_TextField? _field(String key) {
  for (final f in _textFields) {
    if (f.key == key) return f;
  }
  return null;
}

/// The draft as the model reads it back. Every field is here in full — a model
/// editing a card needs its actual words — alongside the token counts it is
/// asked to budget against.
Map<String, dynamic> describeCharacter(Character c, StudioServices services) {
  final out = <String, dynamic>{
    for (final f in _textFields) f.key: f.read(c),
    'alternate_greetings': c.alternateGreetings,
    'tags': c.tags,
    'has_avatar': c.hasAvatar,
    'scenarios': [
      for (final s in c.scenarios)
        {
          'id': s.id,
          'name': s.name,
          'text': s.text,
          'greetings': s.greetings.isEmpty ? 'all' : s.greetings,
        },
    ],
  };
  final counts = <String, int>{};
  for (final f in _textFields) {
    final text = f.read(c);
    if (text.trim().isNotEmpty) counts[f.key] = services.countTokens(text);
  }
  for (var i = 0; i < c.alternateGreetings.length; i++) {
    counts['alternate_greetings[$i]'] =
        services.countTokens(c.alternateGreetings[i]);
  }
  out['token_counts'] = counts;
  // What every chat with this card pays before anyone speaks.
  out['permanent_tokens'] = services.countTokens(
    [c.description, c.personality, c.scenario, c.mesExample, c.systemPrompt,
            c.postHistoryInstructions]
        .join('\n'),
  );
  return out;
}

Map<String, dynamic> describeEntry(LorebookEntry e) => {
      'uid': e.uid,
      'name': e.name,
      'keys': e.keys,
      if (e.secondaryKeys.isNotEmpty) 'secondary_keys': e.secondaryKeys,
      'content': e.content,
      if (e.constant) 'constant': true,
      if (!e.enabled) 'enabled': false,
      'order': e.weight,
      'position': _positionName(e.position),
      if (e.position == LorebookPosition.atDepth) 'depth': e.depth,
    };

Map<String, dynamic> describeLorebook(Lorebook b, {bool entries = true}) => {
      'id': b.id,
      'name': b.name,
      if (b.description.isNotEmpty) 'description': b.description,
      if (b.scanDepth != null) 'scan_depth': b.scanDepth,
      if (b.tokenBudget != null) 'token_budget': b.tokenBudget,
      if (b.recursive) 'recursive': true,
      if (entries) 'entries': [for (final e in b.entries) describeEntry(e)]
      else 'entry_count': b.entries.length,
    };

const Map<String, LorebookPosition> _positions = {
  'before_char': LorebookPosition.beforeChar,
  'after_char': LorebookPosition.afterChar,
  'before_examples': LorebookPosition.emTop,
  'after_examples': LorebookPosition.emBottom,
  'at_depth': LorebookPosition.atDepth,
};

String _positionName(LorebookPosition p) {
  for (final entry in _positions.entries) {
    if (entry.value == p) return entry.key;
  }
  return 'before_char';
}

Lorebook _book(StudioToolContext ctx, Map<String, dynamic> args) {
  final id = _str(args, 'lorebook_id', required: true);
  final book = ctx.ws.lorebook(id);
  if (book == null) {
    final known = ctx.ws.lorebooks.map((b) => '${b.id} (${b.displayName})');
    throw StudioToolError(
      'No lorebook "$id" in the draft. '
      '${known.isEmpty ? 'There are none yet — create_lorebook first.' : 'Known: ${known.join(', ')}.'}',
    );
  }
  return book;
}

// --- the tools ----------------------------------------------------------------

const _string = {'type': 'string'};
const _stringList = {
  'type': 'array',
  'items': {'type': 'string'},
};

final StudioTool getDraftTool = StudioTool(
  const ToolSpec(
    name: 'get_draft',
    description: 'Reads the draft being built: every character field in full '
        'with token counts, the lorebooks and their entries, the scenarios and '
        'the documents. Call this before editing anything you have not just '
        'written yourself.',
    parameters: {
      'type': 'object',
      'properties': {
        'section': {
          'type': 'string',
          'enum': ['all', 'character', 'lorebooks', 'documents'],
          'description': 'Only this part of the draft. Defaults to all.',
        },
      },
    },
  ),
  (ctx, args) async {
    final section = _optStr(args, 'section') ?? 'all';
    final all = section == 'all';
    // What is read here is what this agent may now change without refusal.
    // Documents are listed only in preview, so they are not counted as read:
    // read_document reads one whole.
    if (all || section == 'character') {
      ctx.markSeen([
        ...partsWithPrefix(ctx.ws, 'field:'),
        ...partsWithPrefix(ctx.ws, 'greeting:'),
        ...partsWithPrefix(ctx.ws, 'scenario:'),
      ]);
    }
    if (all || section == 'lorebooks') {
      ctx.markSeen([
        ...partsWithPrefix(ctx.ws, 'book:'),
        ...partsWithPrefix(ctx.ws, 'entry:'),
      ]);
    }
    return StudioToolResult.json({
      if (all || section == 'character')
        'character': describeCharacter(ctx.character, ctx.services),
      if (all || section == 'lorebooks')
        'lorebooks': [for (final b in ctx.ws.lorebooks) describeLorebook(b)],
      if (all || section == 'documents')
        'documents': [
          for (final d in ctx.ws.documents)
            {
              'id': d.id,
              'name': d.name,
              'tokens': ctx.services.countTokens(d.text),
              'preview': _preview(d.text),
            },
        ],
    });
  },
);

final StudioTool setFieldsTool = StudioTool(
  ToolSpec(
    name: 'set_fields',
    description: 'Writes one or more character fields, replacing what they '
        'held. Pass only the fields you are changing. For a small change to a '
        'long field, edit_field is cheaper.',
    parameters: {
      'type': 'object',
      'properties': {
        for (final f in _textFields) f.key: {..._string, 'description': f.label},
        'tags': {..._stringList, 'description': 'Replaces the tag list.'},
        'alternate_greetings': {
          ..._stringList,
          'description': 'Replaces every alternate greeting.',
        },
      },
    },
  ),
  (ctx, args) async {
    final changes = <void Function(Character)>[];
    final changed = <String>[];
    for (final f in _textFields) {
      final value = _optStr(args, f.key);
      if (value == null) continue;
      changes.add((c) => f.write(c, value.trim()));
      changed.add(f.key);
    }
    final tags = _optList(args, 'tags');
    if (tags != null) {
      changes.add((c) => c.tags = tags.map((t) => t.toLowerCase()).toSet().toList());
      changed.add('tags');
    }
    final alternates = _optList(args, 'alternate_greetings');
    if (alternates != null) {
      changes.add((c) => c.alternateGreetings = alternates);
      changed.add('alternate_greetings');
    }
    final unknown = args.keys
        .where((k) => !changed.contains(k) && args[k] != null)
        .toList();
    if (changed.isEmpty) {
      throw StudioToolError(unknown.isEmpty
          ? 'Pass at least one field to set.'
          : 'Unknown field(s): ${unknown.join(', ')}. Fields are: '
              '${[..._textFields.map((f) => f.key), 'tags', 'alternate_greetings'].join(', ')}.');
    }
    ctx.ensureFresh([
      for (final k in changed)
        if (k == 'alternate_greetings')
          ...partsWithPrefix(ctx.ws, 'greeting:')
        else
          'field:$k',
    ]);
    ctx.edit('set_fields', 'Set ${changed.map((k) => _field(k)?.label ?? k.replaceAll('_', ' ')).join(', ')}', (ws) {
      for (final change in changes) {
        change(ws.character);
      }
    });
    return StudioToolResult.json({
      'ok': true,
      'changed': changed,
      if (unknown.isNotEmpty) 'ignored_unknown_fields': unknown,
      'token_counts': {
        for (final k in changed)
          if (_field(k) != null)
            k: ctx.services.countTokens(_field(k)!.read(ctx.character)),
      },
    });
  },
);

final StudioTool editFieldTool = StudioTool(
  ToolSpec(
    name: 'edit_field',
    description: 'Replaces an exact passage inside one field, leaving the rest '
        'untouched. `find` must match the current text exactly and only once '
        '(unless replace_all). For an alternate greeting, pass its index.',
    parameters: {
      'type': 'object',
      'properties': {
        'field': {
          'type': 'string',
          'enum': [..._textFields.map((f) => f.key), 'alternate_greeting'],
        },
        'index': {
          'type': 'integer',
          'description': 'Which alternate greeting (0-based), for that field.',
        },
        'find': _string,
        'replace': _string,
        'replace_all': {'type': 'boolean'},
      },
      'required': ['field', 'find', 'replace'],
    },
  ),
  (ctx, args) async {
    final key = _str(args, 'field', required: true);
    final find = _str(args, 'find', required: true);
    final replace = _str(args, 'replace');
    final all = _optBool(args, 'replace_all') ?? false;
    if (find.isEmpty) throw StudioToolError('"find" cannot be empty.');

    String current;
    void Function(Character c, String v) write;
    String label;
    if (key == 'alternate_greeting') {
      final index = _optInt(args, 'index');
      final greetings = ctx.character.alternateGreetings;
      if (index == null || index < 0 || index >= greetings.length) {
        throw StudioToolError(
          'Pass "index" 0–${greetings.length - 1} for an alternate greeting.',
        );
      }
      ctx.ensureFresh(['greeting:$index']);
      current = greetings[index];
      write = (c, v) => c.alternateGreetings[index] = v;
      label = 'alternate greeting ${index + 1}';
    } else {
      final f = _field(key);
      if (f == null) throw StudioToolError('Unknown field "$key".');
      ctx.ensureFresh(['field:$key']);
      current = f.read(ctx.character);
      write = f.write;
      label = f.label;
    }
    final count = find.allMatches(current).length;
    if (count == 0) {
      throw StudioToolError(
        'That passage is not in the $label. Read it again with get_draft; '
        'find must match exactly, whitespace included.',
      );
    }
    if (count > 1 && !all) {
      throw StudioToolError(
        'That passage appears $count times in the $label. Include more '
        'surrounding text, or pass replace_all.',
      );
    }
    final next = all
        ? current.replaceAll(find, replace)
        : current.replaceFirst(find, replace);
    ctx.edit('edit_field', 'Edited the $label', (ws) => write(ws.character, next));
    return StudioToolResult.json({
      'ok': true,
      'replaced': all ? count : 1,
      'tokens': ctx.services.countTokens(next),
    });
  },
);

final StudioTool addGreetingTool = StudioTool(
  const ToolSpec(
    name: 'add_greeting',
    description: 'Adds an alternate greeting — another opening the user can '
        'swipe to. Sets the first message instead when there is none yet.',
    parameters: {
      'type': 'object',
      'properties': {'text': _string},
      'required': ['text'],
    },
  ),
  (ctx, args) async {
    final text = _str(args, 'text', required: true).trim();
    if (text.isEmpty) throw StudioToolError('"text" cannot be empty.');
    if (ctx.character.firstMes.trim().isEmpty) {
      ctx.edit('add_greeting', 'Wrote the first message',
          (ws) => ws.character.firstMes = text);
      return StudioToolResult.json({'ok': true, 'set': 'first_message'});
    }
    final index = ctx.character.alternateGreetings.length;
    ctx.edit('add_greeting', 'Added alternate greeting ${index + 1}',
        (ws) => ws.character.alternateGreetings.add(text));
    return StudioToolResult.json({'ok': true, 'alternate_greeting_index': index});
  },
);

final StudioTool removeGreetingTool = StudioTool(
  const ToolSpec(
    name: 'remove_greeting',
    description: 'Deletes one alternate greeting by its 0-based index.',
    parameters: {
      'type': 'object',
      'properties': {
        'index': {'type': 'integer'},
      },
      'required': ['index'],
    },
  ),
  (ctx, args) async {
    final index = _optInt(args, 'index');
    final greetings = ctx.character.alternateGreetings;
    if (index == null || index < 0 || index >= greetings.length) {
      throw StudioToolError(greetings.isEmpty
          ? 'There are no alternate greetings.'
          : 'Pass "index" 0–${greetings.length - 1}.');
    }
    ctx.ensureFresh(['greeting:$index']);
    ctx.edit('remove_greeting', 'Removed alternate greeting ${index + 1}',
        (ws) => ws.character.alternateGreetings.removeAt(index));
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool upsertScenarioTool = StudioTool(
  const ToolSpec(
    name: 'upsert_scenario',
    description: 'Writes one of the character\'s own scenarios — a situation '
        'tied to particular greetings (for a card whose openings happen in '
        'different places). Pass id to rewrite an existing one. For a single '
        'situation that covers every greeting, set the "scenario" field '
        'instead.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': _string,
        'name': _string,
        'text': _string,
        'greetings': {
          'type': 'array',
          'items': {'type': 'integer'},
          'description': 'Greeting indexes it applies to: 0 is the first '
              'message, 1 the first alternate. Empty or left out means all.',
        },
      },
      'required': ['name', 'text'],
    },
  ),
  (ctx, args) async {
    final id = _optStr(args, 'id');
    final name = _str(args, 'name', required: true).trim();
    final text = _str(args, 'text', required: true).trim();
    final rawGreetings = args['greetings'];
    final greetings = <int>[
      if (rawGreetings is List)
        for (final g in rawGreetings)
          if (g is num) g.toInt() else if (int.tryParse('$g') != null) int.parse('$g'),
    ];
    final existing = id == null
        ? null
        : ctx.character.scenarios.where((s) => s.id == id).firstOrNull;
    if (id != null && existing == null) {
      throw StudioToolError('No scenario "$id". Leave id out to add one.');
    }
    if (id != null) ctx.ensureFresh(['scenario:$id']);
    final newId = id ?? _newId();
    ctx.edit(
      'upsert_scenario',
      existing == null ? 'Added scenario "$name"' : 'Rewrote scenario "$name"',
      (ws) {
        final list = ws.character.scenarios;
        final at = list.indexWhere((s) => s.id == newId);
        final scenario = CharacterScenario(
          id: newId,
          name: name,
          text: text,
          greetings: greetings,
        );
        if (at == -1) {
          list.add(scenario);
        } else {
          list[at] = scenario;
        }
      },
    );
    return StudioToolResult.json({'ok': true, 'id': newId});
  },
);

final StudioTool deleteScenarioTool = StudioTool(
  const ToolSpec(
    name: 'delete_scenario',
    description: 'Deletes one of the character\'s own scenarios by id.',
    parameters: {
      'type': 'object',
      'properties': {'id': _string},
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    final id = _str(args, 'id', required: true);
    final scenario = ctx.character.scenarios.where((s) => s.id == id).firstOrNull;
    if (scenario == null) throw StudioToolError('No scenario "$id".');
    ctx.ensureFresh(['scenario:$id']);
    ctx.edit('delete_scenario', 'Deleted scenario "${scenario.displayName}"',
        (ws) => ws.character.scenarios.removeWhere((s) => s.id == id));
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool createLorebookTool = StudioTool(
  const ToolSpec(
    name: 'create_lorebook',
    description: 'Creates a lorebook and attaches it to the character. Returns '
        'its id, which the entry tools need.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': _string,
        'description': _string,
      },
      'required': ['name'],
    },
  ),
  (ctx, args) async {
    final name = _str(args, 'name', required: true).trim();
    if (name.isEmpty) throw StudioToolError('"name" cannot be empty.');
    final id = _newId();
    ctx.edit('create_lorebook', 'Created lorebook "$name"', (ws) {
      ws.lorebooks.add(Lorebook(
        id: id,
        name: name,
        description: _str(args, 'description').trim(),
      ));
      ws.character.lorebookIds.add(id);
    });
    return StudioToolResult.json({'ok': true, 'lorebook_id': id});
  },
);

final StudioTool updateLorebookTool = StudioTool(
  const ToolSpec(
    name: 'update_lorebook',
    description: 'Renames a lorebook or changes its settings.',
    parameters: {
      'type': 'object',
      'properties': {
        'lorebook_id': _string,
        'name': _string,
        'description': _string,
        'scan_depth': {
          'type': 'integer',
          'description': 'How many recent messages are scanned for keys.',
        },
        'token_budget': {
          'type': 'integer',
          'description': 'Most tokens its entries may add to one prompt.',
        },
        'recursive': {
          'type': 'boolean',
          'description': 'Whether an activated entry\'s text can trigger others.',
        },
      },
      'required': ['lorebook_id'],
    },
  ),
  (ctx, args) async {
    final book = _book(ctx, args);
    final name = _optStr(args, 'name');
    final description = _optStr(args, 'description');
    final scanDepth = _optInt(args, 'scan_depth');
    final budget = _optInt(args, 'token_budget');
    final recursive = _optBool(args, 'recursive');
    ctx.ensureFresh(['book:${book.id}']);
    ctx.edit('update_lorebook', 'Updated lorebook "${name ?? book.displayName}"',
        (ws) {
      final b = ws.lorebook(book.id)!;
      if (name != null) b.name = name.trim();
      if (description != null) b.description = description.trim();
      if (scanDepth != null) b.scanDepth = scanDepth;
      if (budget != null) b.tokenBudget = budget;
      if (recursive != null) b.recursive = recursive;
    });
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool deleteLorebookTool = StudioTool(
  const ToolSpec(
    name: 'delete_lorebook',
    description: 'Removes a lorebook from the draft and detaches it. A book '
        'that came from the library stays in the library.',
    parameters: {
      'type': 'object',
      'properties': {'lorebook_id': _string},
      'required': ['lorebook_id'],
    },
  ),
  (ctx, args) async {
    final book = _book(ctx, args);
    ctx.ensureFresh([
      'book:${book.id}',
      ...partsWithPrefix(ctx.ws, 'entry:${book.id}:'),
    ]);
    ctx.edit('delete_lorebook', 'Removed lorebook "${book.displayName}"', (ws) {
      ws.lorebooks.removeWhere((b) => b.id == book.id);
      ws.character.lorebookIds.remove(book.id);
    });
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool upsertLoreEntryTool = StudioTool(
  const ToolSpec(
    name: 'upsert_lore_entry',
    description: 'Writes one lorebook entry. Leave uid out to add a new one; '
        'pass it to rewrite that entry (fields you leave out keep their '
        'values). An entry is sent to the model only when one of its keys '
        'appears in the recent chat, unless it is constant.',
    parameters: {
      'type': 'object',
      'properties': {
        'lorebook_id': _string,
        'uid': {'type': 'integer'},
        'name': _string,
        'keys': {
          ..._stringList,
          'description': 'Words that activate it: names, places, specific '
              'nouns. Matched case-insensitively.',
        },
        'secondary_keys': {
          ..._stringList,
          'description': 'When set, at least one of these must also appear.',
        },
        'content': _string,
        'constant': {
          'type': 'boolean',
          'description': 'Always sent, whatever the chat says. Use sparingly.',
        },
        'enabled': {'type': 'boolean'},
        'order': {
          'type': 'integer',
          'description': 'Higher lands closer to the reply. Default 100.',
        },
        'position': {
          'type': 'string',
          'enum': [
            'before_char',
            'after_char',
            'before_examples',
            'after_examples',
            'at_depth',
          ],
        },
        'depth': {
          'type': 'integer',
          'description': 'Messages from the end, for at_depth.',
        },
      },
      'required': ['lorebook_id'],
    },
  ),
  (ctx, args) async {
    final book = _book(ctx, args);
    final uid = _optInt(args, 'uid');
    final existing = uid == null
        ? null
        : book.entries.where((e) => e.uid == uid).firstOrNull;
    if (uid != null && existing == null) {
      throw StudioToolError(
        'No entry $uid in "${book.displayName}". Leave uid out to add one.',
      );
    }
    if (uid != null) ctx.ensureFresh(['entry:${book.id}:$uid']);
    final name = _optStr(args, 'name');
    final keys = _optList(args, 'keys');
    final secondary = _optList(args, 'secondary_keys');
    final content = _optStr(args, 'content');
    final constant = _optBool(args, 'constant');
    final enabled = _optBool(args, 'enabled');
    final order = _optInt(args, 'order');
    final positionName = _optStr(args, 'position');
    final depth = _optInt(args, 'depth');
    final position = positionName == null ? null : _positions[positionName];
    if (positionName != null && position == null) {
      throw StudioToolError('Unknown position "$positionName".');
    }
    if (existing == null) {
      if ((content ?? '').trim().isEmpty) {
        throw StudioToolError('A new entry needs "content".');
      }
      if (!(constant ?? false) && (keys ?? const []).isEmpty) {
        throw StudioToolError(
          'A new entry needs "keys" (or constant: true) — without either it '
          'would never be sent.',
        );
      }
    }
    final targetUid = uid ?? book.nextUid;
    final label = (name ?? existing?.name ?? '').trim();
    ctx.edit(
      'upsert_lore_entry',
      '${existing == null ? 'Added' : 'Rewrote'} lore entry '
          '"${label.isEmpty ? (keys ?? existing?.keys ?? const ['?']).first : label}"'
          ' in "${book.displayName}"',
      (ws) {
        final b = ws.lorebook(book.id)!;
        var entry = b.entries.where((e) => e.uid == targetUid).firstOrNull;
        if (entry == null) {
          entry = LorebookEntry(uid: targetUid);
          b.entries.add(entry);
        }
        if (name != null) entry.name = name.trim();
        if (keys != null) entry.keys = keys;
        if (secondary != null) entry.secondaryKeys = secondary;
        if (content != null) entry.content = content.trim();
        if (constant != null) entry.constant = constant;
        if (enabled != null) entry.enabled = enabled;
        if (order != null) {
          entry.weight = order;
          entry.priority = order;
        }
        if (position != null) entry.position = position;
        if (depth != null) entry.depth = depth;
      },
    );
    final entry = ctx.ws.lorebook(book.id)!.entries
        .firstWhere((e) => e.uid == targetUid);
    return StudioToolResult.json({
      'ok': true,
      'uid': targetUid,
      'tokens': ctx.services.countTokens(entry.content),
    });
  },
);

final StudioTool deleteLoreEntryTool = StudioTool(
  const ToolSpec(
    name: 'delete_lore_entry',
    description: 'Deletes one lorebook entry.',
    parameters: {
      'type': 'object',
      'properties': {
        'lorebook_id': _string,
        'uid': {'type': 'integer'},
      },
      'required': ['lorebook_id', 'uid'],
    },
  ),
  (ctx, args) async {
    final book = _book(ctx, args);
    final uid = _optInt(args, 'uid');
    final entry = book.entries.where((e) => e.uid == uid).firstOrNull;
    if (entry == null) throw StudioToolError('No entry $uid in "${book.displayName}".');
    ctx.ensureFresh(['entry:${book.id}:$uid']);
    ctx.edit('delete_lore_entry',
        'Deleted lore entry "${entry.displayName}" from "${book.displayName}"',
        (ws) => ws.lorebook(book.id)!.entries.removeWhere((e) => e.uid == uid));
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool upsertDocumentTool = StudioTool(
  const ToolSpec(
    name: 'upsert_document',
    description: 'Writes a background document for the embeddings library — '
        'history, a setting guide, anything too long or loose for lorebook '
        'entries. It is recalled by meaning during chats once embeddings are '
        'on. Pass id to rewrite one.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': _string,
        'name': _string,
        'text': _string,
      },
      'required': ['name', 'text'],
    },
  ),
  (ctx, args) async {
    final id = _optStr(args, 'id');
    final name = _str(args, 'name', required: true).trim();
    final text = _str(args, 'text', required: true).trim();
    if (text.isEmpty) throw StudioToolError('"text" cannot be empty.');
    if (id != null && ctx.ws.document(id) == null) {
      throw StudioToolError('No document "$id". Leave id out to add one.');
    }
    if (id != null) ctx.ensureFresh(['doc:$id'], reread: 'read_document');
    final newId = id ?? _newId();
    ctx.edit('upsert_document',
        '${id == null ? 'Wrote' : 'Rewrote'} document "$name"', (ws) {
      final doc = ws.document(newId);
      if (doc == null) {
        ws.documents.add(StudioDocument(id: newId, name: name, text: text));
      } else {
        doc
          ..name = name
          ..text = text;
      }
    });
    return StudioToolResult.json({
      'ok': true,
      'id': newId,
      'tokens': ctx.services.countTokens(text),
    });
  },
);

final StudioTool readDocumentTool = StudioTool(
  const ToolSpec(
    name: 'read_document',
    description: 'Reads one of the draft\'s documents in full.',
    parameters: {
      'type': 'object',
      'properties': {'id': _string},
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    final doc = ctx.ws.document(_str(args, 'id', required: true));
    if (doc == null) throw StudioToolError('No such document.');
    ctx.markSeen(['doc:${doc.id}']);
    return StudioToolResult.json({'id': doc.id, 'name': doc.name, 'text': doc.text});
  },
);

final StudioTool deleteDocumentTool = StudioTool(
  const ToolSpec(
    name: 'delete_document',
    description: 'Removes a document from the draft.',
    parameters: {
      'type': 'object',
      'properties': {'id': _string},
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    final id = _str(args, 'id', required: true);
    final doc = ctx.ws.document(id);
    if (doc == null) throw StudioToolError('No such document.');
    ctx.ensureFresh(['doc:$id'], reread: 'read_document');
    ctx.edit('delete_document', 'Removed document "${doc.name}"',
        (ws) => ws.documents.removeWhere((d) => d.id == id));
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool generateAvatarTool = StudioTool(
  const ToolSpec(
    name: 'generate_avatar',
    description: 'Paints the character\'s portrait with the image studio and '
        'makes it their avatar. Describe the picture itself — subject, look, '
        'framing, style — not the character\'s backstory.',
    parameters: {
      'type': 'object',
      'properties': {'prompt': _string},
      'required': ['prompt'],
    },
  ),
  (ctx, args) async {
    if (!ctx.services.canGenerateImages) {
      throw StudioToolError(
        'The image studio is not set up, so no picture can be made. Tell the '
        'user they can add an image endpoint in the image studio settings.',
      );
    }
    final prompt = _str(args, 'prompt', required: true).trim();
    if (prompt.isEmpty) throw StudioToolError('"prompt" cannot be empty.');
    final ref = await ctx.services.generatePicture(
      prompt: prompt,
      characterId: ctx.character.id,
    );
    ctx.edit('generate_avatar', 'Painted a new portrait', (ws) {
      final c = ws.character;
      // The old picture joins the pool instead of being lost.
      if (c.hasAvatar && !c.avatars.contains(c.avatar)) c.avatars.add(c.avatar);
      c.avatar = ref;
    });
    return StudioToolResult.json({'ok': true});
  },
);

final StudioTool playtestTool = StudioTool(
  const ToolSpec(
    name: 'playtest',
    description: 'Chats with the draft as a user would, through the real chat '
        'prompt (the user\'s preset, persona and model, the draft\'s lorebooks), '
        'and returns what the character said. Each message is sent in turn, '
        'after the chosen greeting. Use it to hear the voice, check that lore '
        'triggers, and catch the card breaking character.',
    parameters: {
      'type': 'object',
      'properties': {
        'messages': {
          ..._stringList,
          'description': 'What the user says, one entry per turn (at most 4).',
        },
        'greeting_index': {
          'type': 'integer',
          'description': '0 is the first message, 1 the first alternate.',
        },
      },
      'required': ['messages'],
    },
  ),
  (ctx, args) async {
    final turns = _optList(args, 'messages') ?? const <String>[];
    if (turns.isEmpty) throw StudioToolError('Pass at least one message.');
    if (turns.length > 4) {
      throw StudioToolError('At most 4 messages per playtest.');
    }
    if (ctx.character.name.trim().isEmpty) {
      throw StudioToolError('Give the character a name first.');
    }
    final replies = await ctx.services.playtest(
      character: ctx.character.clone(),
      lorebooks: [for (final b in ctx.ws.lorebooks) b.copyWith()],
      userTurns: turns,
      greetingIndex: _optInt(args, 'greeting_index') ?? 0,
    );
    return StudioToolResult.json({
      'transcript': [
        for (var i = 0; i < turns.length; i++) ...[
          {'user': turns[i]},
          {ctx.character.displayName: i < replies.length ? replies[i] : ''},
        ],
      ],
    });
  },
);

final StudioTool listLibraryTool = StudioTool(
  const ToolSpec(
    name: 'list_library',
    description: 'Lists what is already in the user\'s library — characters or '
        'lorebooks — with ids, for reference or to bring a lorebook in.',
    parameters: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': ['characters', 'lorebooks'],
        },
        'search': {
          'type': 'string',
          'description': 'Only items whose name or text contains this.',
        },
      },
      'required': ['kind'],
    },
  ),
  (ctx, args) async {
    final kind = _str(args, 'kind', required: true);
    final search = _str(args, 'search').trim().toLowerCase();
    if (kind == 'characters') {
      final matches = ctx.services.libraryCharacters.where((c) =>
          search.isEmpty ||
          c.name.toLowerCase().contains(search) ||
          c.description.toLowerCase().contains(search) ||
          c.tags.any((t) => t.toLowerCase().contains(search)));
      return StudioToolResult.json({
        'characters': [
          for (final c in matches.take(80))
            {'id': c.id, 'name': c.displayName, 'about': _preview(c.blurb, 140)},
        ],
      });
    }
    if (kind == 'lorebooks') {
      final matches = ctx.services.libraryLorebooks
          .where((b) => search.isEmpty || b.matches(search));
      return StudioToolResult.json({
        'lorebooks': [
          for (final b in matches.take(80)) describeLorebook(b, entries: false),
        ],
      });
    }
    throw StudioToolError('"kind" is characters or lorebooks.');
  },
);

final StudioTool readLibraryTool = StudioTool(
  const ToolSpec(
    name: 'read_library_item',
    description: 'Reads one library character or lorebook in full — to borrow '
        'its style, or to check what already exists. Read-only.',
    parameters: {
      'type': 'object',
      'properties': {
        'kind': {
          'type': 'string',
          'enum': ['character', 'lorebook'],
        },
        'id': _string,
      },
      'required': ['kind', 'id'],
    },
  ),
  (ctx, args) async {
    final kind = _str(args, 'kind', required: true);
    final id = _str(args, 'id', required: true);
    if (kind == 'character') {
      final c = ctx.services.libraryCharacters.where((c) => c.id == id).firstOrNull;
      if (c == null) throw StudioToolError('No library character "$id".');
      return StudioToolResult.json(describeCharacter(c, ctx.services));
    }
    if (kind == 'lorebook') {
      final b = ctx.services.libraryLorebooks.where((b) => b.id == id).firstOrNull;
      if (b == null) throw StudioToolError('No library lorebook "$id".');
      return StudioToolResult.json(describeLorebook(b));
    }
    throw StudioToolError('"kind" is character or lorebook.');
  },
);

final StudioTool attachLibraryLorebookTool = StudioTool(
  const ToolSpec(
    name: 'attach_library_lorebook',
    description: 'Brings a library lorebook into the draft and attaches it to '
        'the character. Edits to it are saved back over the library copy when '
        'the draft is applied.',
    parameters: {
      'type': 'object',
      'properties': {'id': _string},
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    final id = _str(args, 'id', required: true);
    if (ctx.ws.lorebook(id) != null) {
      throw StudioToolError('That lorebook is already in the draft.');
    }
    final b = ctx.services.libraryLorebooks.where((b) => b.id == id).firstOrNull;
    if (b == null) throw StudioToolError('No library lorebook "$id".');
    ctx.edit('attach_library_lorebook', 'Attached lorebook "${b.displayName}"', (ws) {
      ws.lorebooks.add(b.copyWith());
      if (!ws.character.lorebookIds.contains(id)) ws.character.lorebookIds.add(id);
    });
    return StudioToolResult.json({'ok': true, 'lorebook_id': id});
  },
);

/// The kinds of sub-agent the `task` tool can start, and what each is for.
const Map<String, String> kStudioAgentTypes = {
  'general': 'Any part of the build: every draft tool.',
  'writer': 'Character fields, greetings and scenarios.',
  'lore_writer': 'Lorebooks and background documents.',
  'critic': 'Reads and playtests the draft and reports problems, changing '
      'nothing.',
};

/// The old name for [kStudioAgentTypes], less `general`.
@Deprecated('Use kStudioAgentTypes')
Map<String, String> get kStudioHelpers => {
      for (final e in kStudioAgentTypes.entries)
        if (e.key != 'general') e.key: e.value,
    };

/// A sub-agent type as the Studio shows it: "Lore writer".
String studioAgentTypeLabel(String type) {
  final words = type.replaceAll('_', ' ').trim();
  if (words.isEmpty) return 'General';
  return words[0].toUpperCase() + words.substring(1);
}

final StudioTool taskTool = StudioTool(
  ToolSpec(
    name: 'task',
    description: 'Launch a sub-agent to handle one self-contained part of the '
        'build. It works on the same draft with its own tools and its own '
        'conversation, then returns a single report to you.\n\n'
        'Agent types: '
        '${kStudioAgentTypes.entries.map((e) => '${e.key} — ${e.value}').join(' ')} '
        'Plus any types the user defined, listed in your instructions.\n\n'
        'Usage:\n'
        '- Launch several sub-agents at once by making several task calls in '
        'one message; they run at the same time. When the user asks for a '
        'number of sub-agents, launch exactly that many.\n'
        '- The sub-agent has NOT seen this conversation. Write a detailed, '
        'self-contained prompt: what to build or check, the relevant facts '
        'about the character, whether to write to the draft or only review, '
        'and exactly what its report should contain.\n'
        '- Give each sub-agent its own part (disjoint ownership): tell it which '
        'fields, lorebook or entries are its to change, and that other agents '
        'are working on the same draft at the same time, so it must not undo '
        'or rewrite their edits.\n'
        '- Do not redo work you delegated; wait for the report, then check the '
        'result with get_draft.\n'
        '- The user never sees the report unless they open the sub-agent, so '
        'summarise what came back.\n'
        '- To send a finished sub-agent a follow-up, pass its task_id; it '
        'carries on with its conversation intact.\n'
        '- With background: true the call returns at once with the task_id and '
        'the sub-agent keeps working while you do other things; its report '
        'reaches you later as a note. Use wait_agents to wait for it and '
        'send_message to redirect it.',
    parameters: {
      'type': 'object',
      'properties': {
        'description': {
          'type': 'string',
          'description': 'A short (3-5 words) description of the task.',
        },
        'prompt': {
          'type': 'string',
          'description': 'The full task for the sub-agent.',
        },
        // Not an enum: the user can define types of their own, and the
        // schema is fixed when the app starts. The types in force are listed
        // in the agent's instructions and checked when the call is answered.
        'agent_type': {
          'type': 'string',
          'description': 'general (the default), writer, lore_writer, critic, '
              'or a type the user defined.',
        },
        'task_id': {
          'type': 'string',
          'description': 'Carry on the sub-agent with this id instead of '
              'starting a new one.',
        },
        'background': {
          'type': 'boolean',
          'description': 'Return at once and let it work while you carry on; '
              'its report arrives later as a note.',
        },
      },
      'required': ['description', 'prompt'],
    },
  ),
  (ctx, args) async {
    final type = (_optStr(args, 'agent_type') ?? 'general').trim();
    final problem = studioAgentTypeProblem(ctx.knowledge.config(), type);
    if (problem != null) throw StudioToolError(problem);
    final description = _str(args, 'description', required: true).trim();
    final prompt = _str(args, 'prompt', required: true).trim();
    if (prompt.isEmpty) throw StudioToolError('"prompt" cannot be empty.');
    final taskId = _optStr(args, 'task_id')?.trim();
    final background = _optBool(args, 'background') ?? false;
    final services = ctx.services;
    if (background && services is! StudioRuntime) {
      throw StudioToolError('Background sub-agents are not available here.');
    }
    final outcome = background
        ? await (services as StudioRuntime).startBackgroundTask(
            agentType: type,
            description: description.isEmpty ? 'Sub-task' : description,
            prompt: prompt,
            callId: ctx.call?.id ?? '',
            taskId: taskId == null || taskId.isEmpty ? null : taskId,
          )
        : await services.runTask(
            agentType: type,
            description: description.isEmpty ? 'Sub-task' : description,
            prompt: prompt,
            callId: ctx.call?.id ?? '',
            taskId: taskId == null || taskId.isEmpty ? null : taskId,
          );
    // Framed as data: this is the sub-agent's account, not an instruction.
    final result = StudioToolResult.json({
      'subagent': outcome.label,
      'task_id': outcome.taskId,
      'status': outcome.status,
      'report': outcome.report,
    });
    // A background start is not a failure: it is still running.
    return outcome.failed && outcome.status != 'running'
        ? StudioToolResult(result.text, isError: true)
        : result;
  },
);

final StudioTool todoWriteTool = StudioTool(
  const ToolSpec(
    name: 'todo_write',
    description: 'Writes your plan for this build as a checklist the user can '
        'see, replacing the previous one. Use it for any build of three or '
        'more steps: write the steps first, keep exactly one in_progress while '
        'you work on it, and mark each completed as soon as it is done — never '
        'before. Skip it for a single small change.',
    parameters: {
      'type': 'object',
      'properties': {
        'todos': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'content': {'type': 'string'},
              'status': {
                'type': 'string',
                'enum': ['pending', 'in_progress', 'completed'],
              },
            },
            'required': ['content', 'status'],
          },
        },
      },
      'required': ['todos'],
    },
  ),
  (ctx, args) async {
    final raw = args['todos'];
    if (raw is! List) {
      throw StudioToolError('"todos" must be a list of {content, status}.');
    }
    final todos = <StudioTodo>[];
    for (var i = 0; i < raw.length; i++) {
      final item = raw[i];
      if (item is! Map) {
        throw StudioToolError('Item $i must be an object {content, status}.');
      }
      final content = (item['content'] ?? '').toString().trim();
      if (content.isEmpty) throw StudioToolError('Item $i has no "content".');
      final status = StudioTodoStatus.fromWire(item['status']);
      if (status == null) {
        throw StudioToolError(
          'Item $i has status "${item['status']}"; use pending, in_progress '
          'or completed.',
        );
      }
      todos.add(StudioTodo(content: content, status: status));
    }
    final active =
        todos.where((t) => t.status == StudioTodoStatus.inProgress).length;
    if (active > 1) {
      throw StudioToolError(
        '$active items are in_progress; keep exactly one in_progress at a time.',
      );
    }
    ctx.todos
      ..clear()
      ..addAll(todos);
    ctx.session.updatedAt = DateTime.now();
    final done = todos.where((t) => t.status == StudioTodoStatus.completed).length;
    return StudioToolResult.json({'ok': true, 'done': done, 'total': todos.length});
  },
);

const List<String> _readTools = ['get_draft', 'read_document'];

/// Every tool, by name.
final Map<String, StudioTool> kStudioTools = {
  for (final t in [
    getDraftTool,
    setFieldsTool,
    editFieldTool,
    addGreetingTool,
    removeGreetingTool,
    upsertScenarioTool,
    deleteScenarioTool,
    createLorebookTool,
    updateLorebookTool,
    deleteLorebookTool,
    upsertLoreEntryTool,
    deleteLoreEntryTool,
    upsertDocumentTool,
    readDocumentTool,
    deleteDocumentTool,
    generateAvatarTool,
    playtestTool,
    listLibraryTool,
    readLibraryTool,
    attachLibraryLorebookTool,
    todoWriteTool,
    taskTool,
    ...kRuntimeTools,
    ...kKnowledgeTools,
    ...kSkillTools,
    ...kImageTools,
  ])
    t.name: t,
};

/// The tools an agent gets. The main agent ([agent] `studio`) has all of
/// them, less `task` when sub-agents are off. A sub-agent never gets `task`
/// (one level deep, like Claude Code and OpenCode) and gets the tools of its
/// type: `general` every draft tool, the others their own trade.
List<StudioTool> studioToolsFor(String agent, {bool subAgents = true}) {
  final names = switch (agent) {
    'writer' => [
        ..._readTools,
        'set_fields',
        'edit_field',
        'add_greeting',
        'remove_greeting',
        'upsert_scenario',
        'delete_scenario',
        'read_library_item',
        'todo_write',
      ],
    'lore_writer' => [
        ..._readTools,
        'create_lorebook',
        'update_lorebook',
        'upsert_lore_entry',
        'delete_lore_entry',
        'upsert_document',
        'delete_document',
        'list_library',
        'read_library_item',
        'todo_write',
      ],
    'critic' => [..._readTools, 'playtest', 'todo_write'],
    // Every draft tool, but none of the run's own: a sub-agent neither spawns
    // nor messages other agents (one level deep).
    'general' => [
        for (final name in kStudioTools.keys)
          if (name != 'task' && !kRuntimeToolNames.contains(name)) name,
      ],
    _ => [
        for (final name in kStudioTools.keys)
          if (subAgents || name != 'task') name,
      ],
  };
  // The runtime and knowledge tools: the main agent (and a general
  // sub-agent) has all of them; a typed sub-agent those its type is given.
  final extra = switch (agent) {
    'studio' || 'general' => const <String>[],
    // Skills are advice for any kind of work, so every typed sub-agent can
    // load them.
    _ => [
        ...?kRuntimeToolsFor[agent],
        ...?kKnowledgeToolsFor[agent],
        ...kSkillToolNames,
      ],
  };
  return [
    for (final n in names) kStudioTools[n]!,
    for (final n in extra)
      if (!names.contains(n) && kStudioTools[n] != null) kStudioTools[n]!,
  ];
}
