/// The Character Studio's records: what an agent is building (the
/// [StudioWorkspace]), the conversation it is building it in, the trail of
/// changes it made, and how the Studio talks to its model ([StudioConfig]).
///
/// A session is a *draft*. Nothing in it touches the library until the user
/// applies it, which is what lets a run be stopped, rewound or thrown away
/// without leaving half a character on the roster. Sessions are files (see
/// `StudioStore`), never preferences: a transcript full of tool results grows
/// quickly, and a large preferences entry is what once made the app unopenable.
library;

import 'dart:convert';

import 'agent_message.dart';
import 'character.dart';
import 'lorebook.dart';
import 'usage.dart';

/// A text the agent wrote for the embeddings library — background too long or
/// too loose for a lorebook entry, recalled by meaning instead of keywords.
///
/// [libraryId] names the [EmbeddingDocument] it became once applied, so a
/// second apply re-indexes that document rather than adding another.
class StudioDocument {
  StudioDocument({
    required this.id,
    required this.name,
    this.text = '',
    this.libraryId,
  });

  final String id;
  String name;
  String text;
  String? libraryId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'text': text,
        if (libraryId != null) 'libraryId': libraryId,
      };

  factory StudioDocument.fromJson(Map<String, dynamic> json) => StudioDocument(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        text: json['text'] as String? ?? '',
        libraryId: json['libraryId'] as String?,
      );
}

/// Everything a session is building: one character, the lorebooks that go with
/// it, and any embedding documents.
///
/// Books keep their own ids, and the character's [Character.lorebookIds] name
/// them — so applying is an upsert by id, and a book brought in from the library
/// is saved back over itself rather than duplicated.
class StudioWorkspace {
  StudioWorkspace({
    required this.character,
    List<Lorebook>? lorebooks,
    List<StudioDocument>? documents,
  })  : lorebooks = lorebooks ?? <Lorebook>[],
        documents = documents ?? <StudioDocument>[];

  Character character;
  final List<Lorebook> lorebooks;
  final List<StudioDocument> documents;

  Lorebook? lorebook(String id) {
    for (final book in lorebooks) {
      if (book.id == id) return book;
    }
    return null;
  }

  StudioDocument? document(String id) {
    for (final doc in documents) {
      if (doc.id == id) return doc;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'character': character.toJson(),
        'lorebooks': [for (final b in lorebooks) b.toJson()],
        'documents': [for (final d in documents) d.toJson()],
      };

  factory StudioWorkspace.fromJson(Map<String, dynamic> json) => StudioWorkspace(
        character: json['character'] is Map
            ? Character.fromJson(
                Map<String, dynamic>.from(json['character'] as Map),
              )
            : Character.empty(),
        lorebooks: [
          if (json['lorebooks'] is List)
            for (final b in json['lorebooks'] as List)
              if (b is Map) Lorebook.fromJson(Map<String, dynamic>.from(b)),
        ],
        documents: [
          if (json['documents'] is List)
            for (final d in json['documents'] as List)
              if (d is Map) StudioDocument.fromJson(Map<String, dynamic>.from(d)),
        ],
      );

  /// A deep copy, through JSON — the same shape a session is saved in, so a
  /// snapshot can never hold something a save would lose.
  StudioWorkspace clone() => StudioWorkspace.fromJson(
        jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>,
      );
}

/// One change the agent (or the user, by hand) made to the workspace, with the
/// whole workspace as it was just before it.
///
/// A whole snapshot rather than a diff so a rewind is exact however the change
/// was made, and so rewinding is *to a point* — this change and everything after
/// it — rather than picking one change out of the middle and leaving the later
/// ones standing on a state that no longer exists.
class StudioOp {
  StudioOp({
    required this.id,
    required this.tool,
    required this.summary,
    required this.before,
    DateTime? at,
    this.reverted = false,
  }) : at = at ?? DateTime.now();

  final String id;

