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
import 'message_image.dart';
import 'studio_agent_type.dart';
import 'studio_revisions.dart';
import 'usage.dart';

export 'studio_agent_type.dart';

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
/// it, any embedding documents — and the session's [notes], the agents' (and
/// the user's) working notes, which are part of the draft so a rewind covers
/// them, but are never applied to the library.
///
/// Books keep their own ids, and the character's [Character.lorebookIds] name
/// them — so applying is an upsert by id, and a book brought in from the library
/// is saved back over itself rather than duplicated.
class StudioWorkspace {
  StudioWorkspace({
    required this.character,
    List<Lorebook>? lorebooks,
    List<StudioDocument>? documents,
    this.notes = '',
  })  : lorebooks = lorebooks ?? <Lorebook>[],
        documents = documents ?? <StudioDocument>[];

  Character character;
  final List<Lorebook> lorebooks;
  final List<StudioDocument> documents;

  /// Free-form markdown: research, findings, decisions, open questions — the
  /// session's writing area. Read and written by every agent (`read_notes`,
  /// `append_notes` …) and by hand in the Draft's Notes tab. Never applied:
  /// it is the workbench, not the card.
  String notes;

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
        if (notes.isNotEmpty) 'notes': notes,
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
        notes: json['notes'] as String? ?? '',
      );

  /// A deep copy, through JSON — the same shape a session is saved in, so a
  /// snapshot can never hold something a save would lose.
  StudioWorkspace clone() => StudioWorkspace.fromJson(
        jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>,
      );
}

/// One line of a playtest: what the tester said, or the character's reply.
class StudioPlaytestTurn {
  const StudioPlaytestTurn({
    required this.user,
    required this.text,
    this.error = false,
  });

  /// Whether the tester said it; otherwise it is the character's.
  final bool user;
  final String text;

  /// A reply that failed: [text] is the error. Shown, never sent back.
  final bool error;

  Map<String, dynamic> toJson() => {
        'user': user,
        'text': text,
        if (error) 'error': true,
      };

  static StudioPlaytestTurn? fromJson(Object? json) {
    if (json is! Map) return null;
    return StudioPlaytestTurn(
      user: json['user'] as bool? ?? false,
      text: json['text'] as String? ?? '',
      error: json['error'] as bool? ?? false,
    );
  }
}

