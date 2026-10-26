/// A small, portable recipe interpreter for user-defined chat tools.
///
/// The language is deliberately JSON-only. A recipe is either a direct
/// operation call:
///
/// ```json
/// {"call": "roll_dice", "arguments": {"formula": "2d6+3"}}
/// ```
///
/// or a list of bounded steps:
///
/// ```json
/// {
///   "steps": [
///     {"let": "side", "value": {"ref": "args.high"}},
///     {
///       "id": "roll",
///       "call": "random_integer",
///       "arguments": {"min": 1, "max": {"ref": "vars.side"}}
///     },
///     {
///       "if": {"op": ">=", "values": [{"ref": "vars.roll"}, 4]},
///       "then": [{"return": "success"}],
///       "else": [{"return": "failure"}]
///     }
///   ]
/// }
/// ```
///
/// Expressions can be ordinary JSON values, `{"ref": "args.name"}` or
/// `{"ref": "vars.result.total"}`, arithmetic/comparison/boolean operations,
/// or `{"template": "Rolled {vars.roll}"}`. No Dart, JavaScript, shell, HTTP or
/// other host access is evaluated here. Operations are supplied by the caller,
/// and the executor enforces execution, recursion, cancellation and numeric
/// bounds.
library;

import 'dart:convert';
import 'dart:math' show Random;

typedef ChatToolOperation =
    Future<Object?> Function(String name, Map<String, dynamic> arguments);

const int kChatToolMaxSteps = 100;
const int kChatToolMaxDepth = 32;
const double _kMaxRecipeNumber = 1e15;

final RegExp _kVariablePattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
final RegExp _kTemplateRefPattern = RegExp(r'\{(args|vars)(?:\.[^{}.\s]+)+\}');

class ChatToolRuntime {
  const ChatToolRuntime();

  Future<Object?> execute(
    Map<String, dynamic> action,
    Map<String, dynamic> arguments,
    ChatToolOperation invoke, {
    bool Function()? cancelled,
  }) async {
    _validateAction(action);
    _validateJson(arguments, 'arguments');
    if (_isCancelled(cancelled)) {
      throw StateError('Tool execution was cancelled.');
    }

    final state = _ExecutionState(arguments: arguments, cancelled: cancelled);
    if (action.containsKey('call')) {
      state.steps++;
      return _invoke(
        action['call'] as String,
        _expectMap(_evaluate(action['arguments'], state, 0), 'call arguments'),
        invoke,
        state,
      );
    }

    final result = await _runSteps(
      action['steps'] as List<Object?>,
      invoke,
      state,
      1,
    );
    return result.returned ? result.value : null;
  }

  Future<_StepResult> _runSteps(
    List<Object?> steps,
    ChatToolOperation invoke,
    _ExecutionState state,
    int depth,
  ) async {
    if (depth > kChatToolMaxDepth) {
      throw StateError(
        'Tool recipe exceeded the maximum recursion depth of '
        '$kChatToolMaxDepth.',
      );
    }

    for (final rawStep in steps) {
      if (state.steps >= kChatToolMaxSteps) {
        throw StateError(
          'Tool recipe exceeded the maximum of $kChatToolMaxSteps steps.',
        );
      }
      if (_isCancelled(state.cancelled)) {
        throw StateError('Tool execution was cancelled.');
      }
      state.steps++;

      final step = rawStep as Map<String, Object?>;
      if (step.containsKey('return')) {
        return _StepResult(
          returned: true,
          value: _evaluate(step['return'], state, 0),
        );
      }
      if (step.containsKey('let')) {
        state.variables[step['let'] as String] = _evaluate(
          step['value'],
          state,
          0,
        );
        continue;
      }
      if (step.containsKey('if')) {
        final condition = _expectBool(
          _evaluate(step['if'], state, 0),
          'if condition',
        );
        final branch = condition ? step['then'] : step['else'];
        final branchSteps = branch as List<Object?>?;
        if (branchSteps == null || branchSteps.isEmpty) continue;
        final result = await _runSteps(branchSteps, invoke, state, depth + 1);
        if (result.returned) return result;
        continue;
      }

      final callStep = step;
      final name = callStep['call'] as String;
      final result = await _invoke(
        name,
        _expectMap(
          _evaluate(callStep['arguments'], state, 0),
          'arguments for "$name"',
        ),
        invoke,
        state,
      );
      final id = callStep['id'] as String?;
      if (id != null && id.isNotEmpty) state.variables[id] = result;
    }

    return const _StepResult(returned: false, value: null);
  }

