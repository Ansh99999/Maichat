import '../../models/agent_message.dart';
import '../../models/character.dart';
import '../../models/lorebook.dart';
import '../../models/studio.dart';
import '../../models/studio_revisions.dart';
import 'studio_tools.dart';

/// The agents' workbench: `count_tokens` (the app's own tokenizer over any
/// text or part of the draft), the session's notes — a writing area for
/// research and findings that is never applied — and the Playground's
/// playtests (`playtest`, `read_playtests`). Registered into [kStudioTools]
/// beside the draft tools.
final List<StudioTool> kWorkbenchTools = <StudioTool>[
  countTokensTool,
  readNotesTool,
  writeNotesTool,
  appendNotesTool,
  editNotesTool,
  playtestTool,
  readPlaytestsTool,
];

/// The notes tools.
const List<String> kNotesToolNames = [
  'read_notes',
  'write_notes',
  'append_notes',
  'edit_notes',
];

/// What every agent gets whatever its type: counting costs nothing, and the
/// notes are where a sub-agent leaves what it found — added to, never wiped.
const List<String> kWorkbenchAlways = [
  'count_tokens',
  'read_notes',
  'append_notes',
];

/// What a typed sub-agent gets beside [kWorkbenchAlways]: the writers may
/// reorganise the notes; a critic, which changes nothing, only adds to them
/// and reads the Playground. The main agent and a `general` sub-agent get
/// every tool anyway, and a type the user defined every notes tool.
const Map<String, List<String>> kWorkbenchToolsFor = <String, List<String>>{
  'writer': ['write_notes', 'edit_notes', 'read_playtests'],
  'lore_writer': ['write_notes', 'edit_notes'],
  'critic': ['read_playtests'],
  'custom': ['write_notes', 'edit_notes'],
};

/// What a [StudioServices] may also offer: the size of the prompt a chat with
/// a draft would send — the preset, persona, card and lore, assembled as a
/// real chat assembles it. Optional, like [StudioRuntime], so a fake need not.
abstract class StudioPromptSizer {
  /// Null when no chat provider is set up.
  ({int tokens, int context, List<(String, int)> sections})? promptSize({
    required Character character,
    required List<Lorebook> lorebooks,
    int greetingIndex = 0,
  });
}

// --- arguments ------------------------------------------------------------------

String _text(Map<String, dynamic> args, String key, {bool required = false}) {
  final value = args[key];
  if (value == null) {
    if (required) throw StudioToolError('"$key" is required.');
    return '';
  }
  if (value is String) return value;
  if (value is num || value is bool) return value.toString();
  throw StudioToolError('"$key" must be a string.');
}

int? _int(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is num) return value.toInt();
  final parsed = int.tryParse('$value'.trim());
  if (parsed == null) throw StudioToolError('"$key" must be a whole number.');
  return parsed;
}

List<String>? _list(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return null;
  if (value is List) {
    return [
      for (final v in value)
        if (v != null && '$v'.trim().isNotEmpty) '$v'.trim(),
    ];
  }
  if (value is String) {
    return value
        .split(',')
        .map((v) => v.trim())
        .where((v) => v.isNotEmpty)
        .toList();
  }
  throw StudioToolError('"$key" must be a list of strings.');
}

String _preview(String text, [int max = 60]) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}

// --- count_tokens -------------------------------------------------------------

/// The card's text fields, as `count_tokens` names them.
final Map<String, String Function(Character c)> _cardFields = {
  'name': (c) => c.name,
  'description': (c) => c.description,
  'personality': (c) => c.personality,
  'scenario': (c) => c.scenario,
  'first_message': (c) => c.firstMes,
  'example_dialogue': (c) => c.mesExample,
  'system_prompt': (c) => c.systemPrompt,
  'post_history_instructions': (c) => c.postHistoryInstructions,
  'creator_notes': (c) => c.creatorNotes,
};

/// The fields every chat with the card pays for on every message.
const List<String> _permanentFields = [
  'description',
  'personality',
  'scenario',
  'example_dialogue',
  'system_prompt',
  'post_history_instructions',
];

const List<String> _partNames = [
  'card',
  ..._permanentFieldsAndMore,
  'alternate_greetings',
  'greetings',
  'scenarios',
  'lorebooks',
  'lorebook:<id>',
  'documents',
  'notes',
  'prompt',
];

const List<String> _permanentFieldsAndMore = [
  'name',
  'description',
  'personality',
  'scenario',
  'first_message',
  'example_dialogue',
  'system_prompt',
  'post_history_instructions',
  'creator_notes',
];