  /// The tool that made it, or `manual` for an edit made by hand.
  final String tool;

  /// One line saying what changed, for the Changes tab.
  final String summary;

  /// The workspace, encoded, from just before this change. Emptied once the
  /// change is older than [kStudioSnapshotLimit] others.
  String before;
  final DateTime at;
  bool reverted;

  Map<String, dynamic> toJson() => {
        'id': id,
        'tool': tool,
        'summary': summary,
        'before': before,
        'at': at.toIso8601String(),
        if (reverted) 'reverted': true,
      };

  factory StudioOp.fromJson(Map<String, dynamic> json) => StudioOp(
        id: json['id'] as String? ?? '',
        tool: json['tool'] as String? ?? '',
        summary: json['summary'] as String? ?? '',
        before: json['before'] as String? ?? '',
        at: DateTime.tryParse(json['at'] as String? ?? ''),
        reverted: json['reverted'] as bool? ?? false,
      );
}

/// Where one step of an agent's plan stands.
enum StudioTodoStatus {
  pending('pending'),
  inProgress('in_progress'),
  completed('completed');

  const StudioTodoStatus(this.wire);

  /// The name the `todo_write` tool uses.
  final String wire;

  static StudioTodoStatus? fromWire(Object? value) {
    for (final s in StudioTodoStatus.values) {
      if (s.wire == value || s.name == value) return s;
    }
    return null;
  }
}

/// One step of an agent's plan, written with the `todo_write` tool so a long
/// build shows where it is.
class StudioTodo {
  const StudioTodo({required this.content, this.status = StudioTodoStatus.pending});

  final String content;
  final StudioTodoStatus status;

  Map<String, dynamic> toJson() => {'content': content, 'status': status.wire};

  static StudioTodo? fromJson(Object? json) {
    if (json is! Map) return null;
    final content = (json['content'] as String? ?? '').trim();
    if (content.isEmpty) return null;
    return StudioTodo(
      content: content,
      status: StudioTodoStatus.fromWire(json['status']) ?? StudioTodoStatus.pending,
    );
  }

  static List<StudioTodo> listFrom(Object? json) => [
        if (json is List)
          for (final t in json) ?StudioTodo.fromJson(t),
      ];
}

/// Where a sub-agent's run stands.
enum StudioAgentStatus { running, done, failed, cancelled }

/// One sub-agent the Studio spawned: a fresh agent with its own conversation,
/// given one task by the main agent, working on the same draft, reporting back
/// once. Kept on the session so its chat can be opened and read afterwards.
class StudioSubagent {
  StudioSubagent({
    required this.id,
    required this.number,
    required this.description,
    required this.prompt,
    required this.callId,
    this.role = 'general',
    List<AgentMessage>? transcript,
    DateTime? startedAt,
    this.endedAt,
    this.status = StudioAgentStatus.running,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.report,
    List<StudioTodo>? todos,
    List<String>? resumeCallIds,
  })  : transcript = transcript ?? <AgentMessage>[],
        todos = todos ?? <StudioTodo>[],
        resumeCallIds = resumeCallIds ?? <String>[],
        startedAt = startedAt ?? DateTime.now();

  final String id;

  /// Its place in the session, from 1 — "Subagent 3".
  final int number;

  /// The few words the main agent gave it, shown beside its number.
  final String description;

  /// The task, as the main agent wrote it — its conversation's first message.
  final String prompt;

  /// The spawning tool call, which its report answers.
  final String callId;

  /// What kind of agent it is (`general`, `writer`, `lore_writer`, `critic`…).
  final String role;

  final List<AgentMessage> transcript;

  /// The `task` calls that carried it on since, by `task_id`.
  final List<String> resumeCallIds;

  /// When its current run began — reset when it is carried on.
  DateTime startedAt;
  DateTime? endedAt;
  StudioAgentStatus status;
  int inputTokens;
  int outputTokens;

  /// What it reported back, once it has.
  String? report;