/// One playtest chat with the draft, kept for the Playground: the user's own
/// (typed there) or one an agent ran with the `playtest` tool. Every reply
/// went through the real chat prompt — see `AppState.playtestCharacter`.
///
/// Kept on the session, not the workspace: a rewind changes the draft, not
/// what was said to it, and snapshots stay small.
class StudioPlaytest {
  StudioPlaytest({
    required this.id,
    required this.by,
    this.title = '',
    this.persona = '',
    this.scenario = '',
    this.greetingIndex = 0,
    List<StudioPlaytestTurn>? turns,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : turns = turns ?? <StudioPlaytestTurn>[],
        createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  final String id;

  /// Who ran it: [kUserEditor] for the user, else an agent's name as a
  /// revision records it (`the main agent`, `Subagent 3`).
  final String by;
  String title;

  /// Who the tester was playing, as the agent described it.
  String persona;

  /// A situation for this test only, in place of the card's scenario.
  String scenario;
  int greetingIndex;
  final List<StudioPlaytestTurn> turns;
  final DateTime createdAt;
  DateTime updatedAt;

  bool get byUser => by == kUserEditor;

  /// The turns that go back to the model: everything but failed replies.
  List<StudioPlaytestTurn> get sendable => [for (final t in turns) if (!t.error) t];

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    return byUser ? 'Your chat' : 'Playtest';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'by': by,
        if (title.isNotEmpty) 'title': title,
        if (persona.isNotEmpty) 'persona': persona,
        if (scenario.isNotEmpty) 'scenario': scenario,
        if (greetingIndex != 0) 'greetingIndex': greetingIndex,
        'turns': [for (final t in turns) t.toJson()],
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static StudioPlaytest? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'] as String? ?? '';
    if (id.isEmpty) return null;
    return StudioPlaytest(
      id: id,
      by: json['by'] as String? ?? kUserEditor,
      title: json['title'] as String? ?? '',
      persona: json['persona'] as String? ?? '',
      scenario: json['scenario'] as String? ?? '',
      greetingIndex: (json['greetingIndex'] as num?)?.toInt() ?? 0,
      turns: [
        if (json['turns'] is List)
          for (final t in json['turns'] as List) ?StudioPlaytestTurn.fromJson(t),
      ],
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }
}

/// How many playtests a session keeps; the oldest go first.
const int kStudioPlaytestLimit = 40;

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
    // Runtime: compaction, background runs, interruption.
    List<StudioCompaction>? compactions,
    this.background = false,
    this.interrupted = false,
  })  : transcript = transcript ?? <AgentMessage>[],
        todos = todos ?? <StudioTodo>[],
        resumeCallIds = resumeCallIds ?? <String>[],
        compactions = compactions ?? <StudioCompaction>[],
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

  // --- runtime ---------------------------------------------------------------

  /// Its conversation's summaries, oldest first (see [StudioCompaction]).
  final List<StudioCompaction> compactions;

  /// Whether its current (or last) run was started in the background: the
  /// main agent kept working, and the report came back as a note.
  bool background;

  /// Whether the app closed while it was working. Its conversation is kept,
  /// and `task` with its id carries it on.
  bool interrupted;

  /// Its last request, as the host counted it beside the Studio's estimate —
  /// what the context inspector compares. Null until a host reports real
  /// usage.
  StudioRequestSize? lastRequest;

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
        if (compactions.isNotEmpty)
          'compactions': [for (final c in compactions) c.toJson()],
        if (background) 'background': true,
        if (interrupted) 'interrupted': true,
        if (lastRequest != null) 'lastRequest': lastRequest!.toJson(),
      };

  factory StudioSubagent.fromJson(Map<String, dynamic> json) {
    var status = StudioAgentStatus.values.firstWhere(
      (s) => s.name == json['status'],
      orElse: () => StudioAgentStatus.done,
    );
    var ended = DateTime.tryParse(json['endedAt'] as String? ?? '');
    // A run cannot survive the app closing; one saved mid-run was cut off.
    var interrupted = json['interrupted'] as bool? ?? false;
    if (status == StudioAgentStatus.running) {
      status = StudioAgentStatus.cancelled;
      interrupted = true;
    }
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
      compactions: StudioCompaction.listFrom(json['compactions']),
      background: json['background'] as bool? ?? false,
      interrupted: interrupted,
    )..lastRequest = StudioRequestSize.fromJson(json['lastRequest']);
  }
}

/// How big an agent's request was: [reported] input tokens as the host
/// counted them, beside the Studio's own [estimated] count of the same
/// request — so the context inspector can say how far its estimates are off.
class StudioRequestSize {
  const StudioRequestSize({
    required this.reported,
    required this.estimated,
    required this.at,
  });

  final int reported;
  final int estimated;
  final DateTime at;

  Map<String, dynamic> toJson() => {
        'reported': reported,
        'estimated': estimated,
        'at': at.toIso8601String(),
      };

