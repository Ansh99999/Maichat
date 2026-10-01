import 'dart:convert';
import 'dart:typed_data';

import '../../models/agent_message.dart';
import '../../models/character.dart';
import '../../models/character_scenario.dart';
import '../../models/discover.dart';
import '../../models/lorebook.dart';
import '../../models/scenario.dart';
import '../../models/studio.dart';
import '../../models/studio_revisions.dart';
import '../avatar_store.dart';
import '../discover/discover_sources.dart';
import 'image_tools.dart';
import 'studio_discover.dart';
import 'studio_images.dart';
import 'studio_tools.dart';
import 'workbench_tools.dart';

/// Bringing things into the draft: from the user's own library (a character
/// to start from or borrow parts of, a scenario, a lorebook's entries) and
/// from Discover, the in-app catalogue browser (search, read a listing in
/// full, import one).
///
/// Every change goes through [StudioToolContext.edit], so it is a row in
/// Changes, can be rewound, and is guarded against overwriting what another
/// agent changed since this one read it. Pictures are always filed into the
/// gallery as files (with where they came from) — never kept as base64 or as
/// a bare link. Registered into [kStudioTools].
final List<StudioTool> kLibraryTools = <StudioTool>[
  loadLibraryCharacterTool,
  useLibraryScenarioTool,
  copyLoreEntriesTool,
  discoverSearchTool,
  discoverReadTool,
  discoverImportTool,
];

/// What reads, and what changes the draft — the custom agent types' groups.
const List<String> kLibraryReadToolNames = ['discover_search', 'discover_read'];
const List<String> kLibraryImportToolNames = [
  'load_library_character',
  'use_library_scenario',
  'copy_lore_entries',
  'discover_import',
];

/// The library's scenarios, for an app that has them. Optional, like
/// [StudioPictureServices]: a host without it simply has none.
abstract class StudioLibraryServices {
  List<Scenario> get libraryScenarios;
}

/// Discover, for an app that browses it.
abstract class StudioDiscoverServices {
  StudioDiscover get discover;

  /// Discover's adult-content switch as the user left it. Agents cannot turn
  /// it on.
  bool get discoverNsfw;

  /// The catalogue Discover was last left on, or empty.
  String get discoverSourceId;
}

/// The library's scenarios, or none.
List<Scenario> libraryScenariosOf(StudioServices services) =>
    services is StudioLibraryServices
        ? (services as StudioLibraryServices).libraryScenarios
        : const <Scenario>[];

// --- arguments ------------------------------------------------------------------

String _arg(Map<String, dynamic> args, String key, {bool required = false}) {
  final value = args[key];
  if (value == null || (value is String && value.trim().isEmpty)) {
    if (required) throw StudioToolError('"$key" is required.');
    return '';
  }
  if (value is String) return value.trim();
  if (value is num || value is bool) return '$value';
  throw StudioToolError('"$key" must be a string.');
}

bool _flag(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return false;
  if (value is bool) return value;
  if (value is String) return value.toLowerCase() == 'true';
  throw StudioToolError('"$key" must be true or false.');
}

List<String> _list(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return const <String>[];
  if (value is List) {
    return [
      for (final v in value)
        if (v != null && '$v'.trim().isNotEmpty) '$v'.trim(),
    ];
  }
  if (value is String) {
    return [
      for (final v in value.split(','))
        if (v.trim().isNotEmpty) v.trim(),
    ];
  }
  throw StudioToolError('"$key" must be a list of strings.');
}

List<int> _ints(Map<String, dynamic> args, String key) {
  final value = args[key];
  if (value == null) return const <int>[];
  if (value is! List) throw StudioToolError('"$key" must be a list of numbers.');
  return [
    for (final v in value)
      if (v is num) v.toInt() else if (int.tryParse('$v') != null) int.parse('$v'),
  ];
}

int _serial = 0;
String _newId() => '${DateTime.now().microsecondsSinceEpoch}${_serial++ % 10}';

String _clip(String text, int max) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}

const _string = {'type': 'string'};
const _stringList = {
  'type': 'array',
  'items': {'type': 'string'},
};

// --- shared draft moves ---------------------------------------------------------

/// The character's own parts — what a wholesale replace overwrites, and so
/// what must not have changed since this agent read it.
List<String> _characterParts(StudioWorkspace ws) => [
      ...partsWithPrefix(ws, 'field:'),
      ...partsWithPrefix(ws, 'greeting:'),
      ...partsWithPrefix(ws, 'scenario:'),
      'tags',
      'avatar',
    ];