final StudioTool countTokensTool = StudioTool(
  const ToolSpec(
    name: 'count_tokens',
    description: 'Counts tokens with the app\'s own tokenizer (the BPE the '
        'chat budgets with): any text you pass, and/or named parts of the '
        'draft. Parts: card (the permanent fields every message pays for, '
        'each and in total), a field by name (description, personality, '
        'scenario, first_message, example_dialogue, system_prompt, '
        'post_history_instructions, creator_notes, name), greetings / '
        'alternate_greetings (each), scenarios (each of the character\'s own), '
        'lorebooks (each book and entry), lorebook:<id>, documents, notes, and '
        'prompt — the whole first request of a chat with the draft as the '
        'user\'s preset assembles it, against the context it allows. With '
        'nothing passed it reports card, greetings, lorebooks and prompt. Use '
        'it to check a budget before and after trimming.',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': 'Any text to count — a passage you are about to write.',
        },
        'parts': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'Parts of the draft to count (see the description).',
        },
      },
    },
  ),
  (ctx, args) async {
    final text = _text(args, 'text');
    final asked = _list(args, 'parts');
    final parts = asked ??
        (text.isEmpty
            ? const ['card', 'greetings', 'lorebooks', 'prompt']
            : const <String>[]);
    final count = ctx.services.countTokens;
    final c = ctx.character;
    final out = <String, dynamic>{};
    final counts = <String, int>{};
    final unknown = <String>[];
    if (text.isNotEmpty) out['text_tokens'] = count(text);

    void field(String key) {
      final value = _cardFields[key]!(c);
      counts[key] = value.trim().isEmpty ? 0 : count(value);
    }

    void book(Lorebook b) {
      var total = 0;
      for (final e in b.entries) {
        final n = count(e.content);
        total += n;
        counts['lorebook:${b.id}:entry:${e.uid}'
            '${e.displayName.isEmpty ? '' : ' (${_preview(e.displayName, 30)})'}'
            '${e.constant ? ' [constant]' : ''}'] = n;
      }
      counts['lorebook:${b.id} (${b.displayName}) total'] = total;
    }

    for (final raw in parts) {
      final part = raw.trim();
      if (part == 'card') {
        var total = 0;
        for (final key in _permanentFields) {
          field(key);
          total += counts[key]!;
        }
        out['permanent_tokens'] = count(
          [for (final key in _permanentFields) _cardFields[key]!(c)].join('\n'),
        );
        out['permanent_fields_sum'] = total;
      } else if (_cardFields.containsKey(part)) {
        field(part);
      } else if (part == 'greetings' || part == 'alternate_greetings') {
        if (part == 'greetings') field('first_message');
        for (var i = 0; i < c.alternateGreetings.length; i++) {
          counts['alternate_greetings[$i]'] = count(c.alternateGreetings[i]);
        }
      } else if (part == 'scenarios') {
        for (final s in c.scenarios) {
          counts['scenario:${s.id} (${s.displayName})'] = count(s.text);
        }
      } else if (part == 'lorebooks') {
        for (final b in ctx.ws.lorebooks) {
          book(b);
        }
      } else if (part.startsWith('lorebook:')) {
        final b = ctx.ws.lorebook(part.substring('lorebook:'.length));
        if (b == null) {
          unknown.add(part);
        } else {
          book(b);
        }
      } else if (part == 'documents') {
        for (final d in ctx.ws.documents) {
          counts['document:${d.id} (${d.name})'] = count(d.text);
        }
      } else if (part == 'notes') {
        counts['notes'] = ctx.ws.notes.trim().isEmpty ? 0 : count(ctx.ws.notes);
      } else if (part == 'prompt') {
        final services = ctx.services;
        final size = services is StudioPromptSizer
            ? (services as StudioPromptSizer).promptSize(
                character: c.clone(),
                lorebooks: [for (final b in ctx.ws.lorebooks) b.copyWith()],
              )
            : null;
        out['prompt'] = size == null
            ? 'Not available: no chat provider is set up, so there is no '
                'preset to assemble a prompt with.'
            : {
                'tokens': size.tokens,
                'context': size.context,
                'share_of_context': size.context <= 0
                    ? null
                    : '${(size.tokens * 100 / size.context).toStringAsFixed(1)}%',
                'sections': {
                  for (final s in size.sections)
                    if (s.$2 > 0) s.$1: s.$2,
                },
                'note': 'The first request of a chat with the draft: preset, '
                    'persona, card, constant and triggered lore, greeting and '
                    'one short user line.',
              };
      } else {
        unknown.add(part);
      }
    }
    if (counts.isNotEmpty) {
      out['parts'] = counts;
      out['parts_total'] = counts.entries
          .where((e) => !e.key.endsWith(' total'))
          .fold<int>(0, (n, e) => n + e.value);
    }
    if (unknown.isNotEmpty) {
      out['unknown_parts'] = unknown;
      out['known_parts'] = _partNames;
    }
    if (out.isEmpty) {
      throw StudioToolError('Pass "text" or "parts" to count.');
    }
    return StudioToolResult.json(out);
  },
);