  Future<Object?> _invoke(
    String name,
    Map<String, dynamic> arguments,
    ChatToolOperation invoke,
    _ExecutionState state,
  ) async {
    if (_isCancelled(state.cancelled)) {
      throw StateError('Tool execution was cancelled.');
    }
    final result = await invoke(name, arguments);
    _validateJson(result, 'result of "$name"');
    return _cloneJson(result);
  }

  Object? _evaluate(Object? expression, _ExecutionState state, int depth) {
    if (depth > kChatToolMaxDepth) {
      throw StateError(
        'Tool recipe exceeded the maximum recursion depth of '
        '$kChatToolMaxDepth.',
      );
    }

    if (expression is Map) {
      final map = <String, Object?>{
        for (final entry in expression.entries)
          entry.key.toString(): entry.value,
      };
      if (_hasOnly(map, const {'ref'})) {
        return _readReference(map['ref'] as String, state);
      }
      if (_hasOnly(map, const {'op', 'values'})) {
        return _operation(map, state, depth + 1);
      }
      if (_hasOnly(map, const {'template'})) {
        return _template(map['template'] as String, state, depth + 1);
      }
      return {
        for (final entry in map.entries)
          entry.key.toString(): _evaluate(entry.value, state, depth + 1),
      };
    }
    if (expression is List) {
      return [
        for (final value in expression) _evaluate(value, state, depth + 1),
      ];
    }
    if (expression is num && !expression.isFinite) {
      throw FormatException('Numbers in a tool recipe must be finite.');
    }
    return expression;
  }

  Object? _operation(
    Map<String, Object?> expression,
    _ExecutionState state,
    int depth,
  ) {
    final op = expression['op'] as String;
    final values = expression['values'] as List<Object?>;
    final evaluated = <Object?>[
      for (final value in values) _evaluate(value, state, depth + 1),
    ];

    switch (op) {
      case '+':
      case '-':
      case '*':
      case '/':
        return _arithmetic(op, evaluated, expression);
      case '==':
        if (evaluated.length != 2) {
          throw FormatException('Operator "$op" needs exactly two values.');
        }
        return _jsonEqual(evaluated[0], evaluated[1]);
      case '!=':
        if (evaluated.length != 2) {
          throw FormatException('Operator "$op" needs exactly two values.');
        }
        return !_jsonEqual(evaluated[0], evaluated[1]);
      case '<':
      case '<=':
      case '>':
      case '>=':
        if (evaluated.length != 2) {
          throw FormatException('Operator "$op" needs exactly two values.');
        }
        final a = _number(evaluated[0], 'left operand of "$op"');
        final b = _number(evaluated[1], 'right operand of "$op"');
        return switch (op) {
          '<' => a < b,
          '<=' => a <= b,
          '>' => a > b,
          _ => a >= b,
        };
      case 'and':
        for (final value in evaluated) {
          if (!_expectBoolValue(value, 'and operand')) return false;
        }
        return true;
      case 'or':
        for (final value in evaluated) {
          if (_expectBoolValue(value, 'or operand')) return true;
        }
        return false;
      case 'not':
        if (evaluated.length != 1) {
          throw FormatException('Operator "not" needs exactly one value.');
        }
        return !_expectBoolValue(evaluated[0], 'not operand');
      default:
        throw FormatException('Unknown tool recipe operator "$op".');
    }
  }

  num _arithmetic(
    String op,
    List<Object?> values,
    Map<String, Object?> expression,
  ) {
    if (op != '+' && values.length != 2) {
      throw FormatException('Operator "$op" needs exactly two values.');
    }
    num result;
    if (op == '+') {
      result = 0;
      for (final value in values) {
        result += _number(value, 'add operand');
      }
    } else {
      final a = _number(values[0], 'left operand of "$op"');
      final b = _number(values[1], 'right operand of "$op"');
      result = switch (op) {
        '-' => a - b,
        '*' => a * b,
        _ => a / b,
      };
    }
    if (!result.isFinite || result.abs() > _kMaxRecipeNumber) {
      throw StateError('Tool recipe arithmetic produced an unbounded number.');
    }
    return result == result.truncateToDouble() ? result.toInt() : result;
  }