List<String> _bookParts(StudioWorkspace ws) => [
      ...partsWithPrefix(ws, 'book:'),
      ...partsWithPrefix(ws, 'entry:'),
    ];

/// [book] under a new id: a copy that can be changed without touching the
/// one it came from.
Lorebook _freshBook(Lorebook book) =>
    Lorebook.fromJson({...book.toJson(), 'id': _newId()});

/// Makes [character] the draft's character with [books] as its lorebooks.
/// With [keepLorebooks] the books the draft already had stay, attached to the
/// new character too.
void _replaceCharacter(
  StudioWorkspace ws,
  Character character,
  List<Lorebook> books, {
  required bool keepLorebooks,
}) {
  final kept = keepLorebooks ? List<Lorebook>.of(ws.lorebooks) : <Lorebook>[];
  ws.character = character;
  ws.lorebooks
    ..clear()
    ..addAll(kept);
  for (final b in kept) {
    if (!character.lorebookIds.contains(b.id)) character.lorebookIds.add(b.id);
  }
  for (final b in books) {
    if (ws.lorebook(b.id) != null) continue;
    ws.lorebooks.add(b);
    if (!character.lorebookIds.contains(b.id)) character.lorebookIds.add(b.id);
  }
}

// --- the library ------------------------------------------------------------------

/// The parts `load_library_character` can take in merge mode.
const List<String> _extraParts = [
  'alternate_greetings',
  'tags',
  'scenarios',
  'lorebooks',
  'avatar',
];