// --- notes --------------------------------------------------------------------

/// The headings in [notes], in order — what `read_notes` lists and
/// `append_notes` files under.
List<String> notesHeadings(String notes) => [
      for (final line in notes.split('\n'))
        if (RegExp(r'^#{1,6}\s+\S').hasMatch(line))
          line.replaceFirst(RegExp(r'^#{1,6}\s+'), '').trim(),
    ];

/// [notes] with [text] added under the heading [section] — at the end of that
/// section (before the next heading of the same or a higher level), or as a
/// new `##` section at the end when there is none. With no [section], at the
/// end.
String appendToNotes(String notes, String text, {String section = ''}) {
  final body = text.trim();
  final title = section.trim();
  String join(String a, String b) {
    final head = a.trimRight();
    return head.isEmpty ? b : '$head\n\n$b';
  }

  if (title.isEmpty) return '${join(notes, body)}\n';
  final lines = notes.split('\n');
  final heading = RegExp(r'^(#{1,6})\s+(.*\S)\s*$');
  var at = -1;
  var level = 0;
  for (var i = 0; i < lines.length; i++) {
    final m = heading.firstMatch(lines[i]);
    if (m != null && m.group(2)!.toLowerCase() == title.toLowerCase()) {
      at = i;
      level = m.group(1)!.length;
      break;
    }
  }
  if (at == -1) return '${join(notes, '## $title\n\n$body')}\n';
  var end = lines.length;
  for (var i = at + 1; i < lines.length; i++) {
    final m = heading.firstMatch(lines[i]);
    if (m != null && m.group(1)!.length <= level) {
      end = i;
      break;
    }
  }
  final before = lines.sublist(0, end).join('\n');
  final after = lines.sublist(end).join('\n');
  final merged = join(before, body);
  return after.trim().isEmpty ? '$merged\n' : '$merged\n\n$after';
}

final StudioTool readNotesTool = StudioTool(
  const ToolSpec(
    name: 'read_notes',
    description: 'Reads the session\'s notes in full: the writing area where '
        'you, your sub-agents and the user keep research, findings, '
        'decisions and open questions. The notes are never part of the card.',
    parameters: {'type': 'object', 'properties': {}},
  ),
  (ctx, args) async {
    ctx.markSeen(['notes']);
    final notes = ctx.ws.notes;
    return StudioToolResult.json({
      'notes': notes,
      'tokens': notes.trim().isEmpty ? 0 : ctx.services.countTokens(notes),
      'sections': notesHeadings(notes),
    });
  },
);

final StudioTool appendNotesTool = StudioTool(
  const ToolSpec(
    name: 'append_notes',
    description: 'Adds to the session\'s notes without touching what is there '
        '— the way to record research (with its sources), findings and '
        'decisions as you go. Pass section to file it under that heading '
        '(made when missing): "Research", "Voice", "Open questions"… Markdown. '
        'Safe to call while other agents write notes too.',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {'type': 'string'},
        'section': {
          'type': 'string',
          'description': 'The heading to add it under.',
        },
      },
      'required': ['text'],
    },
  ),
  (ctx, args) async {
    final text = _text(args, 'text', required: true).trim();
    if (text.isEmpty) throw StudioToolError('"text" cannot be empty.');
    final section = _text(args, 'section').trim();
    ctx.edit(
      'append_notes',
      section.isEmpty ? 'Added to the notes' : 'Added to the notes: $section',
      (ws) => ws.notes = appendToNotes(ws.notes, text, section: section),
    );
    return StudioToolResult.json({
      'ok': true,
      'tokens': ctx.services.countTokens(ctx.ws.notes),
      'sections': notesHeadings(ctx.ws.notes),
    });
  },
);