  Object? _readReference(String ref, _ExecutionState state) {
    final parts = ref.split('.');
    if (parts.length < 2 || parts.any((part) => part.isEmpty)) {
      throw FormatException('Malformed tool recipe reference "$ref".');
    }
    final root = parts[0];
    if (root != 'args' && root != 'vars') {
      throw FormatException(
        'Tool recipe references may start only with "args" or "vars", not '
        '"$root".',
      );
    }
    final source = root == 'args' ? state.arguments : state.variables;
    Object? value = source;
    for (final part in parts.skip(1)) {
      if (value is! Map) {
        throw FormatException('Missing tool recipe reference "$ref".');
      }
      if (!value.containsKey(part)) {
        throw FormatException('Missing tool recipe reference "$ref".');
      }
      value = value[part];
    }
    _validateJson(value, 'reference "$ref"');
    return _cloneJson(value);
  }

  String _template(String text, _ExecutionState state, int depth) {
    if (depth > kChatToolMaxDepth) {
      throw StateError(
        'Tool recipe exceeded the maximum recursion depth of '
        '$kChatToolMaxDepth.',
      );
    }
    return text.replaceAllMapped(_kTemplateRefPattern, (match) {
      final value = _readReference(
        match.group(0)!.substring(1, match.group(0)!.length - 1),
        state,
      );
      if (value == null) return 'null';
      if (value is String) return value;
      if (value is num || value is bool) return value.toString();
      return jsonEncode(value);
    });
  }

  bool _isCancelled(bool Function()? cancelled) {
    final check = cancelled?.call();
    return check == true;
  }
}

class _ExecutionState {
  _ExecutionState({required this.arguments, required this.cancelled});

  final Map<String, dynamic> arguments;
  final Map<String, dynamic> variables = <String, dynamic>{};
  final bool Function()? cancelled;
  int steps = 0;
}

class _StepResult {
  const _StepResult({required this.returned, required this.value});

  final bool returned;
  final Object? value;
}

void _validateAction(Map<String, dynamic> action) {
  final directCall = action.containsKey('call');
  final stepsForm = action.containsKey('steps');
  if (directCall == stepsForm) {
    throw const FormatException(
      'A tool action must contain either "call" or "steps", not both or '
      'neither.',
    );
  }

  if (directCall) {
    _validateKeys(action, const {'call', 'arguments'});
    _validateOperation(action['call'], 'call');
    _validateExpression(action['arguments'], 'arguments', 0);
    return;
  }

  _validateKeys(action, const {'steps'});
  final rawSteps = action['steps'];
  if (rawSteps is! List) {
    throw const FormatException('Tool action "steps" must be a list.');
  }
  for (var i = 0; i < rawSteps.length; i++) {
    _validateStep(rawSteps[i], 'steps[$i]', 0);
  }
}

void _validateStep(Object? rawStep, String path, int depth) {
  if (depth > kChatToolMaxDepth) {
    throw StateError(
      'Tool recipe exceeded the maximum recursion depth of '
      '$kChatToolMaxDepth.',
    );
  }
  if (rawStep is! Map) {
    throw FormatException('Tool recipe step at $path must be an object.');
  }
  final step = <String, Object?>{
    for (final entry in rawStep.entries) entry.key.toString(): entry.value,
  };

  if (step.containsKey('let')) {
    _validateKeys(step, const {'let', 'value'});
    _validateVariable(step['let'], '$path.let');
    _validateExpression(step['value'], '$path.value', depth + 1);
    return;
  }
  if (step.containsKey('call')) {
    _validateKeys(step, const {'id', 'call', 'arguments'});
    if (step.containsKey('id')) {
      _validateVariable(step['id'], '$path.id');
    }
    _validateOperation(step['call'], '$path.call');
    _validateExpression(step['arguments'], '$path.arguments', depth + 1);
    return;
  }
  if (step.containsKey('if')) {
    _validateKeys(step, const {'if', 'then', 'else'});
    _validateExpression(step['if'], '$path.if', depth + 1);
    if (step['then'] is! List) {
      throw FormatException('Tool recipe "then" at $path must be a list.');
    }
    if (step.containsKey('else') && step['else'] is! List) {
      throw FormatException('Tool recipe "else" at $path must be a list.');
    }
    for (var i = 0; i < (step['then'] as List).length; i++) {
      _validateStep((step['then'] as List)[i], '$path.then[$i]', depth + 1);
    }
    if (step.containsKey('else')) {
      for (var i = 0; i < (step['else'] as List).length; i++) {
        _validateStep((step['else'] as List)[i], '$path.else[$i]', depth + 1);
      }
    }
    return;
  }
  if (step.containsKey('return')) {
    _validateKeys(step, const {'return'});
    _validateExpression(step['return'], '$path.return', depth + 1);
    return;
  }

  throw FormatException(
    'Tool recipe step at $path must be one of "let", "call", "if" or '
    '"return".',
  );
}