  /// Its own plan, from its `todo_write` calls.
  final List<StudioTodo> todos;

  String get label => 'Subagent $number';

  /// How many tools it has called so far.
  int get toolCallCount =>
      transcript.fold(0, (n, m) => n + m.toolCalls.length);

  bool get running => status == StudioAgentStatus.running;

  int get tokens => inputTokens + outputTokens;

  /// How long it has run (or ran).
  Duration elapsed([DateTime? now]) =>
      (endedAt ?? now ?? DateTime.now()).difference(startedAt);

  Map<String, dynamic> toJson() => {
        'id': id,
        'number': number,
        'description': description,
        'prompt': prompt,
        'callId': callId,
        'role': role,
        'transcript': [for (final m in transcript) m.toJson()],
        'startedAt': startedAt.toIso8601String(),
        if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
        'status': status.name,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        if (report != null) 'report': report,
        if (todos.isNotEmpty) 'todos': [for (final t in todos) t.toJson()],
        if (resumeCallIds.isNotEmpty) 'resumeCallIds': resumeCallIds,
      };

  factory StudioSubagent.fromJson(Map<String, dynamic> json) {
    var status = StudioAgentStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => StudioAgentStatus.done,
    );
    final ended = DateTime.tryParse(json['endedAt'] as String? ?? '');
    // A run cannot survive the app closing; one saved mid-run was cut off.
    if (status == StudioAgentStatus.running) status = StudioAgentStatus.cancelled;
    return StudioSubagent(
      id: json['id'] as String? ?? '',
      number: (json['number'] as num?)?.toInt() ?? 0,
      description: json['description'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
      callId: json['callId'] as String? ?? '',
      role: json['role'] as String? ?? 'general',
      transcript: [
        if (json['transcript'] is List)
          for (final m in json['transcript'] as List)
            if (m is Map) AgentMessage.fromJson(Map<String, dynamic>.from(m)),
      ],
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
      endedAt: ended,
      status: status,
      inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
      outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
      report: json['report'] as String?,
      todos: StudioTodo.listFrom(json['todos']),
      resumeCallIds: [
        if (json['resumeCallIds'] is List)
          for (final c in json['resumeCallIds'] as List) '$c',
      ],
    );
  }
}

/// How many snapshots a session keeps. Older changes stay listed but can no
/// longer be rewound to; without a cap a long session's file would carry a
/// full copy of the character per edit.
const int kStudioSnapshotLimit = 60;

/// One Character Studio session.
class StudioSession {
  StudioSession({
    required this.id,
    required this.title,
    required this.workspace,
    List<AgentMessage>? transcript,
    List<StudioOp>? ops,
    List<StudioSubagent>? subagents,
    List<StudioTodo>? todos,
    this.sourceCharacterId,
    this.folderId,
    this.appliedAt,
    this.appliedSinceChange = false,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cost = 0,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : transcript = transcript ?? <AgentMessage>[],
        ops = ops ?? <StudioOp>[],
        subagents = subagents ?? <StudioSubagent>[],
        todos = todos ?? <StudioTodo>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;
  String title;
  StudioWorkspace workspace;
  final List<AgentMessage> transcript;
  final List<StudioOp> ops;

  /// Every sub-agent this session has spawned, oldest first.
  final List<StudioSubagent> subagents;

  /// The main agent's plan, from its `todo_write` calls.
  final List<StudioTodo> todos;

  /// The library character this session was opened from, when it was.
  final String? sourceCharacterId;

  /// The folder an apply bundled the draft into, reused by the next apply.
  String? folderId;

  /// When the draft was last written to the library.
  DateTime? appliedAt;

  /// Whether the library already holds exactly this draft.
  bool appliedSinceChange;

  /// What the session has cost so far, summed across every agent it ran.
  int inputTokens;
  int outputTokens;
  double cost;

  final DateTime createdAt;
  DateTime updatedAt;

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    final name = workspace.character.name.trim();
    return name.isEmpty ? 'Untitled session' : name;
  }

  void addUsage(TokenUsage usage, double price) {
    inputTokens += usage.inputTokens;
    outputTokens += usage.outputTokens;
    cost += price;
  }

  /// Makes one change to the workspace through [change], recording it first
  /// with the workspace as it stood — taken here, in the same synchronous step
  /// as the change itself, so two tools running side by side can never record
  /// a "before" that the other has already moved on from.
  void edit(String tool, String summary, void Function(StudioWorkspace ws) change) {
    final before = jsonEncode(workspace.toJson());
    change(workspace);
    ops.add(StudioOp(
      id: '${DateTime.now().microsecondsSinceEpoch}-${ops.length}',
      tool: tool,
      summary: summary,
      before: before,
    ));
    appliedSinceChange = false;
    updatedAt = DateTime.now();
    // Old snapshots are dropped, not the changes: the row stays in the list.
    var live = 0;
    for (var i = ops.length - 1; i >= 0; i--) {
      if (ops[i].before.isEmpty) break;
      if (++live > kStudioSnapshotLimit) ops[i].before = '';
    }
  }

  /// Whether the change at [index] can still be rewound to.
  bool canRewindTo(int index) =>
      index >= 0 &&
      index < ops.length &&
      !ops[index].reverted &&
      ops[index].before.isNotEmpty;

  /// Puts the workspace back to just before the change at [index], marking it
  /// and every later change as undone. Returns the summaries that were undone,
  /// oldest first.
  List<String> rewindTo(int index) {
    if (!canRewindTo(index)) return const <String>[];
    workspace = StudioWorkspace.fromJson(
      jsonDecode(ops[index].before) as Map<String, dynamic>,
    );
    final undone = <String>[];
    for (var i = index; i < ops.length; i++) {
      if (ops[i].reverted) continue;
      ops[i].reverted = true;
      undone.add(ops[i].summary);
    }
    appliedSinceChange = false;
    return undone;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'workspace': workspace.toJson(),
        'transcript': [for (final m in transcript) m.toJson()],
        'ops': [for (final o in ops) o.toJson()],
        if (subagents.isNotEmpty)
          'subagents': [for (final a in subagents) a.toJson()],
        if (todos.isNotEmpty) 'todos': [for (final t in todos) t.toJson()],
        if (sourceCharacterId != null) 'sourceCharacterId': sourceCharacterId,
        if (folderId != null) 'folderId': folderId,
        if (appliedAt != null) 'appliedAt': appliedAt!.toIso8601String(),
        if (appliedSinceChange) 'appliedSinceChange': true,
        'inputTokens': inputTokens,
        'outputTokens': outputTokens,
        'cost': cost,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  factory StudioSession.fromJson(Map<String, dynamic> json) => StudioSession(
        id: json['id'] as String? ?? '',
        title: json['title'] as String? ?? '',
        workspace: json['workspace'] is Map
            ? StudioWorkspace.fromJson(
                Map<String, dynamic>.from(json['workspace'] as Map),
              )
            : StudioWorkspace(character: Character.empty()),
        transcript: [
          if (json['transcript'] is List)
            for (final m in json['transcript'] as List)
              if (m is Map) AgentMessage.fromJson(Map<String, dynamic>.from(m)),
        ],
        ops: [
          if (json['ops'] is List)
            for (final o in json['ops'] as List)
              if (o is Map) StudioOp.fromJson(Map<String, dynamic>.from(o)),
        ],
        subagents: [
          if (json['subagents'] is List)
            for (final a in json['subagents'] as List)
              if (a is Map) StudioSubagent.fromJson(Map<String, dynamic>.from(a)),
        ],
        todos: StudioTodo.listFrom(json['todos']),
        sourceCharacterId: json['sourceCharacterId'] as String?,
        folderId: json['folderId'] as String?,
        appliedAt: DateTime.tryParse(json['appliedAt'] as String? ?? ''),
        appliedSinceChange: json['appliedSinceChange'] as bool? ?? false,
        inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
        outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
        cost: (json['cost'] as num?)?.toDouble() ?? 0,
        createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
        updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
      );
}

/// How the Studio talks to its model. Its own small preferences entry, like the
/// image studio's: the model a character is *built* with is often not the one
/// it is *played* with, so this does not follow the chat's provider.
class StudioConfig {
  const StudioConfig({
    this.providerId,
    this.model = '',
    this.temperature,
    this.maxTokens,
    this.stream = true,
    this.maxSteps = kStudioDefaultMaxSteps,
    this.subAgents = true,
    this.maxParallelSubagents = kStudioDefaultParallelSubagents,
    this.systemPrompt = '',
  });

  /// The provider to use, or null for whichever one chats use.
  final String? providerId;

  /// A model to use instead of the provider's own, or empty for its own.
  final String model;
  final double? temperature;
  final int? maxTokens;
  final bool stream;

  /// How many model turns one message may run before the agent is stopped and
  /// asked to report — the ceiling on what a single "go" can spend.
  final int maxSteps;

  /// Whether the agent may hand work to sub-agents (the `task` tool).
  final bool subAgents;

  /// How many sub-agents may work at once. More can be asked for — the rest
  /// wait for a place rather than failing.
  final int maxParallelSubagents;

  /// The builder's instructions, or empty for the built-in ones.
  final String systemPrompt;

  StudioConfig copyWith({
    String? Function()? providerId,
    String? model,
    double? Function()? temperature,
    int? Function()? maxTokens,
    bool? stream,
    int? maxSteps,
    bool? subAgents,
    int? maxParallelSubagents,
    String? systemPrompt,
  }) =>
      StudioConfig(
        providerId: providerId == null ? this.providerId : providerId(),
        model: model ?? this.model,
        temperature: temperature == null ? this.temperature : temperature(),
        maxTokens: maxTokens == null ? this.maxTokens : maxTokens(),
        stream: stream ?? this.stream,
        maxSteps: maxSteps ?? this.maxSteps,
        subAgents: subAgents ?? this.subAgents,
        maxParallelSubagents: maxParallelSubagents ?? this.maxParallelSubagents,
        systemPrompt: systemPrompt ?? this.systemPrompt,
      );

  Map<String, dynamic> toJson() => {
        if (providerId != null) 'providerId': providerId,
        if (model.isNotEmpty) 'model': model,
        if (temperature != null) 'temperature': temperature,
        if (maxTokens != null) 'maxTokens': maxTokens,
        if (!stream) 'stream': false,
        'maxSteps': maxSteps,
        if (!subAgents) 'subAgents': false,
        if (maxParallelSubagents != kStudioDefaultParallelSubagents)
          'maxParallelSubagents': maxParallelSubagents,
        if (systemPrompt.isNotEmpty) 'systemPrompt': systemPrompt,
      };

  factory StudioConfig.fromJson(Map<String, dynamic> json) => StudioConfig(
        providerId: json['providerId'] as String?,
        model: json['model'] as String? ?? '',
        temperature: (json['temperature'] as num?)?.toDouble(),
        maxTokens: (json['maxTokens'] as num?)?.toInt(),
        stream: json['stream'] as bool? ?? true,
        maxSteps: ((json['maxSteps'] as num?)?.toInt() ?? kStudioDefaultMaxSteps)
            .clamp(1, 200),
        subAgents: json['subAgents'] as bool? ?? true,
        maxParallelSubagents: ((json['maxParallelSubagents'] as num?)?.toInt() ??
                kStudioDefaultParallelSubagents)
            .clamp(1, 50),
        systemPrompt: json['systemPrompt'] as String? ?? '',
      );
}

const int kStudioDefaultMaxSteps = 40;

/// How many sub-agents work at once unless the user says otherwise.
const int kStudioDefaultParallelSubagents = 20;