final StudioTool writeNotesTool = StudioTool(
  const ToolSpec(
    name: 'write_notes',
    description: 'Replaces the session\'s notes with new text — to reorganise '
        'them. To add something, append_notes is safer; for a small change, '
        'edit_notes. Read them first.',
    parameters: {
      'type': 'object',
      'properties': {'text': {'type': 'string'}},
      'required': ['text'],
    },
  ),
  (ctx, args) async {
    final text = _text(args, 'text', required: true);
    ctx.ensureFresh(['notes'], reread: 'read_notes');
    ctx.edit('write_notes', 'Rewrote the notes', (ws) => ws.notes = text.trim());
    return StudioToolResult.json({
      'ok': true,
      'tokens': ctx.services.countTokens(ctx.ws.notes),
    });
  },
);

final StudioTool editNotesTool = StudioTool(
  const ToolSpec(
    name: 'edit_notes',
    description: 'Replaces an exact passage of the session\'s notes, leaving '
        'the rest untouched. find must match exactly and only once (unless '
        'replace_all). An empty replace deletes the passage.',
    parameters: {
      'type': 'object',
      'properties': {
        'find': {'type': 'string'},
        'replace': {'type': 'string'},
        'replace_all': {'type': 'boolean'},
      },
      'required': ['find', 'replace'],
    },
  ),
  (ctx, args) async {
    final find = _text(args, 'find', required: true);
    final replace = _text(args, 'replace');
    final all = args['replace_all'] == true || args['replace_all'] == 'true';
    if (find.isEmpty) throw StudioToolError('"find" cannot be empty.');
    ctx.ensureFresh(['notes'], reread: 'read_notes');
    final current = ctx.ws.notes;
    final hits = find.allMatches(current).length;
    if (hits == 0) {
      throw StudioToolError(
        'That passage is not in the notes. Read them again with read_notes; '
        'find must match exactly, whitespace included.',
      );
    }
    if (hits > 1 && !all) {
      throw StudioToolError(
        'That passage appears $hits times in the notes. Include more '
        'surrounding text, or pass replace_all.',
      );
    }
    final next =
        all ? current.replaceAll(find, replace) : current.replaceFirst(find, replace);
    ctx.edit('edit_notes', 'Edited the notes', (ws) => ws.notes = next);
    return StudioToolResult.json({'ok': true, 'replaced': all ? hits : 1});
  },
);

// --- playtests ----------------------------------------------------------------

/// How many lines one `playtest` call may send.
const int kPlaytestMaxMessages = 6;