void _validateExpression(Object? expression, String path, int depth) {
  if (depth > kChatToolMaxDepth) {
    throw StateError(
      'Tool recipe exceeded the maximum recursion depth of '
      '$kChatToolMaxDepth.',
    );
  }

  if (expression is Map) {
    final map = <String, Object?>{
      for (final entry in expression.entries) entry.key.toString(): entry.value,
    };
    if (_hasOnly(map, const {'ref'})) {
      if (map['ref'] is! String) {
        throw FormatException('Tool recipe "ref" at $path must be a string.');
      }
      _validateReference(map['ref'] as String, path);
      return;
    }
    if (_hasOnly(map, const {'op', 'values'})) {
      if (map['op'] is! String) {
        throw FormatException('Tool recipe "op" at $path must be a string.');
      }
      if (!_kOperators.contains(map['op'])) {
        throw FormatException(
          'Unknown tool recipe operator "${map['op']}" at $path.',
        );
      }
      if (map['values'] is! List) {
        throw FormatException('Tool recipe "values" at $path must be a list.');
      }
      for (var i = 0; i < (map['values'] as List).length; i++) {
        _validateExpression(
          (map['values'] as List)[i],
          '$path.values[$i]',
          depth + 1,
        );
      }
      return;
    }
    if (_hasOnly(map, const {'template'})) {
      if (map['template'] is! String) {
        throw FormatException(
          'Tool recipe "template" at $path must be a string.',
        );
      }
      for (final match in _kTemplateRefPattern.allMatches(
        map['template'] as String,
      )) {
        _validateReference(match.group(0)!.substring(1), path);
      }
      return;
    }

    for (final entry in map.entries) {
      _validateExpression(entry.value, '$path.${entry.key}', depth + 1);
    }
    return;
  }
  if (expression is List) {
    for (var i = 0; i < expression.length; i++) {
      _validateExpression(expression[i], '$path[$i]', depth + 1);
    }
    return;
  }
  if (expression == null ||
      expression is bool ||
      expression is String ||
      expression is num && expression.isFinite) {
    return;
  }
  throw FormatException('Tool recipe value at $path is not JSON-safe.');
}

void _validateReference(String ref, String path) {
  final parts = ref.split('.');
  if (parts.length < 2 || parts.any((part) => part.isEmpty)) {
    throw FormatException('Malformed tool recipe reference "$ref" at $path.');
  }
  final root = parts[0];
  if (root != 'args' && root != 'vars') {
    throw FormatException(
      'Tool recipe reference "$ref" at $path must start with "args" or '
      '"vars".',
    );
  }
}

void _validateKeys(Map<String, Object?> value, Set<String> allowed) {
  final unknown = value.keys.where((key) => !allowed.contains(key)).toList();
  if (unknown.isNotEmpty) {
    throw FormatException(
      'Unknown tool recipe ${unknown.length == 1 ? 'key' : 'keys'}: '
      '${unknown.join(', ')}.',
    );
  }
}

void _validateOperation(Object? value, String path) {
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Tool operation at $path must be a non-empty name.');
  }
}

void _validateVariable(Object? value, String path) {
  if (value is! String || !_kVariablePattern.hasMatch(value)) {
    throw FormatException(
      'Tool variable at $path must be letters, digits or underscores and '
      'start with a letter or underscore.',
    );
  }
}

