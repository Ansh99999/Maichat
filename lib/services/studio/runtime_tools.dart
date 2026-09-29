import '../../models/agent_message.dart';
import '../../models/studio.dart';
import 'studio_tools.dart';

/// What the runtime tools need from whoever runs the session: starting a
/// sub-agent without waiting for it, talking to one that is working, waiting
/// for some to finish, and the list of them. The Studio's controller is one;
/// tests fake it. Kept apart from [StudioServices] so the draft tools' seam is
/// untouched by any of it.
abstract class StudioRuntime {
  /// Starts (or, with [taskId], carries on) a sub-agent and returns at once,
  /// with it still running. Its report reaches the main agent later, as a
  /// note at a step boundary.
  Future<StudioTaskOutcome> startBackgroundTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  });

  /// Hands [message] to the sub-agent [taskId]: queued for its next step when
  /// it is working, or carrying it on in the background when it has
  /// finished. Returns what happened, or throws [StudioToolError].
  Future<Map<String, dynamic>> messageAgent(
    String taskId,
    String message, {
    String callId = '',
  });

  /// Waits until every one of [taskIds] has finished (all running sub-agents
  /// when empty), or [timeout] passes, or the run is stopped — whichever is
  /// first. Reports returned here are not delivered again as notes.
  Future<Map<String, dynamic>> waitForAgents(
    List<String> taskIds,
    Duration timeout,
  );

  /// Every sub-agent in the session, oldest first.
  List<StudioSubagent> get agents;

  /// How many messages wait for the sub-agent [taskId].
  int queuedFor(String taskId);
}

StudioRuntime _runtime(StudioToolContext ctx) {
  final services = ctx.services;
  if (services is StudioRuntime) return services as StudioRuntime;
  throw StudioToolError('Sub-agents are not available here.');
}

/// The longest one wait may last, in seconds.
const int kMaxWaitSeconds = 900;
const int kDefaultWaitSeconds = 300;

final StudioTool sendMessageTool = StudioTool(
  const ToolSpec(
    name: 'send_message',
    description: 'Sends a message to one of your sub-agents. If it is still '
        'working, the message is queued and it reads it at its next step — use '
        'this to redirect it, add a detail, or tell it to stop early. If it has '
        'finished, it carries on in the background with the message as its new '
        'instruction, and its next report reaches you as a note. It returns at '
        'once either way.',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': 'The sub-agent\'s task_id.'},
        'message': {'type': 'string'},
      },
      'required': ['task_id', 'message'],
    },
  ),
  (ctx, args) async {
    final id = (args['task_id'] ?? '').toString().trim();
    final message = (args['message'] ?? '').toString().trim();
    if (id.isEmpty) throw StudioToolError('"task_id" is required.');
    if (message.isEmpty) throw StudioToolError('"message" cannot be empty.');
    return StudioToolResult.json(
      await _runtime(ctx).messageAgent(id, message, callId: ctx.call?.id ?? ''),
    );
  },
);

final StudioTool waitAgentsTool = StudioTool(
  const ToolSpec(
    name: 'wait_agents',
    description: 'Waits for sub-agents working in the background. Returns when '
        'EVERY listed sub-agent has finished, or when timeout_seconds pass — '
        'whichever comes first — with each one\'s status, and the report of each '
        'that finished. Leave task_ids empty to wait for all running '
        'sub-agents. Prefer one long wait (minutes) to many short ones, and do '
        'other work first if there is any; reports also arrive on their own as '
        'notes, so you never need to poll.',
    parameters: {
      'type': 'object',
      'properties': {
        'task_ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
        'timeout_seconds': {
          'type': 'integer',
          'description': 'At most $kMaxWaitSeconds. Default $kDefaultWaitSeconds.',
        },
      },
    },
  ),
  (ctx, args) async {
    final raw = args['task_ids'];
    final ids = <String>[
      if (raw is List)
        for (final id in raw)
          if ('$id'.trim().isNotEmpty) '$id'.trim(),
      if (raw is String)
        for (final id in raw.split(','))
          if (id.trim().isNotEmpty) id.trim(),
    ];
    final seconds = switch (args['timeout_seconds']) {
      num n => n.toInt(),
      String t => int.tryParse(t.trim()) ?? kDefaultWaitSeconds,
      _ => kDefaultWaitSeconds,
    };
    final runtime = _runtime(ctx);
    final known = {for (final a in runtime.agents) a.id};
    final unknown = [for (final id in ids) if (!known.contains(id)) id];
    if (unknown.isNotEmpty) {
      throw StudioToolError(
        'No sub-agent has task_id ${unknown.map((u) => '"$u"').join(', ')}. '
        'Call list_agents to see them.',
      );
    }
    return StudioToolResult.json(await runtime.waitForAgents(
      ids,
      Duration(seconds: seconds.clamp(1, kMaxWaitSeconds)),
    ));
  },
);

final StudioTool listAgentsTool = StudioTool(
  const ToolSpec(
    name: 'list_agents',
    description: 'Lists every sub-agent in this session: its task_id, label, '
        'type, what it was given, status, whether it runs in the background, '
        'how long it has run, its tokens and any messages waiting for it.',
  ),
  (ctx, args) async {
    final runtime = _runtime(ctx);
    final now = DateTime.now();
    return StudioToolResult.json({
      'agents': [
        for (final a in runtime.agents)
          {
            'task_id': a.id,
            'label': a.label,
            'agent_type': a.role,
            'description': a.description,
            'status': a.interrupted && !a.running ? 'interrupted' : a.status.name,
            if (a.background) 'background': true,
            'elapsed_seconds': a.elapsed(now).inSeconds,
            'tokens': a.tokens,
            'tool_calls': a.toolCallCount,
            if (runtime.queuedFor(a.id) > 0)
              'queued_messages': runtime.queuedFor(a.id),
          },
      ],
    });
  },
);

/// Tools about the run itself rather than the draft — messaging and waiting on
/// sub-agents. Registered into [kStudioTools] alongside the draft tools. The
/// main agent has them while sub-agents are on; a sub-agent never does (one
/// level deep, like the `task` tool itself).
final List<StudioTool> kRuntimeTools = <StudioTool>[
  sendMessageTool,
  waitAgentsTool,
  listAgentsTool,
];

/// The names of [kRuntimeTools], which the controller keeps from sub-agents.
Set<String> get kRuntimeToolNames => {for (final t in kRuntimeTools) t.name};

/// Which of [kRuntimeTools] a sub-agent of a given type gets, by name: none.
const Map<String, List<String>> kRuntimeToolsFor = <String, List<String>>{};
