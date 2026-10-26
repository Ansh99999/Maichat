import '../../models/chat_tool.dart';

/// The chat operations shipped with MaiChat.
///
/// These definitions advertise only the schema and a short, model-readable
/// purpose. Their `action` is empty because each name is handled natively by
/// the chat owner; this library does not implement image generation or tool
/// persistence by itself.
const List<ChatToolDefinition> chatToolBuiltIns = [
  ChatToolDefinition(
    name: 'roll_dice',
    description:
        'Rolls dice and returns the individual rolls, modifier and '
        'total. Use compact formulas such as 2d6+3, d20, 4d8-2, or 20 (meaning '
        '1d20).',
    parameters: {
      'type': 'object',
      'properties': {
        'formula': {
          'type': 'string',
          'description': 'Dice formula, such as 2d6+3 or d20.',
          'minLength': 1,
          'maxLength': 32,
        },
      },
      'required': ['formula'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'random_integer',
    description: 'Chooses one inclusive integer between min and max.',
    parameters: {
      'type': 'object',
      'properties': {
        'min': {'type': 'integer', 'description': 'Lower bound, inclusive.'},
        'max': {'type': 'integer', 'description': 'Upper bound, inclusive.'},
      },
      'required': ['min', 'max'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'read_trackers',
    description:
        'Reads the numeric trackers available to this chat. Use this '
        'before updating a tracker when its current value matters.',
    parameters: {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'define_tracker',
    description: 'Defines a numeric chat tracker such as Health or Energy.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Stable tracker id, such as health.',
          'minLength': 1,
          'maxLength': 64,
        },
        'label': {
          'type': 'string',
          'description': 'Human-readable name, such as Health.',
          'minLength': 1,
          'maxLength': 64,
        },
        'value': {'type': 'number', 'description': 'Initial numeric value.'},
        'subject': {
          'type': 'string',
          'description':
              'Optional character, group or other subject this '
              'tracker belongs to.',
        },
        'unit': {
          'type': 'string',
          'description': 'Optional unit shown beside the value.',
        },
        'min': {'type': 'number', 'description': 'Optional lower bound.'},
        'max': {'type': 'number', 'description': 'Optional upper bound.'},
      },
      'required': ['id', 'label', 'value'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'update_tracker',
    description:
        'Sets a tracker value or changes it by a signed delta. '
        'Provide exactly one of value or delta.',
    parameters: {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Tracker id to update.',
          'minLength': 1,
          'maxLength': 64,
        },
        'value': {'type': 'number', 'description': 'Replacement value.'},
        'delta': {
          'type': 'number',
          'description': 'Signed change from the current value.',
        },
      },
      'required': ['id'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'set_prompt_injection',
    description:
        'Adds a short out-of-character correction for the next reply '
        'or for the persistent conversation context.',
    parameters: {
      'type': 'object',
      'properties': {
        'text': {
          'type': 'string',
          'description': 'Instruction to inject, without roleplay prose.',
          'minLength': 1,
          'maxLength': 4096,
        },
        'depth': {
          'type': 'integer',
          'description': 'Depth in roleplay messages; 0 is nearest the reply.',
          'minimum': 0,
          'maximum': 1000,
        },
        'lifetime': {
          'type': 'string',
          'enum': ['next_reply', 'persistent'],
          'description': 'How long the correction remains active.',
        },
      },
      'required': ['text', 'depth', 'lifetime'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'generate_image',
    description:
        'Generates a picture from the supplied prompt and attaches it '
        'to this reply. Use only when the user or story clearly asks for an '
        'image.',
    parameters: {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': 'Image prompt, including subject and visual style.',
          'minLength': 1,
          'maxLength': 4096,
        },
      },
      'required': ['prompt'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'list_tools',
    description: 'Lists the tool definitions available in this chat.',
    parameters: {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'save_tool',
    description:
        'Saves a custom tool definition to the selected chat or global '
        'tool library.',
    parameters: {
      'type': 'object',
      'properties': {
        'definition': {
          'type': 'string',
          'description':
              'JSON-encoded tool definition containing name, description, '
              'parameters schema and executable Recipe JSON action.',
        },
        'scope': {
          'type': 'string',
          'enum': ['chat', 'global'],
          'description': 'Where the definition is saved.',
        },
      },
      'required': ['definition', 'scope'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
  ChatToolDefinition(
    name: 'delete_tool',
    description:
        'Deletes a custom tool from the selected chat or global tool '
        'library.',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': 'Tool name to delete.',
          'minLength': 1,
          'maxLength': 64,
        },
        'scope': {
          'type': 'string',
          'enum': ['chat', 'global'],
          'description': 'Library to delete from.',
        },
      },
      'required': ['name', 'scope'],
      'additionalProperties': false,
    },
    action: {},
    builtin: true,
  ),
];