final StudioTool loadLibraryCharacterTool = StudioTool(
  ToolSpec(
    name: 'load_library_character',
    description: 'Brings a character from the user\'s library into the draft '
        '(ids from list_library). mode "replace" makes it the draft\'s '
        'character, with its lorebooks — to build on an existing card. By '
        'default the draft becomes a new character derived from it; '
        'edit_original: true edits the library character itself, so applying '
        'the draft updates it in place. mode "merge" copies only the parts '
        'you name into the current draft (fields replace the draft\'s; '
        'greetings, tags and scenarios are added; lorebooks are attached). '
        'Read it first with read_library_item. A replace can be rewound in '
        'Changes; documents and notes are kept either way.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': _string,
        'mode': {
          'type': 'string',
          'enum': ['replace', 'merge'],
        },
        'edit_original': {
          'type': 'boolean',
          'description': 'replace only: keep the library character\'s id, so '
              'applying overwrites it. Only when the user asked to edit that '
              'character.',
        },
        'keep_lorebooks': {
          'type': 'boolean',
          'description': 'replace only: keep the lorebooks the draft already '
              'has, attached to the loaded character too.',
        },
        'parts': {
          ..._stringList,
          'description': 'merge only: which parts to take — any of '
              '${[...kStudioTextFields.keys, ..._extraParts].join(', ')}.',
        },
      },
      'required': ['id', 'mode'],
    },
  ),
  (ctx, args) async {
    final id = _arg(args, 'id', required: true);
    final mode = _arg(args, 'mode', required: true);
    final source =
        ctx.services.libraryCharacters.where((c) => c.id == id).firstOrNull;
    if (source == null) {
      throw StudioToolError('No library character "$id". list_library '
          'with kind "characters" shows their ids.');
    }
    final books = [
      for (final bookId in source.lorebookIds)
        ?ctx.services.libraryLorebooks.where((b) => b.id == bookId).firstOrNull,
    ];
    if (mode == 'replace') {
      final original = _flag(args, 'edit_original');
      final keep = _flag(args, 'keep_lorebooks');
      ctx.ensureFresh([..._characterParts(ctx.ws), if (!keep) ..._bookParts(ctx.ws)]);
      // A derived character gets copies of its books too, or editing the
      // draft's would rewrite the original's on apply.
      final copies = [
        for (final b in books) original ? b.copyWith() : _freshBook(b),
      ];
      final character = source.copyWith(id: original ? source.id : _newId());
      character.lorebookIds = [for (final b in copies) b.id];
      ctx.edit(
        'load_library_character',
        original
            ? 'Opened "${source.displayName}" from the library to edit'
            : 'Started from "${source.displayName}" in the library',
        (ws) => _replaceCharacter(ws, character, copies, keepLorebooks: keep),
      );
      return StudioToolResult.json({
        'ok': true,
        'mode': 'replace',
        'name': character.displayName,
        'applies_as': original
            ? 'an update to "${source.displayName}" in the library'
            : 'a new character (the library one is untouched)',
        'lorebooks': [
          for (final b in copies) {'id': b.id, 'name': b.displayName},
        ],
        'alternate_greetings': character.alternateGreetings.length,
        'next': 'Call get_draft before editing it.',
      });
    }
    if (mode != 'merge') {
      throw StudioToolError('"mode" is "replace" or "merge".');
    }
    final parts = _list(args, 'parts');
    if (parts.isEmpty) {
      throw StudioToolError('merge needs "parts": which parts to take, e.g. '
          '["description", "alternate_greetings"].');
    }
    final unknown = [
      for (final p in parts)
        if (!kStudioTextFields.containsKey(p) && !_extraParts.contains(p)) p,
    ];
    if (unknown.isNotEmpty) {
      throw StudioToolError('Unknown part ${unknown.map((p) => '"$p"').join(', ')}. '
          'Parts are ${[...kStudioTextFields.keys, ..._extraParts].join(', ')}.');
    }
    ctx.ensureFresh([
      for (final p in parts)
        if (kStudioTextFields.containsKey(p)) 'field:$p',
      if (parts.contains('tags')) 'tags',
      if (parts.contains('avatar')) 'avatar',
    ]);
    final taken = <String>[];
    ctx.edit(
      'load_library_character',
      'Took ${parts.map((p) => p.replaceAll('_', ' ')).join(', ')} from '
          '"${source.displayName}"',
      (ws) {
        final c = ws.character;
        for (final p in parts) {
          final field = kStudioTextFields[p];
          if (field != null) {
            field.$2(c, field.$1(source));
            taken.add(p);
            continue;
          }
          switch (p) {
            case 'alternate_greetings':
              for (final g in source.alternateGreetings) {
                if (!c.alternateGreetings.contains(g)) c.alternateGreetings.add(g);
              }
              taken.add('${source.alternateGreetings.length} greetings');
            case 'tags':
              for (final t in source.tags) {
                if (!c.tags.contains(t)) c.tags.add(t);
              }
              taken.add('tags');
            case 'scenarios':
              for (final s in source.scenarios) {
                c.scenarios.add(CharacterScenario(
                  id: _newId(),
                  name: s.name,
                  text: s.text,
                  scenarioId: s.scenarioId,
                  greetings: List<int>.of(s.greetings),
                ));
              }
              taken.add('${source.scenarios.length} scenarios');
            case 'lorebooks':
              // Attached as attach_library_lorebook does: the same book, saved
              // back over the library copy when the draft is applied.
              for (final b in books) {
                if (ws.lorebook(b.id) == null) ws.lorebooks.add(b.copyWith());
                if (!c.lorebookIds.contains(b.id)) c.lorebookIds.add(b.id);
              }
              taken.add('${books.length} lorebooks');
            case 'avatar':
              if (source.hasAvatar) {
                if (c.hasAvatar &&
                    c.avatar != source.avatar &&
                    !c.avatars.contains(c.avatar)) {
                  c.avatars.add(c.avatar);
                }
                c.avatar = source.avatar;
              }
              for (final a in source.avatars) {
                if (a != c.avatar && !c.avatars.contains(a)) c.avatars.add(a);
              }
              taken.add('pictures');
          }
        }
      },
    );
    return StudioToolResult.json({'ok': true, 'mode': 'merge', 'took': taken});
  },
);

final StudioTool useLibraryScenarioTool = StudioTool(
  const ToolSpec(
    name: 'use_library_scenario',
    description: 'Brings a scenario from the user\'s library into the draft '
        '(ids from list_library with kind "scenarios"). as "scenario" (the '
        'default) adds it as one of the character\'s own scenarios, for the '
        'greetings you name (all when left out); as "main" writes it into the '
        'scenario field — replacing it, or after it when the library scenario '
        'is set to add to the card\'s own.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': _string,
        'as': {
          'type': 'string',
          'enum': ['scenario', 'main'],
        },
        'greetings': {
          'type': 'array',
          'items': {'type': 'integer'},
          'description': 'as "scenario": greeting indexes it belongs to — 0 is '
              'the first message, 1 the first alternate.',
        },
      },
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    final id = _arg(args, 'id', required: true);
    final as = _arg(args, 'as').isEmpty ? 'scenario' : _arg(args, 'as');
    final scenario =
        libraryScenariosOf(ctx.services).where((s) => s.id == id).firstOrNull;
    if (scenario == null) {
      throw StudioToolError('No library scenario "$id". list_library with '
          'kind "scenarios" shows their ids.');
    }
    if (!scenario.isUsable) {
      throw StudioToolError('"${scenario.displayName}" has no text.');
    }
    if (as == 'main') {
      ctx.ensureFresh(['field:scenario']);
      ctx.edit('use_library_scenario',
          'Set the scenario from "${scenario.displayName}"', (ws) {
        ws.character.scenario = scenario.appliedOver(ws.character.scenario);
      });
      return StudioToolResult.json({
        'ok': true,
        'as': 'main',
        'replaced': scenario.overwriteCharacterScenario,
      });
    }
    if (as != 'scenario') throw StudioToolError('"as" is "scenario" or "main".');
    final newId = _newId();
    ctx.edit('use_library_scenario',
        'Added scenario "${scenario.displayName}" from the library', (ws) {
      ws.character.scenarios.add(CharacterScenario(
        id: newId,
        name: scenario.displayName,
        text: scenario.text,
        scenarioId: scenario.id,
        greetings: _ints(args, 'greetings'),
      ));
    });
    return StudioToolResult.json({'ok': true, 'as': 'scenario', 'id': newId});
  },
);