Map<String, dynamic> _expectMap(Object? value, String description) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) {
    return {
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  throw FormatException('$description must be a JSON object.');
}

bool _expectBool(Object? value, String description) =>
    _expectBoolValue(value, description);

bool _expectBoolValue(Object? value, String description) {
  if (value is bool) return value;
  throw FormatException('$description must be a boolean.');
}

num _number(Object? value, String description) {
  if (value is num && value.isFinite) return value;
  throw FormatException('$description must be a finite number.');
}

bool _hasOnly(Map<String, Object?> value, Set<String> keys) {
  return value.length == keys.length && value.keys.every(keys.contains);
}

Object? _cloneJson(Object? value) {
  if (value == null) return null;
  final decoded = jsonDecode(jsonEncode(value));
  if (value is Map) {
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  }
  return decoded;
}

void _validateJson(Object? value, String path) {
  void visit(Object? value, String path, int depth) {
    if (depth > kChatToolMaxDepth) {
      throw StateError(
        'Tool data exceeded the maximum recursion depth of '
        '$kChatToolMaxDepth.',
      );
    }
    if (value == null || value is bool || value is String) return;
    if (value is num) {
      if (!value.isFinite) {
        throw FormatException('Number at $path is not finite.');
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          throw FormatException('Map key at $path must be a string.');
        }
        visit(entry.value, '$path.${entry.key}', depth + 1);
      }
      return;
    }
    if (value is List) {
      for (var i = 0; i < value.length; i++) {
        visit(value[i], '$path[$i]', depth + 1);
      }
      return;
    }
    throw FormatException('Value at $path is not JSON-safe.');
  }

  visit(value, path, 0);
}

