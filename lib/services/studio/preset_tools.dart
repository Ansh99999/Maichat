import 'dart:convert';

import '../../models/agent_message.dart';
import '../../models/preset.dart';
import '../../models/prompt_block.dart';
import 'studio_tools.dart';

/// The generation presets in the user's library. Optional so hosts which only
/// support character drafts do not have to implement another library.
abstract class StudioPresetServices {
  List<Preset> get libraryPresets;
}

List<Preset> libraryPresetsOf(StudioServices services) =>
    services is StudioPresetServices
    ? (services as StudioPresetServices).libraryPresets
    : const <Preset>[];

const List<String> kPresetReadToolNames = ['list_presets', 'get_preset'];
const List<String> kPresetEditToolNames = [
  'load_preset',
  'update_preset',
  'clear_preset',
];

final List<StudioTool> kPresetTools = [
  listPresetsTool,
  getPresetTool,
  loadPresetTool,
  updatePresetTool,
  clearPresetTool,
];

const _string = {'type': 'string'};
const _boolean = {'type': 'boolean'};
const _strings = {'type': 'array', 'items': _string};

void _only(Map<String, dynamic> args, Iterable<String> keys) {
  final unknown = args.keys.where((key) => !keys.contains(key));
  if (unknown.isNotEmpty) {
    throw StudioToolError('Unknown option(s): ${unknown.join(', ')}.');
  }
}

String _text(Object? value, String key) {
  if (value is! String) throw StudioToolError('"$key" must be a string.');
  return value;
}

String _id(Map<String, dynamic> args) {
  final id = _text(args['id'], 'id').trim();
  if (id.isEmpty) throw StudioToolError('"id" must not be empty.');
  return id;
}

bool _bool(Object? value, String key) {
  if (value is! bool) throw StudioToolError('"$key" must be true or false.');
  return value;
}

num _number(
  Object? value,
  String key, {
  num? min,
  num? max,
  bool integer = false,
}) {
  if (value is! num ||
      !value.isFinite ||
      (integer &&
          value is! int &&
          (value != value.roundToDouble() || value.toInt() != value))) {
    throw StudioToolError(
      '"$key" must be a finite ${integer ? 'whole number' : 'number'}.',
    );
  }
  if ((min != null && value < min) || (max != null && value > max)) {
    throw StudioToolError(
      '"$key" must be ${max == null ? 'at least $min' : 'between $min and $max'}.',
    );
  }
  return value;
}

List<String> _stringList(Object? value, String key) {
  if (value is! List || value.any((v) => v is! String)) {
    throw StudioToolError('"$key" must be a list of strings.');
  }
  return value.cast<String>().toList();
}