final StudioTool copyLoreEntriesTool = StudioTool(
  const ToolSpec(
    name: 'copy_lore_entries',
    description: 'Copies entries from a library lorebook into one of the '
        'draft\'s lorebooks, as new entries — the library book is untouched. '
        'Name them by uid (read_library_item shows them), or by a word in '
        'their name, keys or text with search; with neither, every entry is '
        'copied.',
    parameters: {
      'type': 'object',
      'properties': {
        'from_id': {
          ..._string,
          'description': 'The library lorebook to copy from.',
        },
        'lorebook_id': {
          ..._string,
          'description': 'The draft lorebook to copy into.',
        },
        'uids': {
          'type': 'array',
          'items': {'type': 'integer'},
        },
        'search': _string,
      },
      'required': ['from_id', 'lorebook_id'],
    },
  ),
  (ctx, args) async {
    final fromId = _arg(args, 'from_id', required: true);
    final from =
        ctx.services.libraryLorebooks.where((b) => b.id == fromId).firstOrNull;
    if (from == null) throw StudioToolError('No library lorebook "$fromId".');
    final intoId = _arg(args, 'lorebook_id', required: true);
    final into = ctx.ws.lorebook(intoId);
    if (into == null) {
      final known = ctx.ws.lorebooks.map((b) => '${b.id} (${b.displayName})');
      throw StudioToolError('No lorebook "$intoId" in the draft. '
          '${known.isEmpty ? 'create_lorebook first.' : 'Known: ${known.join(', ')}.'}');
    }
    final uids = _ints(args, 'uids').toSet();
    final search = _arg(args, 'search').toLowerCase();
    final picked = [
      for (final e in from.entries)
        if ((uids.isEmpty || uids.contains(e.uid)) &&
            (search.isEmpty ||
                e.name.toLowerCase().contains(search) ||
                e.content.toLowerCase().contains(search) ||
                e.keys.any((k) => k.toLowerCase().contains(search))))
          e,
    ];
    if (picked.isEmpty) {
      throw StudioToolError('Nothing in "${from.displayName}" matches. '
          'read_library_item with kind "lorebook" lists its entries.');
    }
    final added = <int>[];
    ctx.edit(
      'copy_lore_entries',
      'Copied ${picked.length} ${picked.length == 1 ? 'entry' : 'entries'} '
          'from "${from.displayName}" into "${into.displayName}"',
      (ws) {
        final book = ws.lorebook(intoId)!;
        for (final e in picked) {
          final copy = e.copy()..uid = book.nextUid;
          book.entries.add(copy);
          added.add(copy.uid);
        }
      },
    );
    return StudioToolResult.json({'ok': true, 'copied': added.length, 'uids': added});
  },
);

// --- Discover ----------------------------------------------------------------------

StudioDiscoverServices _discover(StudioToolContext ctx) {
  final services = ctx.services;
  if (services is StudioDiscoverServices) {
    return services as StudioDiscoverServices;
  }
  throw StudioToolError('Discover cannot be reached here.');
}

DiscoverKind _kindArg(Map<String, dynamic> args) {
  final kind = _arg(args, 'kind');
  if (kind.isEmpty || kind == 'character' || kind == 'characters') {
    return DiscoverKind.character;
  }
  if (kind == 'lorebook' || kind == 'lorebooks') return DiscoverKind.lorebook;
  throw StudioToolError('"kind" is "character" or "lorebook".');
}