bool _jsonEqual(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is num && b is num) {
    if (!a.isFinite || !b.isFinite) return false;
    return a == b;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key)) return false;
      if (!_jsonEqual(entry.value, b[entry.key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a.runtimeType == b.runtimeType && a == b;
}

const Set<String> _kOperators = {
  '+',
  '-',
  '*',
  '/',
  '==',
  '!=',
  '<',
  '<=',
  '>',
  '>=',
  'and',
  'or',
  'not',
};

/// Validates model-supplied arguments against the subset of JSON Schema used
/// by MaiChat tool definitions.
///
/// Unknown schema keywords are ignored so future-compatible definitions can
/// still be loaded. Known keywords, however, must be well formed; malformed
/// definitions fail rather than silently accepting every value.
void validateChatToolRecipe(Map<String, dynamic> action) =>
    _validateAction(action);

void validateChatToolSchema(Map<String, dynamic> schema) =>
    _validateSchema(schema, 'schema', 0);

void validateChatToolArguments(
  Map<String, dynamic> schema,
  Map<String, dynamic> arguments,
) {
  _validateJson(schema, 'schema');
  _validateSchema(schema, 'schema', 0);
  _validateAgainstSchema(schema, arguments, 'arguments', 0);
}

void _validateSchema(Map<String, dynamic> schema, String path, int depth) {
  if (depth > kChatToolMaxDepth) {
    throw StateError(
      'Tool schema exceeded the maximum recursion depth of '
      '$kChatToolMaxDepth.',
    );
  }

  final type = schema['type'];
  if (type != null && (type is! String || !_kSchemaTypes.contains(type))) {
    throw FormatException(
      'Unknown JSON Schema type at $path.type: expected one of '
      '${_kSchemaTypes.join(', ')}.',
    );
  }

  final properties = schema['properties'];
  if (properties != null && properties is! Map) {
    throw FormatException(
      'JSON Schema "properties" at $path.properties must be an object.',
    );
  }
  if (properties is Map) {
    for (final entry in properties.entries) {
      final child = entry.value;
      if (child is! Map) {
        throw FormatException(
          'Schema for property "${entry.key}" at '
          '$path.properties.${entry.key} must be an object.',
        );
      }
      _validateSchema(
        Map<String, dynamic>.from(child),
        '$path.properties.${entry.key}',
        depth + 1,
      );
    }
  }

  final required = schema['required'];
  if (required != null) {
    if (required is! List || required.any((value) => value is! String)) {
      throw FormatException(
        'JSON Schema "required" at $path.required must be a list of strings.',
      );
    }
    final names = required.cast<String>();
    if (names.length != names.toSet().length) {
      throw FormatException(
        'JSON Schema "required" at $path.required contains duplicate names.',
      );
    }
  }

  final additional = schema['additionalProperties'];
  if (additional != null && additional is! bool && additional is! Map) {
    throw FormatException(
      'JSON Schema "additionalProperties" at '
      '$path.additionalProperties must be a boolean or schema.',
    );
  }
  if (additional is Map) {
    _validateSchema(
      Map<String, dynamic>.from(additional),
      '$path.additionalProperties',
      depth + 1,
    );
  }

  final items = schema['items'];
  if (items != null && items is! Map) {
    throw FormatException(
      'JSON Schema "items" at $path.items must be a schema object.',
    );
  }
  if (items is Map) {
    _validateSchema(Map<String, dynamic>.from(items), '$path.items', depth + 1);
  }

  final enumValue = schema['enum'];
  if (enumValue != null) {
    if (enumValue is! List || (enumValue).isEmpty) {
      throw FormatException(
        'JSON Schema "enum" at $path.enum must be a non-empty list.',
      );
    }
    for (var i = 0; i < (enumValue).length; i++) {
      _validateJson((enumValue)[i], '$path.enum[$i]');
    }
  }

  _validateBound(schema['minimum'], 'minimum', path, allowNegative: true);
  _validateBound(schema['maximum'], 'maximum', path, allowNegative: true);
  _validateBound(schema['minLength'], 'minLength', path);
  _validateBound(schema['maxLength'], 'maxLength', path);
  _validateBound(schema['maxItems'], 'maxItems', path);

  final minimum = schema['minimum'];
  final maximum = schema['maximum'];
  if (minimum is num && maximum is num && minimum > maximum) {
    throw FormatException(
      'JSON Schema minimum is greater than maximum at $path.',
    );
  }
  final minLength = schema['minLength'];
  final maxLength = schema['maxLength'];
  if (minLength is int && maxLength is int && minLength > maxLength) {
    throw FormatException(
      'JSON Schema minLength is greater than maxLength at $path.',
    );
  }
}

void _validateBound(
  Object? value,
  String keyword,
  String path, {
  bool allowNegative = false,
}) {
  if (value == null) return;
  if (value is! num || !value.isFinite) {
    throw FormatException(
      'JSON Schema "$keyword" at $path.$keyword must be a finite number.',
    );
  }
  if (!allowNegative && value < 0) {
    throw FormatException(
      'JSON Schema "$keyword" at $path.$keyword must not be negative.',
    );
  }
}

void _validateAgainstSchema(
  Map<String, dynamic> schema,
  Object? value,
  String path,
  int depth,
) {
  if (depth > kChatToolMaxDepth) {
    throw StateError(
      'Tool schema exceeded the maximum recursion depth of '
      '$kChatToolMaxDepth.',
    );
  }
  _validateJson(value, path);

  final enumValue = schema['enum'];
  if (enumValue is List && !enumValue.any((v) => _jsonEqual(v, value))) {
    throw FormatException(
      'Value at $path must be one of the allowed enum values.',
    );
  }

  switch (schema['type'] as String?) {
    case null:
      break;
    case 'object':
      if (value is! Map) {
        throw FormatException('Value at $path must be an object.');
      }
      break;
    case 'array':
      if (value is! List) {
        throw FormatException('Value at $path must be an array.');
      }
      break;
    case 'string':
      if (value is! String) {
        throw FormatException('Value at $path must be a string.');
      }
      break;
    case 'boolean':
      if (value is! bool) {
        throw FormatException('Value at $path must be a boolean.');
      }
      break;
    case 'null':
      if (value != null) {
        throw FormatException('Value at $path must be null.');
      }
      break;
    case 'number':
      if (value is! num || !value.isFinite) {
        throw FormatException('Value at $path must be a finite number.');
      }
      break;
    case 'integer':
      if (value is! num ||
          !value.isFinite ||
          value != value.truncateToDouble()) {
        throw FormatException('Value at $path must be an integer.');
      }
      break;
  }

  if (value is num) {
    final minimum = schema['minimum'];
    if (minimum is num && value < minimum) {
      throw FormatException('Value at $path must be at least $minimum.');
    }
    final maximum = schema['maximum'];
    if (maximum is num && value > maximum) {
      throw FormatException('Value at $path must be at most $maximum.');
    }
  }

  if (value is String) {
    final minLength = schema['minLength'];
    if (minLength is int && value.length < minLength) {
      throw FormatException(
        'Value at $path must be at least $minLength characters long.',
      );
    }
    final maxLength = schema['maxLength'];
    if (maxLength is int && value.length > maxLength) {
      throw FormatException(
        'Value at $path must be at most $maxLength characters long.',
      );
    }
  }

  if (schema['type'] == 'object' && value is Map) {
    final required = schema['required'];
    if (required is List) {
      for (final name in required) {
        if (name is String && !value.containsKey(name)) {
          throw FormatException('Missing required property "$name" at $path.');
        }
      }
    }

    final properties = schema['properties'];
    if (properties is Map) {
      for (final entry in value.entries) {
        final property = properties[entry.key];
        if (property is Map) {
          _validateAgainstSchema(
            Map<String, dynamic>.from(property),
            entry.value,
            '$path.${entry.key}',
            depth + 1,
          );
        }
      }
    }

    final additional = schema['additionalProperties'];
    if (additional is bool && !additional) {
      final properties = schema['properties'];
      final known = properties is Map
          ? properties.keys.map((key) => key.toString()).toSet()
          : const <String>{};
      for (final key in value.keys) {
        if (!known.contains(key)) {
          throw FormatException(
            'Unknown property "$key" at $path is not allowed.',
          );
        }
      }
    } else if (additional is Map) {
      for (final entry in value.entries) {
        _validateAgainstSchema(
          Map<String, dynamic>.from(additional),
          entry.value,
          '$path.${entry.key}',
          depth + 1,
        );
      }
    }
  }

  if (schema['type'] == 'array' && value is List) {
    final maxItems = schema['maxItems'];
    if (maxItems is int && value.length > maxItems) {
      throw FormatException(
        'Value at $path must contain at most $maxItems items.',
      );
    }
    final items = schema['items'];
    if (items is Map) {
      for (var i = 0; i < value.length; i++) {
        _validateAgainstSchema(
          Map<String, dynamic>.from(items),
          value[i],
          '$path[$i]',
          depth + 1,
        );
      }
    }
  }
}

/// Rolls dice from a compact formula: `NdM`, `dM`, `NdM+K`, `NdM-K`, or a
/// bare integer (which means one die with that many sides).
///
/// Bounds are checked before any rolls occur, and [random] — when supplied —
/// is the application's chosen source of randomness.
Map<String, dynamic> rollChatDice(String formula, {Random? random}) {
  final text = formula.trim();
  const maxCount = 100;
  const maxSides = 1000000;
  const maxModifier = 1000000;

  var count = 1;
  var sides = 0;
  var modifier = 0;
  var bare = false;

  final diceMatch = RegExp(
    r'^([0-9]{1,3})?d([0-9]{1,7})(?:([+-])([0-9]{1,7}))?$',
  ).firstMatch(text);
  if (diceMatch != null) {
    final countText = diceMatch.group(1);
    if (countText != null) count = int.parse(countText);
    sides = int.parse(diceMatch.group(2)!);
    if (diceMatch.group(3) != null) {
      modifier = int.parse(diceMatch.group(4)!);
      if (diceMatch.group(3) == '-') modifier = -modifier;
    }
  } else if (RegExp(r'^[0-9]{1,7}$').hasMatch(text)) {
    bare = true;
    sides = int.parse(text);
  } else {
    throw FormatException(
      'Invalid dice formula "$formula"; expected NdM, dM, NdM+K or a bare '
      'integer.',
    );
  }

  if (count < 1 || sides < 1) {
    throw FormatException(
      'Dice formula "$formula" is outside its supported bounds.',
    );
  }
  if (count > maxCount || sides > maxSides || modifier.abs() > maxModifier) {
    throw FormatException(
      'Dice formula "$formula" exceeds count, sides or modifier limits.',
    );
  }

  final rng = random ?? Random();
  final rolls = <int>[];
  var total = modifier;
  for (var i = 0; i < count; i++) {
    final roll = rng.nextInt(sides) + 1;
    rolls.add(roll);
    total += roll;
  }

  return {
    'formula': text,
    'rolls': rolls,
    'modifier': modifier,
    'total': total,
    if (bare) 'normalizedFormula': '1d$text',
  };
}

const Set<String> _kSchemaTypes = {
  'object',
  'array',
  'string',
  'boolean',
  'null',
  'number',
  'integer',
};