final StudioTool playtestTool = StudioTool(
  const ToolSpec(
    name: 'playtest',
    description: 'Chats with the draft as a user would, through the real chat '
        'prompt (the user\'s preset, persona and model, the draft\'s '
        'lorebooks), and returns what the character said. Each message is '
        'sent in turn, after the chosen greeting. Use it to hear the voice, '
        'check that lore triggers, and catch the card breaking character.\n\n'
        'Every playtest is kept in the Playground, where the user can read '
        'it. To play a part adaptively — reacting to what the character '
        'says — send one or two lines, read the replies, then continue the '
        'same chat by passing its playtest_id. Say who you are playing in '
        'persona, and give a scenario to test a situation the card\'s own '
        'scenario does not cover.',
    parameters: {
      'type': 'object',
      'properties': {
        'messages': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'What the user says, one entry per turn (at most '
              '$kPlaytestMaxMessages).',
        },
        'greeting_index': {
          'type': 'integer',
          'description': '0 is the first message, 1 the first alternate. '
              'For a new playtest only.',
        },
        'playtest_id': {
          'type': 'string',
          'description': 'Carry on this playtest, with everything said so far.',
        },
        'title': {
          'type': 'string',
          'description': 'A few words on what this playtest checks.',
        },
        'persona': {
          'type': 'string',
          'description': 'Who you are playing, e.g. "a wary traveller who '
              'distrusts magic". Recorded with the playtest.',
        },
        'scenario': {
          'type': 'string',
          'description': 'A situation for this playtest only, replacing the '
              'card\'s scenario. For a new playtest only.',
        },
      },
      'required': ['messages'],
    },
  ),
  (ctx, args) async {
    final turns = _list(args, 'messages') ?? const <String>[];
    if (turns.isEmpty) throw StudioToolError('Pass at least one message.');
    if (turns.length > kPlaytestMaxMessages) {
      throw StudioToolError(
        'At most $kPlaytestMaxMessages messages per playtest call. To go on, '
        'pass the playtest_id this call returns.',
      );
    }
    final c = ctx.character;
    if (c.name.trim().isEmpty) {
      throw StudioToolError('Give the character a name first.');
    }
    final id = _text(args, 'playtest_id').trim();
    final persona = _text(args, 'persona').trim();
    final title = _text(args, 'title').trim();
    StudioPlaytest test;
    var fresh = false;
    if (id.isNotEmpty) {
      final found = ctx.session.playtest(id);
      if (found == null) {
        throw StudioToolError(
          'No playtest "$id". Leave playtest_id out to start one; '
          'read_playtests lists them.',
        );
      }
      if (found.byUser) {
        throw StudioToolError(
          'That is the user\'s own Playground chat; read it with '
          'read_playtests, and start a playtest of your own to test further.',
        );
      }
      test = found;
      if (persona.isNotEmpty) test.persona = persona;
      if (title.isNotEmpty) test.title = title;
    } else {
      final greetings = c.greetings;
      final index = (_int(args, 'greeting_index') ?? 0)
          .clamp(0, greetings.isEmpty ? 0 : greetings.length - 1);
      test = StudioPlaytest(
        id: '${DateTime.now().microsecondsSinceEpoch}',
        by: editorForAgent(ctx.agent),
        title: title.isEmpty ? _preview(turns.first, 48) : title,
        persona: persona,
        scenario: _text(args, 'scenario').trim(),
        greetingIndex: index,
        turns: [
          if (greetings.isNotEmpty)
            StudioPlaytestTurn(user: false, text: greetings[index]),
        ],
      );
      fresh = true;
    }
    final earlier = test.sendable;
    List<String> replies;
    try {
      replies = await ctx.services.playtest(
        character: c.clone(),
        lorebooks: [for (final b in ctx.ws.lorebooks) b.copyWith()],
        userTurns: turns,
        greetingIndex: test.greetingIndex,
        earlier: earlier,
        scenario: test.scenario,
      );
    } catch (e) {
      test.turns
        ..add(StudioPlaytestTurn(user: true, text: turns.first))
        ..add(StudioPlaytestTurn(user: false, text: '$e', error: true));
      test.updatedAt = DateTime.now();
      if (fresh) ctx.session.addPlaytest(test);
      throw StudioToolError('The playtest failed: $e');
    }
    for (var i = 0; i < turns.length; i++) {
      test.turns
        ..add(StudioPlaytestTurn(user: true, text: turns[i]))
        ..add(StudioPlaytestTurn(
          user: false,
          text: i < replies.length ? replies[i] : '',
        ));
    }
    test.updatedAt = DateTime.now();
    if (fresh) {
      ctx.session.addPlaytest(test);
    } else {
      ctx.session.updatedAt = DateTime.now();
    }
    return StudioToolResult.json({
      'playtest_id': test.id,
      'transcript': [
        for (var i = 0; i < turns.length; i++) ...[
          {'user': turns[i]},
          {c.displayName: i < replies.length ? replies[i] : ''},
        ],
      ],
      'turns_so_far': test.turns.where((t) => t.user).length,
    });
  },
);

final StudioTool readPlaytestsTool = StudioTool(
  const ToolSpec(
    name: 'read_playtests',
    description: 'Reads the Playground: the playtests run on this draft — the '
        'user\'s own chats with it and the agents\' playtests. Without '
        'playtest_id it lists them, newest first; with one it returns that '
        'chat in full. What the user said there is the best evidence of how '
        'the card plays for them.',
    parameters: {
      'type': 'object',
      'properties': {
        'playtest_id': {'type': 'string'},
      },
    },
  ),
  (ctx, args) async {
    final id = _text(args, 'playtest_id').trim();
    final name = ctx.character.displayName;
    if (id.isEmpty) {
      return StudioToolResult.json({
        'playtests': [
          for (final p in ctx.session.playtests.reversed)
            {
              'playtest_id': p.id,
              'title': p.displayTitle,
              'by': p.byUser ? 'the user' : p.by,
              if (p.persona.isNotEmpty) 'persona': p.persona,
              if (p.scenario.isNotEmpty) 'scenario': _preview(p.scenario, 120),
              'user_turns': p.turns.where((t) => t.user).length,
              'updated': p.updatedAt.toIso8601String(),
            },
        ],
      });
    }
    final p = ctx.session.playtest(id);
    if (p == null) throw StudioToolError('No playtest "$id".');
    return StudioToolResult.json({
      'playtest_id': p.id,
      'title': p.displayTitle,
      'by': p.byUser ? 'the user' : p.by,
      if (p.persona.isNotEmpty) 'persona': p.persona,
      if (p.scenario.isNotEmpty) 'scenario': p.scenario,
      'greeting_index': p.greetingIndex,
      'transcript': [
        for (final t in p.turns)
          if (t.error)
            {'error': t.text}
          else
            {(t.user ? 'user' : name): t.text},
      ],
    });
  },
);