/// The catalogue [args] names, or — none named — the one Discover was left
/// on, or the first that publishes [kind].
DiscoverSource _sourceArg(
  StudioDiscoverServices d,
  Map<String, dynamic> args,
  DiscoverKind kind,
) {
  final publishing = sourcesFor(d.discover.sources, kind);
  String list() => publishing.map((s) => '${s.id} (${s.label})').join(', ');
  final wanted = _arg(args, 'source');
  if (wanted.isEmpty) {
    final last = d.discover.source(d.discoverSourceId);
    if (last != null && last.supports(kind)) return last;
    if (publishing.isEmpty) {
      throw StudioToolError('No catalogue publishes ${kind.label.toLowerCase()}.');
    }
    return publishing.first;
  }
  final source = d.discover.source(wanted) ??
      d.discover.sources
          .where((s) => s.label.toLowerCase() == wanted.toLowerCase())
          .firstOrNull;
  if (source == null) {
    throw StudioToolError('No catalogue "$wanted". For '
        '${kind.label.toLowerCase()}: ${list()}.');
  }
  if (!source.supports(kind)) {
    throw StudioToolError('${source.label} has no ${kind.label.toLowerCase()}. '
        'These do: ${list()}.');
  }
  return source;
}

/// The listing a search showed, or — when this run of the app has not
/// listed it — as much of one as the id says.
DiscoverItem _itemArg(
  StudioDiscoverServices d,
  DiscoverSource source,
  DiscoverKind kind,
  Map<String, dynamic> args,
) {
  final id = _arg(args, 'id', required: true);
  return d.discover.item(source.id, kind, id) ??
      DiscoverItem(sourceId: source.id, kind: kind, id: id, name: id);
}

/// Downloads [item], turning a site's refusal into what the agent can do
/// about it.
Future<DiscoverPayload> _fetch(
  StudioDiscoverServices d,
  DiscoverSource source,
  DiscoverItem item,
) async {
  try {
    return await d.discover.fetch(source, item);
  } on DiscoverChallengeException {
    throw StudioToolError('${source.label} wants a browser check before it '
        'will hand this over, which cannot be done from here. Ask the user to '
        'open it in Discover (Characters ▸ Discover) and download it there; '
        'it is then in the library (list_library).');
  } on DiscoverException catch (e) {
    final listed = d.discover.item(source.id, item.kind, item.id) != null;
    throw StudioToolError(listed
        ? e.message
        : '${e.message} (Search for it with discover_search first, so its '
            'whole listing is known.)');
  }
}

Map<String, dynamic> _listing(DiscoverItem i) => {
      'id': i.id,
      'name': i.name,
      if (i.creator.isNotEmpty) 'creator': i.creator,
      if (i.tagline.isNotEmpty)
        'tagline': _clip(i.tagline, 140)
      else if (i.description.isNotEmpty)
        'about': _clip(i.description, 160),
      if (i.tags.isNotEmpty) 'tags': i.tags.take(8).toList(),
      if (i.nsfw) 'nsfw': true,
      if (i.tokens != null) 'tokens': i.tokens,
      if (i.downloads != null) 'downloads': i.downloads,
      if (i.favourites != null && i.favourites! > 0) 'favourites': i.favourites,
      if (i.hasLore) 'has_lorebook': true,
      if (i.entryCount != null) 'entries': i.entryCount,
    };

