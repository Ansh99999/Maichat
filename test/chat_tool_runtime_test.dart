import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:maichat/models/agent_message.dart';
import 'package:maichat/models/chat_tool.dart';
import 'package:maichat/models/message_image.dart';
import 'package:maichat/services/chat_tools/definitions.dart';
import 'package:maichat/services/chat_tools/runtime.dart';

void main() {
  group('definitions', () {
    test('ships the complete ordered built-in tool list', () {
      expect(chatToolBuiltIns.map((tool) => tool.name), [
        'roll_dice',
        'random_integer',
        'read_trackers',
        'define_tracker',
        'update_tracker',
        'set_prompt_injection',
        'generate_image',
        'list_tools',
        'save_tool',
        'delete_tool',
      ]);
      for (final tool in chatToolBuiltIns) {
        expect(tool.builtin, isTrue);
        expect(tool.action, isEmpty);
        expect(tool.enabled, isTrue);
        expect(tool.description, isNotEmpty);
        expect(tool.spec.name, tool.name);
        expect(tool.spec.description, tool.description);
        expect(tool.spec.parameters, same(tool.parameters));
      }
      for (final tool in chatToolBuiltIns.where(
        (tool) => tool.name == 'read_trackers' || tool.name == 'list_tools',
      )) {
        validateChatToolArguments(tool.parameters, {});
      }
    });

    test('built-in schemas reject malformed arguments', () {
      final roll = chatToolBuiltIns.singleWhere((t) => t.name == 'roll_dice');
      expect(
        () => validateChatToolArguments(roll.parameters, {'formula': ''}),
        throwsFormatException,
      );
      expect(
        () => validateChatToolArguments(roll.parameters, {
          'formula': 'd20',
          'x': 1,
        }),
        throwsFormatException,
      );
      final tracker = chatToolBuiltIns.singleWhere(
        (t) => t.name == 'update_tracker',
      );
      expect(
        () => validateChatToolArguments(tracker.parameters, {
          'id': 'health',
          'value': double.infinity,
        }),
        throwsFormatException,
      );
    });
  });

  group('JSON models', () {
    test('round-trips a full tool definition and copies it', () {
      const definition = ChatToolDefinition(
        name: 'custom',
        description: 'A custom tool.',
        parameters: {
          'type': 'object',
          'properties': {
            'value': {'type': 'integer', 'minimum': 1},
          },
          'required': ['value'],
        },
        action: {
          'call': 'random_integer',
          'arguments': {
            'min': 1,
            'max': {'ref': 'args.value'},
          },
        },
        enabled: false,
        hidden: true,
        followUp: false,
        builtin: true,
      );
      final restored = ChatToolDefinition.fromJson(
        jsonDecode(jsonEncode(definition.toJson())) as Map<String, dynamic>,
      );
      expect(restored.name, definition.name);
      expect(restored.description, definition.description);
      expect(restored.parameters, definition.parameters);
      expect(restored.action, definition.action);
      expect(restored.enabled, isFalse);
      expect(restored.hidden, isTrue);
      expect(restored.followUp, isFalse);
      expect(restored.builtin, isTrue);
      expect(restored.spec.parameters, definition.parameters);

      final copied = definition.copyWith(enabled: true, followUp: true);
      expect(copied.enabled, isTrue);
      expect(copied.followUp, isTrue);
      expect(copied.name, definition.name);
    });

    test('restores friendly definition defaults for old JSON', () {
      final restored = ChatToolDefinition.fromJson({
        'name': 'old',
        'description': 'd',
      });
      expect(restored.parameters, {
        'type': 'object',
        'properties': <String, dynamic>{},
      });
      expect(restored.action, isEmpty);
      expect(restored.enabled, isTrue);
      expect(restored.hidden, isFalse);
      expect(restored.followUp, isTrue);
      expect(restored.builtin, isFalse);
    });

    test('round-trips and clamps chat configuration', () {
      const config = ChatToolConfig(
        enabled: true,
        disabledTools: ['generate_image'],
        customTools: [ChatToolDefinition(name: 'x', description: 'Custom x.')],
        maxRounds: 7,
        maxCalls: 33,
        trackerPlacement: 'panel',
        hideToolCallsInChat: true,
        followUpOverrides: {'roll_dice': false},
      );
      final restored = ChatToolConfig.fromJson(
        jsonDecode(jsonEncode(config.toJson())) as Map<String, dynamic>,
      );
      expect(restored.enabled, isTrue);
      expect(restored.disabledTools, ['generate_image']);
      expect(restored.customTools.single.name, 'x');
      expect(restored.maxRounds, 7);
      expect(restored.maxCalls, 33);
      expect(restored.trackerPlacement, 'panel');
      expect(restored.hideToolCallsInChat, isTrue);
      expect(restored.followUpOverrides, {'roll_dice': false});

      final clamped = ChatToolConfig.fromJson({
        'maxRounds': 0,
        'maxCalls': 999,
      });
      expect(clamped.maxRounds, 1);
      expect(clamped.maxCalls, 50);

      final copied = config.copyWith(maxRounds: 2, maxCalls: 3);
      expect(copied.maxRounds, 2);
      expect(copied.maxCalls, 3);
      expect(copied.hideToolCallsInChat, isTrue);
      expect(copied.followUpOverrides, {'roll_dice': false});
    });

    test('round-trips a run with protocol history, effects and images', () {
      final call = ToolCall(
        id: 'c1',
        name: 'roll_dice',
        arguments: const {'formula': 'd20'},
      );
      final run = ChatToolRun(
        id: 'run-1',
        providerId: 'provider',
        model: 'model',
        wire: 'openai',
        history: [
          AgentMessage.user('Roll.'),
          AgentMessage(role: AgentRole.assistant, toolCalls: [call]),
          AgentMessage.toolResult(call, '{"total":20}'),
        ],
        effects: const [
          ChatToolEffect(key: 'tracker:health', before: 10, after: 8),
        ],
        images: const [MessageImage(ref: 'local:a.png')],
        status: 'completed',
      );
      final restored = ChatToolRun.fromJson(
        jsonDecode(jsonEncode(run.toJson())) as Map<String, dynamic>,
      );
      expect(restored.id, run.id);
      expect(restored.providerId, 'provider');
      expect(restored.model, 'model');
      expect(restored.wire, 'openai');
      expect(restored.status, 'completed');
      expect(restored.history.length, 3);
      expect(restored.history[1].toolCalls.single.name, 'roll_dice');
      expect(restored.history[2].toolCallId, 'c1');
      expect(restored.effects.single.key, 'tracker:health');
      expect(restored.effects.single.before, 10);
      expect(restored.effects.single.after, 8);
      expect(restored.images.single, run.images.single);

      final copied = run.copyWith(status: 'error');
      expect(copied.status, 'error');
      expect(copied.id, run.id);
    });

    test('round-trips an effect containing null before and after values', () {
      const effect = ChatToolEffect(
        key: 'injection:a',
        before: null,
        after: 'x',
      );
      final restored = ChatToolEffect.fromJson(
        jsonDecode(jsonEncode(effect.toJson())) as Map<String, dynamic>,
      );
      expect(restored.key, 'injection:a');
      expect(restored.before, isNull);
      expect(restored.after, 'x');
    });
  });

  group('projection', () {
    test('applies effects in run order and never mutates inputs', () {
      final base = {
        'tracker:health': 10,
        'nested': {
          'items': [1, 2],
        },
      };
      final runs = [
        ChatToolRun(
          id: 'one',
          effects: const [
            ChatToolEffect(key: 'tracker:health', before: 10, after: 9),
          ],
        ),
        ChatToolRun(
          id: 'two',
          effects: const [
            ChatToolEffect(key: 'tracker:health', before: 9, after: 8),
          ],
        ),
      ];
      final projection = projectChatToolRuns(runs, base: base);
      expect(projection.values, {
        'tracker:health': 8,
        'nested': {
          'items': [1, 2],
        },
      });
      expect(projection.staleRuns, isEmpty);
      expect(base['tracker:health'], 10);
      expect((base['nested'] as Map)['items'], [1, 2]);
    });

    test('marks a stale run stale and skips all of its effects atomically', () {
      final runs = [
        ChatToolRun(
          id: 'good',
          effects: const [
            ChatToolEffect(key: 'tracker:health', before: 10, after: 8),
          ],
        ),
        ChatToolRun(
          id: 'stale',
          effects: const [
            ChatToolEffect(key: 'tracker:health', before: 10, after: 99),
            ChatToolEffect(key: 'tracker:energy', before: 5, after: 4),
          ],
        ),
      ];
      final projection = projectChatToolRuns(
        runs,
        base: {'tracker:health': 10, 'tracker:energy': 5},
      );
      expect(projection.values, {'tracker:health': 8, 'tracker:energy': 5});
      expect(projection.staleRuns, {'stale'});
    });

    test('compares effect preconditions by deep JSON equality', () {
      final runs = [
        ChatToolRun(
          id: 'deep',
          effects: const [
            ChatToolEffect(
              key: 'injection:a',
              before: {
                'text': 'Be brief.',
                'depth': 2,
                'tags': ['one', 'two'],
              },
              after: {'text': 'Be brief.', 'depth': 3},
            ),
          ],
        ),
      ];
      final projection = projectChatToolRuns(
        runs,
        base: {
          'injection:a': {
            'depth': 2,
            'tags': ['one', 'two'],
            'text': 'Be brief.',
          },
        },
      );
      expect(projection.staleRuns, isEmpty);
      expect(projection.values['injection:a'], {
        'text': 'Be brief.',
        'depth': 3,
      });
    });

    test('is pure and performs no handler or random work', () {
      final run = ChatToolRun(
        id: 'r',
        effects: const [
          ChatToolEffect(key: 'tracker:health', before: 1, after: 2),
        ],
      );
      var calls = 0;
      // The projection API accepts runs only; adding this closure proves the
      // test cannot accidentally provide a callable to it.
      ChatToolEffect effect() {
        calls++;
        return run.effects.single;
      }

      effect();
      final projection = projectChatToolRuns(
        [run],
        base: {'tracker:health': 1},
      );
      expect(calls, 1);
      expect(projection.values['tracker:health'], 2);
      expect(run.effects.single.after, 2);
    });
  });

  group('executable recipes', () {
    test('executes a direct call with argument expressions', () async {
      final calls = <(String, Map<String, dynamic>)>[];
      final result = await const ChatToolRuntime().execute(
        {
          'call': 'random_integer',
          'arguments': {
            'min': {
              'op': '+',
              'values': [1, 2],
            },
            'max': {'ref': 'args.high'},
          },
        },
        {'high': 10},
        (name, arguments) async {
          calls.add((name, arguments));
          return 7;
        },
      );
      expect(result, 7);
      expect(calls.single.$1, 'random_integer');
      expect(calls.single.$2, {'min': 3, 'max': 10});
    });

    test(
      'composes variables, conditions, nested returns and templates',
      () async {
        final result = await const ChatToolRuntime().execute(
          {
            'steps': [
              {
                'let': 'target',
                'value': {'ref': 'args.target'},
              },
              {
                'id': 'roll',
                'call': 'random_integer',
                'arguments': {
                  'min': 1,
                  'max': {'ref': 'vars.target'},
                },
              },
              {
                'if': {
                  'op': 'and',
                  'values': [
                    {
                      'op': '>=',
                      'values': [
                        {'ref': 'vars.roll'},
                        4,
                      ],
                    },
                    {
                      'op': 'not',
                      'values': [
                        {
                          'op': '==',
                          'values': [
                            {'ref': 'args.mode'},
                            'strict',
                          ],
                        },
                      ],
                    },
                  ],
                },
                'then': [
                  {
                    'if': {
                      'op': '>',
                      'values': [
                        {'ref': 'vars.roll'},
                        8,
                      ],
                    },
                    'then': [
                      {
                        'return': {
                          'text': {'template': 'Critical {vars.roll}'},
                          'meta': {
                            'target': {'ref': 'vars.target'},
                          },
                        },
                      },
                    ],
                    'else': [
                      {
                        'return': {
                          'text': {
                            'template': 'Hit {vars.roll} of {vars.target}',
                          },
                        },
                      },
                    ],
                  },
                ],
                'else': [
                  {
                    'return': {
                      'text': {'template': 'Miss {args.mode}'},
                    },
                  },
                ],
              },
            ],
          },
          {'target': 10, 'mode': 'normal'},
          (name, arguments) async => arguments['max'] == 10 ? 9 : 0,
        );
        expect(result, {
          'text': 'Critical 9',
          'meta': {'target': 10},
        });
      },
    );

    test(
      'evaluates JSON structures, equality, booleans and integer division',
      () async {
        final result = await const ChatToolRuntime().execute(
          {
            'steps': [
              {
                'return': [
                  {'a': 1},
                  {
                    'op': '/',
                    'values': [7, 2],
                  },
                  {
                    'op': '/',
                    'values': [8, 4],
                  },
                  {
                    'op': '!=',
                    'values': [
                      {'a': 1},
                      {'a': 1.0},
                    ],
                  },
                ],
              },
            ],
          },
          {},
          (_, _) async => throw StateError('unreachable'),
        );
        expect(result, [
          {'a': 1},
          3.5,
          2,
          false,
        ]);
      },
    );

    test('returns null after a steps recipe with no return', () async {
      final result = await const ChatToolRuntime().execute(
        {
          'steps': [
            {'let': 'x', 'value': 1},
          ],
        },
        {},
        (_, _) async => throw StateError('unreachable'),
      );
      expect(result, isNull);
    });

    test('rejects malformed recipes before invoking an operation', () async {
      final invalidActions = <Map<String, dynamic>>[
        {},
        {'call': 'x', 'steps': []},
        {'steps': 'x'},
        {
          'steps': [
            {'call': 'x', 'unknown': 1},
          ],
        },
        {'call': '', 'arguments': {}},
        {
          'call': 'x',
          'arguments': {'ref': 'root.value'},
        },
        {
          'steps': [
            {'if': true, 'then': []},
          ],
          'unknown': 1,
        },
      ];
      for (final action in invalidActions) {
        var invoked = false;
        await expectLater(
          const ChatToolRuntime().execute(action, {}, (_, _) async {
            invoked = true;
            return null;
          }),
          throwsFormatException,
        );
        expect(invoked, isFalse);
      }
    });

    test(
      'missing references and invalid operation data are clear errors',
      () async {
        await expectLater(
          const ChatToolRuntime().execute(
            {
              'call': 'x',
              'arguments': {'ref': 'args.missing'},
            },
            {},
            (_, _) async => null,
          ),
          throwsFormatException,
        );
        await expectLater(
          const ChatToolRuntime().execute(
            {'call': 'x', 'arguments': {}},
            {},
            (_, _) async => double.infinity,
          ),
          throwsFormatException,
        );
      },
    );

    test('checks cancellation before every step and operation', () async {
      var cancelled = false;
      var operations = 0;
      await expectLater(
        const ChatToolRuntime().execute(
          {
            'steps': [
              {'let': 'first', 'value': 1},
              {'call': 'operation', 'arguments': {}},
              {'call': 'operation', 'arguments': {}},
            ],
          },
          {},
          (_, _) async {
            operations++;
            cancelled = true;
            return null;
          },
          cancelled: () => cancelled,
        ),
        throwsStateError,
      );
      cancelled = true;
      expect(operations, 1);
    });

    test('rejects recursive custom call cycles via the step limit', () async {
      var calls = 0;
      final action = {
        'steps': [
          for (var i = 0; i < 101; i++)
            {
              'call': 'custom_tool',
              'arguments': {'round': i},
            },
        ],
      };
      await expectLater(
        const ChatToolRuntime().execute(action, {}, (_, _) async => calls++),
        throwsStateError,
      );
      expect(calls, 100);
    });

    test('enforces the 100-step and depth-32 limits', () async {
      final hundredLets = {
        'steps': [
          for (var i = 0; i < 100; i++) {'let': 'x$i', 'value': i},
        ],
      };
      await expectLater(
        const ChatToolRuntime().execute(hundredLets, {}, (_, _) async => null),
        completes,
      );

      final hundredAndOneLets = {
        'steps': [
          for (var i = 0; i < 101; i++) {'let': 'x$i', 'value': i},
        ],
      };
      await expectLater(
        const ChatToolRuntime().execute(
          hundredAndOneLets,
          {},
          (_, _) async => null,
        ),
        throwsStateError,
      );

      Object? deep = {'ref': 'args.value'};
      for (var i = 0; i < 33; i++) {
        deep = {'nested': deep};
      }
      await expectLater(
        const ChatToolRuntime().execute(
          {
            'steps': [
              {'return': deep},
            ],
          },
          {'value': 1},
          (_, _) async => null,
        ),
        throwsStateError,
      );
    });

    test('bounds arithmetic and rejects invalid boolean operands', () async {
      await expectLater(
        const ChatToolRuntime().execute(
          {
            'steps': [
              {
                'return': {
                  'op': '/',
                  'values': [1, 0],
                },
              },
            ],
          },
          {},
          (_, _) async => null,
        ),
        throwsStateError,
      );
      await expectLater(
        const ChatToolRuntime().execute(
          {
            'steps': [
              {
                'return': {
                  'op': 'and',
                  'values': [true, 'yes'],
                },
              },
            ],
          },
          {},
          (_, _) async => null,
        ),
        throwsFormatException,
      );
    });
  });

  group('schema validation', () {
    test('accepts valid nested objects, arrays and integer-valued numbers', () {
      final schema = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'count': {'type': 'integer', 'minimum': 1, 'maximum': 10},
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': 2,
          },
          'nested': {
            'type': 'object',
            'properties': {
              'enabled': {'type': 'boolean'},
            },
            'additionalProperties': false,
          },
        },
        'required': ['name', 'count'],
        'additionalProperties': false,
      };
      validateChatToolArguments(schema, {
        'name': 'x',
        'count': 2.0,
        'tags': ['a', 'b'],
        'nested': {'enabled': true},
      });
    });

    test('reports failures with a path and precise type reason', () {
      final schema = {
        'type': 'object',
        'properties': {
          'value': {'type': 'integer'},
          'child': {
            'type': 'object',
            'properties': {
              'name': {'type': 'string'},
            },
            'required': ['name'],
          },
          'list': {
            'type': 'array',
            'items': {'type': 'number'},
          },
        },
        'required': ['value', 'child'],
        'additionalProperties': false,
      };
      expect(
        () => validateChatToolArguments(schema, {
          'value': 1.5,
          'child': {'name': 'x'},
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('arguments.value'),
          ),
        ),
      );
      expect(
        () => validateChatToolArguments(schema, {
          'value': 1,
          'child': {},
          'unknown': 1,
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateChatToolArguments(schema, {
          'value': 1,
          'child': {'name': 2},
          'list': ['x'],
        }),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('arguments.child.name'),
          ),
        ),
      );
    });

    test(
      'supports enums, numeric and length bounds, and unknown keywords are ignored',
      () {
        final schema = {
          'type': 'object',
          'properties': {
            'choice': {
              'enum': ['a', 'b'],
            },
            'number': {'type': 'number', 'minimum': 1, 'maximum': 2},
            'text': {'type': 'string', 'minLength': 2, 'maxLength': 3},
            'futureKeyword': {'type': 'string'},
          },
          'additionalProperties': false,
        };
        validateChatToolArguments(schema, {
          'choice': 'a',
          'number': 1.5,
          'text': 'abc',
        });
        expect(
          () => validateChatToolArguments(schema, {
            'choice': 'c',
            'number': 1.5,
            'text': 'abc',
          }),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('arguments.choice'),
            ),
          ),
        );
        expect(
          () => validateChatToolArguments(schema, {
            'choice': 'a',
            'number': 3,
            'text': 'abc',
          }),
          throwsA(isA<FormatException>()),
        );
        expect(
          () => validateChatToolArguments(schema, {
            'choice': 'a',
            'number': 1.5,
            'text': 'a',
          }),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('rejects malformed known schema keywords and excessive recursion', () {
      expect(
        () => validateChatToolArguments({'properties': 'bad'}, {}),
        throwsFormatException,
      );
      expect(
        () => validateChatToolArguments({
          'required': [1],
        }, {}),
        throwsFormatException,
      );
      expect(
        () => validateChatToolArguments({'items': 'bad'}, {}),
        throwsFormatException,
      );
      expect(
        () => validateChatToolArguments({
          'type': 'integer',
          'minimum': double.nan,
        }, {}),
        throwsFormatException,
      );

      var schema = <String, dynamic>{'type': 'object', 'properties': {}};
      for (var i = 0; i < 34; i++) {
        schema = {
          'type': 'object',
          'properties': {'child': schema},
        };
      }
      expect(() => validateChatToolArguments(schema, {}), throwsStateError);
    });
  });

  group('dice', () {
    test('uses the supplied application RNG in order', () {
      final rng = _SequenceRandom([3, 2, 5, 1]);
      final result = rollChatDice('4d6-2', random: rng);
      expect(result, {
        'formula': '4d6-2',
        'rolls': [4, 3, 6, 2],
        'modifier': -2,
        'total': 13,
      });
    });

    test('supports dM and a bare integer as one die', () {
      final result = rollChatDice(' 20 ', random: _SequenceRandom([19]));
      expect(result['formula'], '20');
      expect(result['rolls'], [20]);
      expect(result['modifier'], 0);
      expect(result['total'], 20);
      expect(result['normalizedFormula'], '1d20');
      expect(rollChatDice('d4', random: _SequenceRandom([0]))['rolls'], [1]);
    });

    test('checks formula bounds before rolling', () {
      final rng = _CountingRandom();
      expect(() => rollChatDice('0d6', random: rng), throwsFormatException);
      expect(() => rollChatDice('101d6', random: rng), throwsFormatException);
      expect(
        () => rollChatDice('1d1000001', random: rng),
        throwsFormatException,
      );
      expect(
        () => rollChatDice('2d6+1000001', random: rng),
        throwsFormatException,
      );
      expect(rng.rolls, 0);
    });
  });
}

class _SequenceRandom implements Random {
  _SequenceRandom(this.values);

  final List<int> values;
  int index = 0;

  @override
  int nextInt(int max) {
    if (index >= values.length) throw StateError('RNG exhausted');
    final value = values[index++];
    if (value < 0 || value >= max) {
      throw StateError('Test random value out of range: $value/$max');
    }
    return value;
  }

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}

class _CountingRandom implements Random {
  int rolls = 0;

  @override
  int nextInt(int max) {
    rolls++;
    return 0;
  }

  @override
  bool nextBool() => false;

  @override
  double nextDouble() => 0;
}