Map<String, dynamic> _object(Object? value, String key) {
  if (value is! Map || value.keys.any((k) => k is! String)) {
    throw StudioToolError('"$key" must be an object.');
  }
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Preset _fromNativeJson(Map<String, dynamic> json) =>
    Preset.fromJson(_deepCopy(json));

Preset _libraryPreset(StudioToolContext ctx, String id) {
  final preset = libraryPresetsOf(
    ctx.services,
  ).where((p) => p.id == id).firstOrNull;
  if (preset == null) {
    throw StudioToolError(
      'No library preset "$id". Call list_presets for ids.',
    );
  }
  return preset;
}

Map<String, dynamic> _selected(StudioToolContext ctx) => {
  'preset': ctx.ws.preset?.toJson(),
  'uses_active_preset': ctx.ws.preset == null,
};

final StudioTool listPresetsTool = StudioTool(
  const ToolSpec(
    name: 'list_presets',
    description:
        'Lists generation presets in the user\'s library, with ids, '
        'provider/model bindings and the selected draft preset. Use get_preset '
        'with an id to read one in full, then load_preset to playtest or edit it.',
    parameters: {
      'type': 'object',
      'properties': {'search': _string},
    },
  ),
  (ctx, args) async {
    _only(args, ['search']);
    final search = args.containsKey('search')
        ? _text(args['search'], 'search').trim().toLowerCase()
        : '';
    return StudioToolResult.json({
      'selected_preset_id': ctx.ws.preset?.id,
      'presets': [
        for (final p in libraryPresetsOf(ctx.services))
          if (search.isEmpty ||
              '${p.displayName} ${p.model}'.toLowerCase().contains(search))
            {
              'id': p.id,
              'name': p.displayName,
              'providerId': p.providerId,
              'model': p.model,
              'selected': p.id == ctx.ws.preset?.id,
            },
      ],
    });
  },
);

final StudioTool getPresetTool = StudioTool(
  const ToolSpec(
    name: 'get_preset',
    description:
        'Reads the draft\'s selected generation preset in full native '
        'JSON, including sampling, prompts and promptOrder. With id, reads a '
        'library preset instead, without selecting it. No selection means '
        'playtests use the app\'s active preset. Read the draft version before '
        'editing it; an id reads only the library version.',
    parameters: {
      'type': 'object',
      'properties': {'id': _string},
    },
  ),
  (ctx, args) async {
    _only(args, ['id']);
    if (args.containsKey('id')) {
      return StudioToolResult.json({
        'preset': _libraryPreset(ctx, _id(args)).toJson(),
      });
    }
    ctx.markSeen(['preset']);
    return StudioToolResult.json(_selected(ctx));
  },
);

final StudioTool loadPresetTool = StudioTool(
  const ToolSpec(
    name: 'load_preset',
    description:
        'Loads a library generation preset into the Studio draft for '
        'playtests, Playground replies and count_tokens prompt measurements. '
        'The library stays unchanged until the user applies the draft. Keeps '
        'its id so Apply updates it; as_copy: true gives it a new id/name so '
        'Apply creates a separate preset. Replaces the previously selected '
        'draft preset and can be rewound in Changes.',
    parameters: {
      'type': 'object',
      'properties': {'id': _string, 'as_copy': _boolean},
      'required': ['id'],
    },
  ),
  (ctx, args) async {
    _only(args, ['id', 'as_copy']);
    final source = _libraryPreset(ctx, _id(args));
    final asCopy = args.containsKey('as_copy')
        ? _bool(args['as_copy'], 'as_copy')
        : false;
    final json = _deepCopy(source.toJson());
    if (asCopy) {
      json['id'] = Preset.create().id;
      json['name'] = '${source.displayName} (copy)';
    }
    final selected = _fromNativeJson(json);
    ctx.ensureFresh(['preset'], reread: 'get_preset');
    ctx.edit(
      'load_preset',
      'Loaded generation preset "${selected.displayName}"',
      (ws) {
        ws.preset = selected;
      },
    );
    return StudioToolResult.json({'ok': true, ..._selected(ctx)});
  },
);

const _textFields = ['name', 'model', 'thinkStartTag', 'thinkEndTag'];
const _boolFields = [
  'useMaxContext',
  'stream',
  'wrapInQuotes',
  'squashSystemMessages',
  'maxContextUnlocked',
  'thinking',
];
const _integerRanges = <String, (int, int?)>{
  'maxResponseTokens': (1, null),
  'maxContext': (1, null),
  'topK': (0, null),
  'topA': (0, 1000),
  'seed': (-1, null),
  'n': (1, 8),
  'namesBehavior': (-1, 2),
  'thinkingBudget': (0, null),
  'summaryBudget': (1, null),
  'colorBand': (0, 0xffffffff),
};
const _numberRanges = <String, (double, double)>{
  'temperature': (0, 2),
  'topP': (0, 1),
  'minP': (0, 1),
  'frequencyPenalty': (-2, 2),
  'presencePenalty': (-2, 2),
  'repetitionPenalty': (0, 2),
};

const _blockProperties = {
  'identifier': _string,
  'name': _string,
  'role': {'type': 'string', 'enum': kPromptRoles},
  'content': _string,
  'system_prompt': _boolean,
  'marker': _boolean,
  'injection_position': {
    'type': 'integer',
    'enum': [0, 1],
  },
  'injection_depth': {'type': 'integer'},
  'injection_order': {'type': 'integer'},
  'injection_trigger': _strings,
  'forbid_overrides': _boolean,
};

List<Map<String, dynamic>> _blocks(Object? value, Preset current) {
  if (value is! List) {
    throw StudioToolError('"prompts" must be a list of prompt blocks.');
  }
  final ids = <String>{};
  return [
    for (var i = 0; i < value.length; i++)
      (() {
        final block = _object(value[i], 'prompts[$i]');
        final id = _id({'id': block['identifier']});
        _only(block, [
          ..._blockProperties.keys,
          ...?current.blockById(id)?.raw.keys,
        ]);
        if (!ids.add(id)) {
          throw StudioToolError('Duplicate prompt identifier "$id".');
        }
        block['identifier'] = id;
        for (final key in ['name', 'role', 'content']) {
          if (block.containsKey(key)) _text(block[key], 'prompts[$i].$key');
        }
        if (block.containsKey('role') &&
            !kPromptRoles.contains(block['role'])) {
          throw StudioToolError(
            'Prompt "$id" role must be system, user or assistant.',
          );
        }
        for (final key in ['system_prompt', 'marker', 'forbid_overrides']) {
          if (block.containsKey(key)) _bool(block[key], 'prompts[$i].$key');
        }
        for (final key in [
          'injection_position',
          'injection_depth',
          'injection_order',
        ]) {
          if (!block.containsKey(key)) continue;
          block[key] = _number(
            block[key],
            'prompts[$i].$key',
            integer: true,
            min: 0,
            max: key == 'injection_position' ? 1 : null,
          ).toInt();
        }
        if (block.containsKey('injection_trigger')) {
          block['injection_trigger'] = _stringList(
            block['injection_trigger'],
            'prompts[$i].injection_trigger',
          );
        }
        // Full replacement of known block fields; imported plugin fields stay
        // attached to the same identifier even if the agent omits them.
        return {...?current.blockById(id)?.raw, ...block};
      })(),
  ];
}

List<Map<String, dynamic>> _order(Object? value) {
  if (value is! List) throw StudioToolError('"promptOrder" must be a list.');
  final ids = <String>{};
  return [
    for (var i = 0; i < value.length; i++)
      (() {
        final entry = _object(value[i], 'promptOrder[$i]');
        _only(entry, ['identifier', 'enabled']);
        final id = _id({'id': entry['identifier']});
        if (!ids.add(id)) {
          throw StudioToolError('Duplicate promptOrder identifier "$id".');
        }
        return {
          'identifier': id,
          'enabled': entry.containsKey('enabled')
              ? _bool(entry['enabled'], 'promptOrder[$i].enabled')
              : true,
        };
      })(),
  ];
}

final StudioTool updatePresetTool = StudioTool(
  ToolSpec(
    name: 'update_preset',
    description:
        'Edits the selected draft generation preset. Pass only changed '
        'native JSON fields in changes (camelCase sampling; prompts uses '
        'SillyTavern snake_case block fields). prompts and promptOrder each '
        'replace their complete array, including an empty array. Read '
        'get_preset first and keep needed character/history markers. Unknown '
        'import settings are preserved. The id stays fixed. clear explicitly '
        'removes providerId/colorBand; empty model uses the app\'s selected '
        'model. Nothing changes in the library until the user applies.',
    parameters: {
      'type': 'object',
      'properties': {
        'changes': {
          'type': 'object',
          'properties': {
            for (final key in _textFields) key: _string,
            'providerId': _string,
            'mode': {
              'type': 'string',
              'enum': ['simple', 'advanced'],
            },
            'reasoningEffort': {
              'type': 'string',
              'enum': ['', 'low', 'medium', 'high'],
            },
            for (final key in _boolFields) key: _boolean,
            for (final e in _integerRanges.entries)
              e.key: {
                'type': 'integer',
                'description':
                    'At least ${e.value.$1}${e.value.$2 == null ? '' : ', at most ${e.value.$2}'}.',
              },
            for (final e in _numberRanges.entries)
              e.key: {
                'type': 'number',
                'description': '${e.value.$1} to ${e.value.$2}.',
              },
            'stopSequences': _strings,
            'prompts': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': _blockProperties,
                'required': ['identifier'],
              },
            },
            'promptOrder': {
              'type': 'array',
              'items': {
                'type': 'object',
                'properties': {'identifier': _string, 'enabled': _boolean},
                'required': ['identifier'],
              },
            },
          },
        },
        'clear': {
          'type': 'array',
          'items': {
            'type': 'string',
            'enum': ['providerId', 'colorBand'],
          },
        },
      },
    },
  ),
  (ctx, args) async {
    _only(args, ['changes', 'clear']);
    // This key survives a replacement or a clear. Check it before looking at
    // the current selection so an intervening clear still asks for a reread.
    ctx.ensureFresh(['preset'], reread: 'get_preset');
    final current = ctx.ws.preset;
    if (current == null) {
      throw StudioToolError(
        'No draft preset selected. Call load_preset first.',
      );
    }
    final changes = args.containsKey('changes')
        ? _object(args['changes'], 'changes')
        : <String, dynamic>{};
    final clear = args.containsKey('clear')
        ? _stringList(args['clear'], 'clear')
        : <String>[];
    _only(changes, [
      ..._textFields,
      ..._boolFields,
      ..._integerRanges.keys,
      ..._numberRanges.keys,
      'providerId',
      'mode',
      'reasoningEffort',
      'stopSequences',
      'prompts',
      'promptOrder',
    ]);
    if (changes.isEmpty && clear.isEmpty) {
      throw StudioToolError('Pass changes or clear to edit the preset.');
    }
    for (final key in clear) {
      if (!['providerId', 'colorBand'].contains(key)) {
        throw StudioToolError(
          'Cannot clear "$key"; clear only providerId or colorBand.',
        );
      }
      if (changes.containsKey(key)) {
        throw StudioToolError(
          'Cannot change and clear "$key" in the same call.',
        );
      }
    }
    final json = _deepCopy(current.toJson());
    for (final entry in changes.entries) {
      final key = entry.key;
      final value = entry.value;
      if (_textFields.contains(key) || key == 'providerId') {
        json[key] = _text(value, key);
        if (key == 'providerId' && (json[key] as String).trim().isEmpty) {
          throw StudioToolError(
            'providerId must not be empty; use clear: ["providerId"].',
          );
        }
      } else if (_boolFields.contains(key)) {
        json[key] = _bool(value, key);
      } else if (_integerRanges.containsKey(key)) {
        final range = _integerRanges[key]!;
        json[key] = _number(
          value,
          key,
          integer: true,
          min: range.$1,
          max: range.$2,
        ).toInt();
      } else if (_numberRanges.containsKey(key)) {
        final range = _numberRanges[key]!;
        json[key] = _number(
          value,
          key,
          min: range.$1,
          max: range.$2,
        ).toDouble();
      } else if (key == 'mode' || key == 'reasoningEffort') {
        final allowed = key == 'mode'
            ? ['simple', 'advanced']
            : ['', 'low', 'medium', 'high'];
        if (!allowed.contains(value)) {
          throw StudioToolError(
            'Invalid $key; use ${allowed.map((v) => '"$v"').join(', ')}.',
          );
        }
        json[key] = value;
      } else if (key == 'stopSequences') {
        json[key] = _stringList(value, key);
        if ((json[key] as List<String>).any((stop) => stop.isEmpty)) {
          throw StudioToolError(
            'stopSequences must not contain empty strings.',
          );
        }
      } else if (key == 'prompts') {
        json[key] = _blocks(value, current);
      } else if (key == 'promptOrder') {
        json[key] = _order(value);
      }
    }
    for (final key in clear) {
      json.remove(key);
    }
    if (changes.containsKey('prompts') || changes.containsKey('promptOrder')) {
      final ids = {for (final b in json['prompts'] as List) b['identifier']};
      for (final e in json['promptOrder'] as List) {
        if (!ids.contains(e['identifier'])) {
          throw StudioToolError(
            'promptOrder references missing prompt "${e['identifier']}"; update both arrays together.',
          );
        }
      }
    }
    final updated = _fromNativeJson(json);
    ctx.edit(
      'update_preset',
      'Updated generation preset "${updated.displayName}"',
      (ws) {
        ws.preset = updated;
      },
    );
    return StudioToolResult.json({'ok': true, ..._selected(ctx)});
  },
);

final StudioTool clearPresetTool = StudioTool(
  const ToolSpec(
    name: 'clear_preset',
    description:
        'Removes the Studio draft\'s selected generation preset, '
        'returning playtests and Playground replies to the app\'s active '
        'preset. Does not delete a library preset. Can be rewound in Changes.',
  ),
  (ctx, args) async {
    _only(args, const []);
    ctx.ensureFresh(['preset'], reread: 'get_preset');
    if (ctx.ws.preset != null) {
      ctx.edit('clear_preset', 'Cleared the draft generation preset', (ws) {
        ws.preset = null;
      });
    }
    return StudioToolResult.json({'ok': true, ..._selected(ctx)});
  },
);