final StudioTool discoverSearchTool = StudioTool(
  const ToolSpec(
    name: 'discover_search',
    description: 'Searches Discover, the app\'s catalogue browser (Chub, '
        'Character Tavern, RisuRealm and others), for characters or '
        'lorebooks other people published — for inspiration, a base to build '
        'on, or a world\'s existing lore. Returns ids for discover_read and '
        'discover_import. Adult results follow the user\'s Discover setting.',
    parameters: {
      'type': 'object',
      'properties': {
        'query': _string,
        'kind': {
          'type': 'string',
          'enum': ['character', 'lorebook'],
        },
        'source': {
          ..._string,
          'description': 'A catalogue id; left out, the one Discover was last '
              'on. Each result lists the others.',
        },
        'tags': {..._stringList, 'description': 'Only results with these tags.'},
        'exclude_tags': _stringList,
        'sort': {
          ..._string,
          'description': 'One of the catalogue\'s orderings (listed in the '
              'result); left out, its default.',
        },
        'page': {'type': 'integer'},
      },
    },
  ),
  (ctx, args) async {
    final d = _discover(ctx);
    final kind = _kindArg(args);
    final source = _sourceArg(d, args, kind);
    final sorts = source.sortsFor(kind);
    var sort = _arg(args, 'sort');
    if (sort.isNotEmpty) {
      final match = sorts
          .where((s) =>
              s.value == sort || s.label.toLowerCase() == sort.toLowerCase())
          .firstOrNull;
      if (match == null) {
        throw StudioToolError('${source.label} has no sort "$sort". It has: '
            '${sorts.map((s) => '${s.value.isEmpty ? '""' : s.value} (${s.label})').join(', ')}.');
      }
      sort = match.value;
    } else {
      sort = source.defaultSortFor(kind);
    }
    final page = (args['page'] is num ? (args['page'] as num).toInt() : 1)
        .clamp(1, 1000);
    final exclude = _list(args, 'exclude_tags');
    DiscoverPage result;
    try {
      result = await d.discover.search(
        source,
        DiscoverQuery(
          kind: kind,
          search: _arg(args, 'query'),
          sort: sort,
          page: page,
          nsfw: d.discoverNsfw,
          includeTags: _list(args, 'tags'),
          excludeTags: source.supportsTagExclusion ? exclude : const [],
          pageSize: 20,
        ),
      );
    } on DiscoverException catch (e) {
      throw StudioToolError(e.message);
    }
    return StudioToolResult.json({
      'source': source.id,
      'kind': kind.wire,
      'page': page,
      'has_more': result.hasMore,
      if (result.items.isEmpty)
        'note': 'Nothing found. Try fewer or plainer words, other tags, or '
            'another catalogue.',
      if (exclude.isNotEmpty && !source.supportsTagExclusion)
        'note_tags': '${source.label} cannot leave tags out; exclude_tags was '
            'ignored.',
      'results': [for (final i in result.items) _listing(i)],
      'sorts': [for (final s in sorts) s.value.isEmpty ? 'relevance' : s.value],
      'other_sources': [
        for (final s in sourcesFor(d.discover.sources, kind))
          if (s.id != source.id) s.id,
      ],
      if (!d.discoverNsfw) 'adult_results': 'off (the user\'s Discover setting)',
    });
  },
);

Map<String, dynamic> _cardOut(Character c, StudioServices services) {
  final fields = <String, String>{
    for (final e in kStudioTextFields.entries)
      if (e.value.$1(c).trim().isNotEmpty) e.key: e.value.$1(c),
  };
  return {
    'fields': fields,
    if (c.alternateGreetings.isNotEmpty)
      'alternate_greetings': c.alternateGreetings,
    if (c.tags.isNotEmpty) 'tags': c.tags,
    if (c.scenarios.isNotEmpty)
      'scenarios': [
        for (final s in c.scenarios) {'name': s.name, 'text': s.text},
      ],
    'permanent_tokens': services.countTokens(
      [c.description, c.personality, c.scenario, c.mesExample, c.systemPrompt,
              c.postHistoryInstructions]
          .join('\n'),
    ),
  };
}

Map<String, dynamic> _bookOut(Lorebook b, {int show = 40}) => {
      'name': b.displayName,
      if (b.description.isNotEmpty) 'description': _clip(b.description, 300),
      'entry_count': b.entries.length,
      'entries': [
        for (final e in b.entries.take(show))
          {
            if (e.name.isNotEmpty) 'name': e.name,
            'keys': e.keys,
            'content': _clip(e.content, 300),
            if (e.constant) 'constant': true,
          },
      ],
      if (b.entries.length > show)
        'more': '${b.entries.length - show} further entries come with an '
            'import.',
    };

final StudioTool discoverReadTool = StudioTool(
  const ToolSpec(
    name: 'discover_read',
    description: 'Reads one Discover listing in full (an id from '
        'discover_search): a character\'s whole definition, greetings, tags '
        'and the lorebook its card carries, or a lorebook\'s entries. '
        'Read-only — discover_import brings it into the draft.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': _string,
        'source': _string,
        'kind': {
          'type': 'string',
          'enum': ['character', 'lorebook'],
        },
      },
      'required': ['id', 'source'],
    },
  ),
  (ctx, args) async {
    final d = _discover(ctx);
    final kind = _kindArg(args);
    final source = _sourceArg(d, args, kind);
    final item = _itemArg(d, source, kind, args);
    final payload = await _fetch(d, source, item);
    final c = payload.character;
    final b = payload.lorebook;
    return StudioToolResult.json({
      'source': source.label,
      'id': item.id,
      'name': c?.displayName ?? b?.displayName ?? item.name,
      if (item.creator.isNotEmpty || (c?.creator.isNotEmpty ?? false))
        'creator': item.creator.isNotEmpty ? item.creator : c!.creator,
      if (item.pageUrl != null) 'link': item.pageUrl,
      if (item.nsfw) 'nsfw': true,
      'character': ?(c == null ? null : _cardOut(c, ctx.services)),
      'lorebook': ?(b == null ? null : _bookOut(b)),
      'note': 'Use it as inspiration in your own words unless the user asked '
          'to start from it (discover_import). Credit its creator.',
    });
  },
);