  static StudioRequestSize? fromJson(Object? json) {
    if (json is! Map) return null;
    final reported = (json['reported'] as num?)?.toInt();
    if (reported == null) return null;
    return StudioRequestSize(
      reported: reported,
      estimated: (json['estimated'] as num?)?.toInt() ?? 0,
      at: DateTime.tryParse(json['at'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

/// An agent's earlier conversation, summarised so the next request fits its
/// model's context — Claude Code's auto-compact, in the Studio.
///
/// The transcript itself is never cut: it is what the chat draws. A compaction
/// only changes what is *sent*: the summary, as a note, then the transcript
/// from [upTo] on. Each one covers everything before its [upTo], including the
/// summaries before it, so only the newest is ever sent.
class StudioCompaction {
  StudioCompaction({
    required this.summary,
    required this.upTo,
    DateTime? at,
    this.tokensBefore = 0,
  }) : at = at ?? DateTime.now();

  /// What the agent wrote for itself about the part it no longer sees.
  final String summary;

  /// The transcript index the summary covers up to (exclusive): messages
  /// `[0, upTo)` are behind it. Always the start of a turn, never between a
  /// tool call and its result.
  final int upTo;
  final DateTime at;

  /// How big the request had grown when it was taken, for the chat's divider.
  final int tokensBefore;

  Map<String, dynamic> toJson() => {
        'summary': summary,
        'upTo': upTo,
        'at': at.toIso8601String(),
        if (tokensBefore > 0) 'tokensBefore': tokensBefore,
      };

  factory StudioCompaction.fromJson(Map<String, dynamic> json) =>
      StudioCompaction(
        summary: json['summary'] as String? ?? '',
        upTo: (json['upTo'] as num?)?.toInt() ?? 0,
        at: DateTime.tryParse(json['at'] as String? ?? ''),
        tokensBefore: (json['tokensBefore'] as num?)?.toInt() ?? 0,
      );

  static List<StudioCompaction> listFrom(Object? raw) => [
        if (raw is List)
          for (final c in raw)
            if (c is Map) StudioCompaction.fromJson(Map<String, dynamic>.from(c)),
      ];
}

/// A message the user sent while the agent was working: it waits here, shown
/// in the chat as queued, until the agent reaches the end of its current step
/// and takes it in — Claude Code's queued messages.
class StudioQueuedMessage {
  StudioQueuedMessage({
    required this.id,
    required this.text,
    List<MessageImage>? images,
  }) : images = images ?? const <MessageImage>[];

  final String id;
  final String text;
  final List<MessageImage> images;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        if (images.isNotEmpty) 'images': [for (final i in images) i.toJson()],
      };

  factory StudioQueuedMessage.fromJson(Map<String, dynamic> json) =>
      StudioQueuedMessage(
        id: json['id'] as String? ?? '',
        text: json['text'] as String? ?? '',
        images: [
          if (json['images'] is List)
            for (final i in json['images'] as List)
              if (i is Map) MessageImage.fromJson(Map<String, dynamic>.from(i)),
        ],
      );
}

/// Answers every tool call in [transcript] that has no result — what a run cut
/// off by the app closing leaves behind. A call with no result is one no
/// dialect accepts again (OpenAI and Anthropic reject the request outright,
/// Gemini loses the thread), so a session saved mid-run is repaired on load.
///
/// The missing results go right after the results that did arrive, before the
/// next turn. [resultFor] says what each one reads; it is an error either way.
/// Returns how many were added.
int repairUnansweredCalls(
  List<AgentMessage> transcript,
  String Function(ToolCall call) resultFor,
) {
  var added = 0;
  var i = 0;
  while (i < transcript.length) {
    final m = transcript[i];
    i++;
    if (m.role != AgentRole.assistant || m.toolCalls.isEmpty) continue;
    final answered = <String>{};
    var end = i;
    while (end < transcript.length && transcript[end].role == AgentRole.tool) {
      final id = transcript[end].toolCallId;
      if (id != null) answered.add(id);
      end++;
    }
    final missing = [
      for (final call in m.toolCalls)
        if (!answered.contains(call.id))
          AgentMessage.toolResult(call, resultFor(call), isError: true),
    ];
    transcript.insertAll(end, missing);
    added += missing.length;
    i = end + missing.length;
  }
  return added;
}

/// What a call cut off by the app closing is answered with.
const String kInterruptedCallResult =
    'Interrupted before it finished — the app was closed. Call it again if it '
    'is still needed.';

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
    Map<String, StudioRevision>? revisions,
    // Runtime: compaction, queued messages, run state.
    List<StudioCompaction>? compactions,
    List<StudioQueuedMessage>? queued,
    this.active = false,
    this.interrupted = false,
    List<StudioPlaytest>? playtests,
  })  : playtests = playtests ?? <StudioPlaytest>[],
        transcript = transcript ?? <AgentMessage>[],
        ops = ops ?? <StudioOp>[],
        subagents = subagents ?? <StudioSubagent>[],
        todos = todos ?? <StudioTodo>[],
        revisions = revisions ?? <String, StudioRevision>{},
        compactions = compactions ?? <StudioCompaction>[],
        queued = queued ?? <StudioQueuedMessage>[],
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

  /// The Playground's chats with the draft — the user's and the agents' —
  /// oldest first, at most [kStudioPlaytestLimit].
  final List<StudioPlaytest> playtests;

  StudioPlaytest? playtest(String id) {
    for (final p in playtests) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// Files [test], dropping the oldest past the limit.
  void addPlaytest(StudioPlaytest test) {
    playtests.add(test);
    while (playtests.length > kStudioPlaytestLimit) {
      playtests.removeAt(0);
    }
    updatedAt = DateTime.now();
  }

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

  // --- stale-edit protection ------------------------------------------------

  /// The latest version of each part of the draft, and who made it (see
  /// `studio_revisions.dart`). Saved with the session, so a draft reopened
  /// tomorrow still knows what was last touched by whom. Kept on the session,
  /// not the workspace: a rewind swaps the workspace for an old snapshot, and
  /// the version numbers must keep going up through that.
  final Map<String, StudioRevision> revisions;

  /// What each agent has seen of the draft, by the agent's name (`studio`, or
  /// a sub-agent's label): part key → the revision it read or wrote last.
  /// Not saved — after a restart every agent reads the draft again before
  /// changing what somebody else changed, which is the safe side.
  final Map<String, Map<String, int>> seen = <String, Map<String, int>>{};

  /// What [agent] has seen, created on first use.
  Map<String, int> seenBy(String agent) =>
      seen.putIfAbsent(agent, () => <String, int>{});

  /// Records that [parts] changed, by [by], bumping each one's revision.
  Set<String> _bump(Iterable<String> parts, String by) {
    final out = <String>{};
    for (final key in parts) {
      revisions[key] = StudioRevision((revisions[key]?.rev ?? 0) + 1, by);
      out.add(key);
    }
    return out;
  }
  // --- runtime ---------------------------------------------------------------

  /// The main agent's conversation summaries, oldest first.
  final List<StudioCompaction> compactions;

  /// Messages the user sent while the agent was working, not yet taken in.
  final List<StudioQueuedMessage> queued;

  /// Whether an agent (the main one, or a sub-agent in the background) was
  /// working when this was saved. A session loaded with this set was cut off
  /// by the app closing, and loads [interrupted].
  bool active;

  /// Whether the last run was cut off by the app closing. The transcript has
  /// been repaired (see [repairUnansweredCalls]); the user can resume.
  bool interrupted;

  /// The main agent's last request, as the host counted it beside the
  /// Studio's estimate. Null until a host reports real usage.
  StudioRequestSize? lastRequest;

  /// The sub-agents the app closing cut off, for the resume note.
  List<StudioSubagent> get interruptedSubagents =>
      [for (final a in subagents) if (a.interrupted) a];

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
  ///
  /// Returns the parts of the draft the change touched, whose revisions it
  /// has bumped in the name of whoever [tool] says made it.
  Set<String> edit(
    String tool,
    String summary,
    void Function(StudioWorkspace ws) change,
  ) {
    final before = jsonEncode(workspace.toJson());
    final fingerprints = partFingerprints(workspace);
    change(workspace);
    final touched = _bump(
      changedParts(fingerprints, partFingerprints(workspace)),
      editorOf(tool),
    );
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
    return touched;
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
    final fingerprints = partFingerprints(workspace);
    workspace = StudioWorkspace.fromJson(
      jsonDecode(ops[index].before) as Map<String, dynamic>,
    );
    // A rewind is the user changing those parts back: an agent that read them
    // before it has to read them again.
    _bump(changedParts(fingerprints, partFingerprints(workspace)), kUserEditor);
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
        if (revisions.isNotEmpty)
          'revisions': {
            for (final e in revisions.entries) e.key: e.value.toJson(),
          },
        if (compactions.isNotEmpty)
          'compactions': [for (final c in compactions) c.toJson()],
        if (queued.isNotEmpty) 'queued': [for (final q in queued) q.toJson()],
        if (active) 'active': true,
        if (interrupted) 'interrupted': true,
        if (lastRequest != null) 'lastRequest': lastRequest!.toJson(),
        if (playtests.isNotEmpty)
          'playtests': [for (final p in playtests) p.toJson()],
      };

  /// Reads a saved session. One saved while an agent worked ([active]) was cut
  /// off by the app closing: it loads [interrupted], every agent that was
  /// working is marked so, and each unanswered tool call is answered, so the
  /// transcript is one every dialect accepts again.
  factory StudioSession.fromJson(Map<String, dynamic> json) {
    final session = StudioSession._fromJson(json)
      ..lastRequest = StudioRequestSize.fromJson(json['lastRequest']);
    if (session.active) {
      session
        ..active = false
        ..interrupted = true;
    }
    if (session.interrupted) session.repairInterrupted();
    return session;
  }

  /// Answers every call the app closing left open, in the main transcript and
  /// every sub-agent's. A `task` call names the sub-agent it started and how
  /// to carry it on.
  void repairInterrupted() {
    String resultFor(ToolCall call) {
      if (call.name == 'task') {
        for (final a in subagents) {
          if (a.callId == call.id || a.resumeCallIds.contains(call.id)) {
            return jsonEncode({
              'subagent': a.label,
              'task_id': a.id,
              'status': 'interrupted',
              'report': 'The app was closed while ${a.label} was working. Its '
                  'conversation is kept: call task with task_id "${a.id}" to '
                  'carry it on, if it is still needed.',
            });
          }
        }
      }
      return kInterruptedCallResult;
    }

    repairUnansweredCalls(transcript, resultFor);
    for (final a in subagents) {
      repairUnansweredCalls(a.transcript, (_) => kInterruptedCallResult);
      // Its clock stops where the app did, not at whenever it is next looked at.
      if (a.interrupted) a.endedAt ??= updatedAt;
    }
  }

  factory StudioSession._fromJson(Map<String, dynamic> json) => StudioSession(
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
        revisions: {
          if (json['revisions'] is Map)
            for (final e in (json['revisions'] as Map).entries)
              if (StudioRevision.fromJson(e.value) != null)
                e.key.toString(): StudioRevision.fromJson(e.value)!,
        },
        compactions: StudioCompaction.listFrom(json['compactions']),
        queued: [
          if (json['queued'] is List)
            for (final q in json['queued'] as List)
              if (q is Map)
                StudioQueuedMessage.fromJson(Map<String, dynamic>.from(q)),
        ],
        active: json['active'] as bool? ?? false,
        interrupted: json['interrupted'] as bool? ?? false,
        playtests: [
          if (json['playtests'] is List)
            for (final p in json['playtests'] as List) ?StudioPlaytest.fromJson(p),
        ],
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
    this.areasCapsule = false,
    // Knowledge: the web, memory, and the user's own sub-agent types.
    this.webTools = true,
    this.searchProvider = StudioSearchProvider.duckduckgo,
    this.searchUrl = '',
    this.searchKey = '',
    this.memoryEnabled = true,
    this.customAgents = const <StudioAgentType>[],
    this.contextBudget = kStudioDefaultContextBudget,
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

  /// Whether the Interface | Draft | Changes capsule is shown. It stays on —
  /// across sessions and restarts — until it is switched off again from the
  /// composer's actions, which is the only place it is switched.
  final bool areasCapsule;

  /// The builder's instructions, or empty for the built-in ones.
  final String systemPrompt;

  // --- knowledge ---------------------------------------------------------------

  /// Whether the agents may search and read the web (`web_search`,
  /// `web_fetch`).
  final bool webTools;

  /// Where `web_search` goes; Wikipedia and Fandom need no key.
  final StudioSearchProvider searchProvider;

  /// A SearXNG instance's address, for [StudioSearchProvider.searxng].
  final String searchUrl;

  /// The Brave Search key, for [StudioSearchProvider.brave]. A secret: saved
  /// as `apiKey`, so a backup made without keys blanks it like every other
  /// key (`kBackupSecretFields`).
  final String searchKey;

  /// Whether the Studio remembers the user's preferences across sessions
  /// (`remember`/`forget`, and the notes in every agent's instructions).
  final bool memoryEnabled;

  /// The user's own sub-agent types, beside the built-in four.
  final List<StudioAgentType> customAgents;
  /// How many tokens a request may reach before the agent's earlier
  /// conversation is summarised, when the model's own window is not known
  /// (and never more than that window when it is).
  final int contextBudget;

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
    bool? areasCapsule,
    bool? webTools,
    StudioSearchProvider? searchProvider,
    String? searchUrl,
    String? searchKey,
    bool? memoryEnabled,
    List<StudioAgentType>? customAgents,
    int? contextBudget,
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
        areasCapsule: areasCapsule ?? this.areasCapsule,
        webTools: webTools ?? this.webTools,
        searchProvider: searchProvider ?? this.searchProvider,
        searchUrl: searchUrl ?? this.searchUrl,
        searchKey: searchKey ?? this.searchKey,
        memoryEnabled: memoryEnabled ?? this.memoryEnabled,
        customAgents: customAgents ?? this.customAgents,
        contextBudget: contextBudget ?? this.contextBudget,
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
        if (areasCapsule) 'areasCapsule': true,
        if (!webTools) 'webTools': false,
        if (searchProvider != StudioSearchProvider.duckduckgo)
          'searchProvider': searchProvider.name,
        if (searchUrl.isNotEmpty) 'searchUrl': searchUrl,
        if (searchKey.isNotEmpty) 'apiKey': searchKey,
        if (!memoryEnabled) 'memoryEnabled': false,
        if (customAgents.isNotEmpty)
          'customAgents': [for (final a in customAgents) a.toJson()],
        if (contextBudget != kStudioDefaultContextBudget)
          'contextBudget': contextBudget,
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
        areasCapsule: json['areasCapsule'] as bool? ?? false,
        webTools: json['webTools'] as bool? ?? true,
        searchProvider: StudioSearchProvider.byName(json['searchProvider']),
        searchUrl: json['searchUrl'] as String? ?? '',
        searchKey: json['apiKey'] as String? ?? '',
        memoryEnabled: json['memoryEnabled'] as bool? ?? true,
        customAgents: StudioAgentType.listFrom(json['customAgents']),
        contextBudget: ((json['contextBudget'] as num?)?.toInt() ??
                kStudioDefaultContextBudget)
            .clamp(kStudioMinContextBudget, kStudioMaxContextBudget),
      );
}

const int kStudioDefaultMaxSteps = 40;

/// How many sub-agents work at once unless the user says otherwise.
const int kStudioDefaultParallelSubagents = 20;

/// The request size, in tokens, past which an agent's earlier conversation is
/// summarised when the model's window is not known.
const int kStudioDefaultContextBudget = 120000;
const int kStudioMinContextBudget = 8000;
const int kStudioMaxContextBudget = 2000000;