/// The first bytes of a picture, as its type — or null for anything else.
String? _imageMime(Uint8List b) {
  if (b.length >= 8 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E) {
    return 'image/png';
  }
  if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (b.length >= 12 &&
      String.fromCharCodes(b.sublist(0, 4)) == 'RIFF' &&
      String.fromCharCodes(b.sublist(8, 12)) == 'WEBP') {
    return 'image/webp';
  }
  if (b.length >= 6 && String.fromCharCodes(b.sublist(0, 3)) == 'GIF') {
    return 'image/gif';
  }
  return null;
}

/// Files a card's picture in the gallery and returns its stored ref — or
/// null when there is none, or nowhere to keep it. A link is fetched through
/// the guarded web client; bytes the site already sent are filed as they are.
/// Never hands back base64 or a bare link.
Future<String?> _filePicture(
  StudioToolContext ctx,
  String ref,
  DiscoverItem item,
  DiscoverSource source, {
  required String characterId,
}) async {
  final services = ctx.services;
  if (services is! StudioPictureServices) return null;
  final pictures = services as StudioPictureServices;
  final trimmed = ref.trim();
  if (avatarIsLocal(trimmed)) return trimmed;
  final credit = [
    source.label,
    if (item.creator.isNotEmpty) 'by ${item.creator}',
  ].join(' · ');
  WebPicture? picture;
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    try {
      final got = await pictures.images.fetchPicture(trimmed);
      picture = WebPicture(
        bytes: got.bytes,
        mime: got.mime,
        url: got.url,
        page: item.pageUrl ?? got.page,
        title: item.name,
        credit: credit,
      );
    } on ImageError {
      return null;
    }
  } else if (trimmed.isNotEmpty) {
    Uint8List bytes;
    try {
      bytes = base64Decode(trimmed);
    } catch (_) {
      return null;
    }
    final mime = _imageMime(bytes);
    if (mime == null) return null;
    picture = WebPicture(
      bytes: bytes,
      mime: mime,
      url: item.bestImageUrl ?? item.pageUrl ?? source.homeUrl,
      page: item.pageUrl ?? '',
      title: item.name,
      credit: credit,
    );
  }
  if (picture == null) return null;
  final record = await pictures.fileWebPicture(
    picture,
    characterId: characterId,
    title: item.name,
  );
  return record?.image;
}

/// A character from a listing, as a reference block for the notes.
String _referenceNote(
  Character? c,
  Lorebook? b,
  DiscoverItem item,
  DiscoverSource source,
) {
  final out = StringBuffer()
    ..writeln('Source: ${source.label}'
        '${item.creator.isNotEmpty ? ', by ${item.creator}' : ''}'
        '${item.pageUrl != null ? ' — ${item.pageUrl}' : ''}');
  if (c != null) {
    if (c.tags.isNotEmpty) out.writeln('Tags: ${c.tags.join(', ')}');
    for (final e in kStudioTextFields.entries) {
      if (const {'name', 'creator', 'character_version'}.contains(e.key)) continue;
      final text = e.value.$1(c).trim();
      if (text.isEmpty) continue;
      out
        ..writeln()
        ..writeln('**${e.key.replaceAll('_', ' ')}**')
        ..writeln(text);
    }
    for (var i = 0; i < c.alternateGreetings.length; i++) {
      out
        ..writeln()
        ..writeln('**alternate greeting ${i + 1}**')
        ..writeln(c.alternateGreetings[i].trim());
    }
  }
  if (b != null && b.entries.isNotEmpty) {
    out
      ..writeln()
      ..writeln('**lorebook: ${b.displayName}** (${b.entries.length} entries)');
    for (final e in b.entries) {
      final title = e.name.trim().isNotEmpty ? e.name.trim() : e.keys.join(', ');
      out.writeln('- $title: ${_clip(e.content, 400)}');
    }
  }
  return out.toString().trim();
}

final StudioTool discoverImportTool = StudioTool(
  const ToolSpec(
    name: 'discover_import',
    description: 'Brings a Discover listing (an id from discover_search) '
        'into the draft. as "base": the draft becomes that character — its '
        'card, picture and the lorebook it carries — to build on, when the '
        'user wants to start from it. as "reference": its definition goes '
        'into the session notes under its own heading, to work from without '
        'copying it into the card. as "lorebook": a lorebook listing, or the '
        'book a character carries, is added to the draft and attached. '
        'Documents and notes are kept; a base import can be rewound in '
        'Changes.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': _string,
        'source': _string,
        'kind': {
          'type': 'string',
          'enum': ['character', 'lorebook'],
        },
        'as': {
          'type': 'string',
          'enum': ['base', 'reference', 'lorebook'],
        },
        'keep_lorebooks': {
          'type': 'boolean',
          'description': 'as "base": keep the lorebooks the draft already has.',
        },
      },
      'required': ['id', 'source', 'as'],
    },
  ),
  (ctx, args) async {
    final d = _discover(ctx);
    final kind = _kindArg(args);
    final as = _arg(args, 'as', required: true);
    if (!const {'base', 'reference', 'lorebook'}.contains(as)) {
      throw StudioToolError('"as" is "base", "reference" or "lorebook".');
    }
    final source = _sourceArg(d, args, kind);
    final item = _itemArg(d, source, kind, args);
    if (as == 'base') {
      // Checked before the download: a stale draft fails fast.
      ctx.ensureFresh([
        ..._characterParts(ctx.ws),
        if (!_flag(args, 'keep_lorebooks')) ..._bookParts(ctx.ws),
      ]);
    }
    final payload = await _fetch(d, source, item);
    final card = payload.character;
    final book = payload.lorebook;

    if (as == 'reference') {
      final name = card?.displayName ?? book?.displayName ?? item.name;
      final note = _referenceNote(card, book, item, source);
      final section = 'From Discover: $name';
      ctx.edit('discover_import', 'Noted "$name" from ${source.label}',
          (ws) => ws.notes = appendToNotes(ws.notes, note, section: section));
      return StudioToolResult.json({
        'ok': true,
        'as': 'reference',
        'section': section,
        'tokens': ctx.services.countTokens(note),
      });
    }

    if (as == 'lorebook') {
      if (book == null || book.entries.isEmpty) {
        throw StudioToolError(card != null
            ? '"${card.displayName}" carries no lorebook.'
            : 'That listing has no entries to bring in.');
      }
      final copy = _freshBook(book);
      ctx.edit('discover_import',
          'Added lorebook "${copy.displayName}" from ${source.label}', (ws) {
        ws.lorebooks.add(copy);
        if (!ws.character.lorebookIds.contains(copy.id)) {
          ws.character.lorebookIds.add(copy.id);
        }
      });
      return StudioToolResult.json({
        'ok': true,
        'as': 'lorebook',
        'lorebook_id': copy.id,
        'name': copy.displayName,
        'entries': copy.entries.length,
      });
    }

    if (card == null) {
      throw StudioToolError('That is a lorebook, not a character; import it '
          'as "lorebook".');
    }
    // A new character of the user's own: it is not in the library yet.
    final character = card.copyWith(id: _newId());
    final keep = _flag(args, 'keep_lorebooks');
    final picture = await _filePicture(
      ctx,
      character.hasAvatar ? character.avatar : (item.bestImageUrl ?? ''),
      item,
      source,
      characterId: character.id,
    );
    final hadPicture = character.hasAvatar || item.bestImageUrl != null;
    character.avatar = picture ?? '';
    // Extra pictures a card carries are filed the same way, or dropped.
    final extras = <String>[];
    for (final ref in character.avatars.take(6)) {
      final filed =
          await _filePicture(ctx, ref, item, source, characterId: character.id);
      if (filed != null && filed != character.avatar) extras.add(filed);
    }
    character.avatars = extras;
    if (character.creator.trim().isEmpty) character.creator = item.creator;
    character.lorebookIds = [];
    final books = [if (book != null && book.entries.isNotEmpty) _freshBook(book)];
    ctx.edit(
      'discover_import',
      'Started from "${character.displayName}" on ${source.label}',
      (ws) => _replaceCharacter(ws, character, books, keepLorebooks: keep),
    );
    return StudioToolResult.json({
      'ok': true,
      'as': 'base',
      'name': character.displayName,
      if (books.isNotEmpty)
        'lorebook': {
          'id': books.first.id,
          'name': books.first.displayName,
          'entries': books.first.entries.length,
        },
      'picture': picture != null
          ? 'filed in the gallery with its source'
          : hadPicture
              ? 'could not be saved; the draft has no picture'
              : 'none',
      'next': 'Call get_draft before editing it. Credit '
          '${item.creator.isNotEmpty ? item.creator : 'its creator'} in the '
          'creator notes if the user keeps much of it.',
    });
  },
);
