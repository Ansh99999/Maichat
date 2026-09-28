import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../models/agent_message.dart';
import '../../models/character.dart';
import '../../models/embedding.dart';
import '../../models/folder.dart';
import '../../models/lorebook.dart';
import '../../models/message_image.dart';
import '../../models/studio.dart';
import '../../state/app_state.dart';
import '../agent_client.dart';
import '../chat_client.dart';
import '../document_sources.dart';
import 'agent_runner.dart';
import 'studio_prompt.dart';
import 'studio_store.dart';
import 'studio_tools.dart';

/// The id [StudioController.liveFor] and [StudioController.transcriptFor] use
/// for the main agent; a sub-agent is named by its [StudioSubagent.id].
const String kMainAgent = 'main';

/// What one agent is doing right now, before it lands in its transcript: the
/// reply being written, its thinking, and the calls it is waiting on.
class StudioLive {
  String text = '';
  String reasoning = '';

  /// Calls that have started and not yet answered, by call id.
  final Map<String, ToolCall> activeCalls = <String, ToolCall>{};

  void clearWords() {
    text = '';
    reasoning = '';
  }
}

/// A helper's run, as the lead's `delegate` chip shows it while it works.
class HelperRun {
  HelperRun({required this.callId, required this.helper, required this.task});

  /// The `delegate` call this run answers.
  final String callId;
  final String helper;
  final String task;

  /// What it has done so far, one line per tool call.
  final List<String> steps = <String>[];
  bool done = false;
}

/// What an apply wrote, for the confirmation that follows it.
class StudioApplyResult {
  const StudioApplyResult({
    required this.characterName,
    required this.lorebooks,
    required this.documents,
    required this.documentsSkipped,
    this.folderName,
  });

  final String characterName;
  final int lorebooks;
  final int documents;

  /// Documents left out because embeddings are off.
  final int documentsSkipped;
  final String? folderName;
}

/// One open Studio session: runs its agent, keeps the session saved as it
/// goes, and is what the Studio screen draws.
///
/// Controllers are held by [StudioHub] rather than by a screen, so an agent
/// that is working keeps working when the user steps back to the session list
/// — and the screen finds it still running when they come back.
class StudioController extends ChangeNotifier {
  StudioController({
    required this.state,
    required this.store,
    required this.session,
  });

  final AppState state;
  final StudioStore store;
  final StudioSession session;

  AgentRunner? _lead;

  /// Whether the agent is working.
  bool get running => _lead != null;

  final Map<String, StudioLive> _live = <String, StudioLive>{};

  /// What the agent named [agentId] ([kMainAgent] or a sub-agent's id) is
  /// doing right now.
  StudioLive liveFor(String agentId) =>
      _live.putIfAbsent(agentId, StudioLive.new);

  /// The conversation of the agent named [agentId].
  List<AgentMessage> transcriptFor(String agentId) => agentId == kMainAgent
      ? session.transcript
      : subagent(agentId)?.transcript ?? const <AgentMessage>[];

  /// Every sub-agent this session has spawned, oldest first.
  List<StudioSubagent> get subagents => session.subagents;

  bool get hasSubagents => session.subagents.isNotEmpty;

  StudioSubagent? subagent(String id) {
    for (final a in session.subagents) {
      if (a.id == id) return a;
    }
    return null;
  }

  /// The main agent's reply as it is being written.
  String get liveText => liveFor(kMainAgent).text;
  String get liveReasoning => liveFor(kMainAgent).reasoning;

  /// The main agent's calls that have started and not yet answered.
  Map<String, ToolCall> get activeCalls => liveFor(kMainAgent).activeCalls;

  /// Helper runs, by the `delegate` call id that started them.
  final Map<String, HelperRun> helpers = <String, HelperRun>{};

  /// Why the last run stopped short, when it did: a failed request, or the
  /// step ceiling.
  String? notice;
  bool noticeIsError = false;

  /// Hand edits made since the agent last ran, told to it with the next
  /// message so it does not write over them from an old read of the draft.
  final List<String> _handEdits = <String>[];

  Timer? _paint;
  Future<void> _saving = Future<void>.value();
  bool _disposed = false;

  // --- running ---------------------------------------------------------------

  /// Sends the user's [text] (and any [images]) and runs the agent until it
  /// answers.
  Future<void> send(
    String text, {
    List<MessageImage> images = const <MessageImage>[],
  }) async {
    final message = text.trim();
    if ((message.isEmpty && images.isEmpty) || running) return;
    notice = null;
    if (_handEdits.isNotEmpty) {
      session.transcript.add(AgentMessage.user(
        '[Studio note] The user edited the draft by hand: '
        '${_handEdits.join('; ')}. Call get_draft before changing those parts.',
      ));
      _handEdits.clear();
    }
    session.transcript.add(AgentMessage.user(message, images: images));
    if (session.title.trim().isEmpty && session.workspace.character.name.isEmpty) {
      session.title = _titleFrom(message);
    }
    session.updatedAt = DateTime.now();
    _save();
    await _runLead();
  }

  /// Stops the agent and every helper it started.
  void stop() => _lead?.cancel();

  void dismissNotice() {
    notice = null;
    notifyListeners();
  }

  Future<void> _runLead() async {
    final config = state.studioConfig;
    final services = _AppStudioServices(this);
    final lead = AgentRunner(
      name: 'studio',
      systemPrompt: config.systemPrompt.trim().isEmpty
          ? defaultStudioPrompt()
          : config.systemPrompt,
      tools: studioToolsFor('studio', subAgents: config.subAgents),
      context: StudioToolContext(session: session, services: services),
      turn: _turn,
      maxSteps: config.maxSteps,
      observer: _observer,
    );
    services.lead = lead;
    _lead = lead;
    liveFor(kMainAgent).clearWords();
    helpers.clear();
    notifyListeners();
    try {
      final outcome = await lead.run(session.transcript);
      if (outcome.end == AgentRunEnd.stepLimit) {
        notice = 'Stopped after ${config.maxSteps} steps. Send "continue" to '
            'let it carry on, or raise the limit in Studio settings.';
        noticeIsError = false;
      }
    } on ChatApiException catch (e) {
      notice = e.message;
      noticeIsError = true;
    } catch (e) {
      notice = 'The Studio stopped: $e';
      noticeIsError = true;
    } finally {
      _lead = null;
      for (final a in session.subagents) {
        if (a.running) {
          a
            ..status = StudioAgentStatus.cancelled
            ..endedAt ??= DateTime.now();
        }
      }
      for (final waiting in _taskQueue) {
        waiting.complete();
      }
      _taskQueue.clear();
      for (final live in _live.values) {
        live
          ..clearWords()
          ..activeCalls.clear();
      }
      session.updatedAt = DateTime.now();
      _save();
      if (!_disposed) notifyListeners();
    }
  }

  Stream<AgentDelta> _turn(
    AgentClient client,
    List<AgentMessage> messages,
    List<ToolSpec> tools,
  ) =>
      state.streamAgentTurn(
        client: client,
        messages: messages,
        tools: tools,
        onSpend: (usage, cost) => session.addUsage(usage, cost),
      );

  AgentObserver get _observer => AgentObserver(
        onText: (agent, delta) {
          if (agent != 'studio') return;
          liveFor(kMainAgent).text += delta;
          _paintSoon();
        },
        onReasoning: (agent, delta) {
          if (agent != 'studio') return;
          liveFor(kMainAgent).reasoning += delta;
          _paintSoon();
        },
        onToolStart: (agent, call) {
          if (agent == 'studio') liveFor(kMainAgent).activeCalls[call.id] = call;
          _paintSoon();
        },
        onToolEnd: (agent, call, result) {
          liveFor(kMainAgent).activeCalls.remove(call.id);
          _save();
          _paintSoon();
        },
        onMessage: (agent, message) {
          if (agent != 'studio') return;
          // The words are in the transcript now; the live copy starts over for
          // the next turn.
          if (message.role == AgentRole.assistant) {
            liveFor(kMainAgent).clearWords();
          }
          _save();
          _paintSoon();
        },
      );

  // --- sub-agents ------------------------------------------------------------

  /// How many sub-agents are working now, and who is waiting for a place.
  int _tasksRunning = 0;
  final List<Completer<void>> _taskQueue = <Completer<void>>[];

  /// Whether any sub-agent is working right now.
  bool get anySubagentRunning => session.subagents.any((a) => a.running);

  /// The plan of the agent named [agentId] ([kMainAgent] or a sub-agent's
  /// id), from its `todo_write` calls.
  List<StudioTodo> todosFor(String agentId) => agentId == kMainAgent
      ? session.todos
      : subagent(agentId)?.todos ?? const <StudioTodo>[];

  /// The sub-agent a `task` call started (or carried on), if any.
  StudioSubagent? subagentForCall(String callId) {
    for (final a in session.subagents) {
      if (a.callId == callId || a.resumeCallIds.contains(callId)) return a;
    }
    return null;
  }

  Future<void> _takeTaskPlace() async {
    while (_tasksRunning >= state.studioConfig.maxParallelSubagents) {
      final turn = Completer<void>();
      _taskQueue.add(turn);
      await turn.future;
    }
    _tasksRunning++;
  }

  void _giveTaskPlace() {
    _tasksRunning--;
    if (_taskQueue.isNotEmpty) _taskQueue.removeAt(0).complete();
  }

  /// Runs one sub-agent for a `task` call: a fresh agent with its own
  /// conversation, or — with [taskId] — the one that already has that id,
  /// carried on with the new prompt. Waits for a place when
  /// [StudioConfig.maxParallelSubagents] are already working.
  Future<StudioTaskOutcome> _runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  }) async {
    final lead = _lead;
    StudioTaskOutcome ended(String label, String id, String status, String report) =>
        StudioTaskOutcome(label: label, taskId: id, status: status, report: report);
    if (lead == null || lead.cancelled) {
      return ended('', '', 'cancelled', 'The run was stopped before this task began.');
    }
    StudioSubagent? agent;
    if (taskId != null) {
      agent = subagent(taskId);
      if (agent == null) {
        final known = session.subagents.map((a) => '${a.id} (${a.label})');
        return ended('', taskId, 'failed',
            'No sub-agent has task_id "$taskId". '
            '${known.isEmpty ? 'None exist yet; leave task_id out to start one.' : 'Known: ${known.join(', ')}.'}');
      }
      if (agent.running) {
        return ended(agent.label, agent.id, 'failed',
            '${agent.label} is still working; wait for its report first.');
      }
    }
    await _takeTaskPlace();
    try {
      if (lead.cancelled) {
        return ended(agent?.label ?? '', agent?.id ?? '', 'cancelled',
            'The run was stopped before this task began.');
      }
      final StudioSubagent sub;
      if (agent == null) {
        final number = session.subagents.length + 1;
        sub = StudioSubagent(
          id: '${DateTime.now().microsecondsSinceEpoch}-$number',
          number: number,
          description: description,
          prompt: prompt,
          callId: callId,
          role: agentType,
          transcript: [AgentMessage.user(prompt)],
        );
        session.subagents.add(sub);
      } else {
        sub = agent
          ..transcript.add(AgentMessage.user(prompt))
          ..resumeCallIds.add(callId)
          ..status = StudioAgentStatus.running
          ..startedAt = DateTime.now()
          ..endedAt = null
          ..report = null;
      }
      _save();
      notifyListeners();
      return await _runSubagent(lead, sub);
    } finally {
      _giveTaskPlace();
    }
  }

  Future<StudioTaskOutcome> _runSubagent(AgentRunner lead, StudioSubagent sub) async {
    final services = _AppStudioServices(this)..lead = lead;
    final live = liveFor(sub.id)..clearWords();
    final child = AgentRunner(
      name: sub.id,
      systemPrompt: studioAgentPrompt(sub.role),
      tools: studioToolsFor(sub.role),
      context: StudioToolContext(
        session: session,
        services: services,
        agent: sub.label,
        subagent: sub,
      ),
      turn: (client, messages, tools) => state.streamAgentTurn(
        client: client,
        messages: messages,
        tools: tools,
        onSpend: (usage, cost) {
          sub
            ..inputTokens += usage.inputTokens
            ..outputTokens += usage.outputTokens;
          session.addUsage(usage, cost);
          _paintSoon();
        },
      ),
      maxSteps: state.studioConfig.maxSteps,
      observer: AgentObserver(
        onText: (_, delta) {
          live.text += delta;
          _paintSoon();
        },
        onReasoning: (_, delta) {
          live.reasoning += delta;
          _paintSoon();
        },
        onToolStart: (_, call) {
          live.activeCalls[call.id] = call;
          _paintSoon();
        },
        onToolEnd: (_, call, _) {
          live.activeCalls.remove(call.id);
          _save();
          _paintSoon();
        },
        onMessage: (_, message) {
          if (message.role == AgentRole.assistant) live.clearWords();
          _save();
          _paintSoon();
        },
      ),
    );
    String report;
    try {
      final outcome = await lead.runChild(child, sub.transcript);
      final said = outcome.lastText.trim();
      switch (outcome.end) {
        case AgentRunEnd.finished:
          sub.status = StudioAgentStatus.done;
          report = said.isEmpty ? 'Done (it gave no report).' : said;
        case AgentRunEnd.stepLimit:
          sub.status = StudioAgentStatus.done;
          report = 'Stopped at the step limit. '
              '${said.isEmpty ? '' : 'Its account: $said'}';
        case AgentRunEnd.cancelled:
          sub.status = StudioAgentStatus.cancelled;
          report = 'Stopped by the user.${said.isEmpty ? '' : ' Partial report: $said'}';
      }
    } on ChatApiException catch (e) {
      sub.status = StudioAgentStatus.failed;
      report = 'It failed: ${e.message}';
    } catch (e) {
      sub.status = StudioAgentStatus.failed;
      report = 'It failed: $e';
    }
    sub
      ..report = report.trim()
      ..endedAt = DateTime.now();
    live
      ..clearWords()
      ..activeCalls.clear();
    _save();
    _paintSoon();
    return StudioTaskOutcome(
      label: sub.label,
      taskId: sub.id,
      status: sub.status.name,
      report: sub.report!,
    );
  }

  // --- the draft ---------------------------------------------------------------

  /// Puts the draft back to before the change at [index], and tells the agent
  /// so it does not build on what is gone.
  Future<void> rewindTo(int index) async {
    if (running) return;
    final undone = session.rewindTo(index);
    if (undone.isEmpty) return;
    session.transcript.add(AgentMessage.user(
      '[Studio note] The user rewound the draft, undoing: '
      '${undone.join('; ')}. Call get_draft before making further changes.',
    ));
    session.updatedAt = DateTime.now();
    _save();
    notifyListeners();
  }

  /// A change the user makes by hand, recorded like any other.
  void editByHand(String summary, void Function(StudioWorkspace ws) change) {
    session.edit('manual', summary, change);
    _handEdits.add(summary.replaceFirst(RegExp(r' by hand$'), ''));
    _save();
    notifyListeners();
  }

  void rename(String title) {
    session.title = title.trim();
    session.updatedAt = DateTime.now();
    _save();
    notifyListeners();
  }

  /// Writes the draft into the library: the character (in place, when the
  /// session was opened from one or applied before), every lorebook by id, the
  /// documents when embeddings are on, and — with [bundleFolder] — a folder
  /// holding all of it.
  Future<StudioApplyResult> apply({bool bundleFolder = false}) async {
    final ws = session.workspace.clone();
    final character = ws.character;
    // A book removed from the draft stays attached to nothing it is not in.
    character.lorebookIds.removeWhere(
      (id) => ws.lorebook(id) == null && state.lorebookById(id) == null,
    );
    for (final book in ws.lorebooks) {
      await state.saveLorebook(book);
    }
    await state.saveCharacter(character);

    var documents = 0;
    var skipped = 0;
    final documentIds = <String>[];
    for (final doc in session.workspace.documents) {
      if (!state.embeddingReady) {
        skipped++;
        continue;
      }
      final existing = state.documentById(doc.libraryId);
      if (existing != null) {
        await state.reindexDocument(existing.id, text: doc.text, name: doc.name);
        documentIds.add(existing.id);
      } else {
        final record = await state.importDocument(
          DocumentText(
            name: doc.name,
            text: doc.text,
            source: DocSource.paste,
            origin: 'Character Studio',
          ),
          tags: [if (character.name.trim().isNotEmpty) character.name.trim()],
        );
        if (record == null) {
          skipped++;
          continue;
        }
        doc.libraryId = record.id;
        documentIds.add(record.id);
      }
      documents++;
    }

    String? folderName;
    if (bundleFolder) {
      final existing = session.folderId == null
          ? null
          : state.folders.where((f) => f.id == session.folderId).firstOrNull;
      final folder = existing ??
          Folder(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: character.displayName,
            description: character.title.trim().isNotEmpty
                ? character.title.trim()
                : 'Made in the Character Studio.',
          );
      void addAll(List<String> into, Iterable<String> ids) {
        for (final id in ids) {
          if (!into.contains(id)) into.add(id);
        }
      }

      addAll(folder.characterIds, [character.id]);
      addAll(folder.lorebookIds, ws.lorebooks.map((b) => b.id));
      addAll(folder.documentIds, documentIds);
      await state.saveFolder(folder);
      session.folderId = folder.id;
      folderName = folder.name;
    }

    session.appliedAt = DateTime.now();
    session.appliedSinceChange = true;
    session.updatedAt = DateTime.now();
    _save();
    notifyListeners();
    return StudioApplyResult(
      characterName: character.displayName,
      lorebooks: ws.lorebooks.length,
      documents: documents,
      documentsSkipped: skipped,
      folderName: folderName,
    );
  }

  // --- plumbing -----------------------------------------------------------------

  /// Saves the session, one write at a time, so two quick saves cannot race
  /// each other's temporary file.
  void _save() {
    _saving = _saving
        .then((_) => store.save(session))
        .catchError((Object e) => debugPrint('MaiChat: studio save failed ($e)'));
  }

  /// Waits for every save asked for so far. For tests, and for leaving.
  Future<void> flush() => _saving;

  /// Repaints on a cadence, not per delta, as the chat does.
  void _paintSoon() {
    if (_disposed || _paint != null) return;
    _paint = Timer(const Duration(milliseconds: 80), () {
      _paint = null;
      if (!_disposed) notifyListeners();
    });
  }

  static String _titleFrom(String message) {
    final flat = message.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 40 ? flat : '${flat.substring(0, 40)}…';
  }

  @override
  void dispose() {
    _disposed = true;
    _paint?.cancel();
    _lead?.cancel();
    super.dispose();
  }
}

/// A one-line account of a tool call, for chips and helper progress.
String describeCall(ToolCall call) {
  final a = call.arguments;
  String quoted(Object? v) {
    final s = (v ?? '').toString().replaceAll(RegExp(r'\s+'), ' ').trim();
    return s.length <= 40 ? s : '${s.substring(0, 40)}…';
  }

  return switch (call.name) {
    'get_draft' => 'Read the draft',
    'set_fields' => 'Set ${a.keys.map((k) => k.replaceAll('_', ' ')).join(', ')}',
    'edit_field' => 'Edited ${quoted(a['field']).replaceAll('_', ' ')}',
    'add_greeting' => 'Added a greeting',
    'remove_greeting' => 'Removed a greeting',
    'upsert_scenario' => 'Scenario "${quoted(a['name'])}"',
    'delete_scenario' => 'Deleted a scenario',
    'create_lorebook' => 'Created lorebook "${quoted(a['name'])}"',
    'update_lorebook' => 'Updated a lorebook',
    'delete_lorebook' => 'Removed a lorebook',
    'upsert_lore_entry' =>
      'Lore: ${quoted(a['name'] ?? (a['keys'] is List && (a['keys'] as List).isNotEmpty ? (a['keys'] as List).first : 'entry'))}',
    'delete_lore_entry' => 'Deleted a lore entry',
    'upsert_document' => 'Document "${quoted(a['name'])}"',
    'read_document' => 'Read a document',
    'delete_document' => 'Removed a document',
    'generate_avatar' => 'Painting a portrait',
    'playtest' => 'Playtest',
    'list_library' => 'Looked through the library',
    'read_library_item' => 'Read a library ${quoted(a['kind'])}',
    'attach_library_lorebook' => 'Attached a library lorebook',
    'task' =>
      '${studioAgentTypeLabel((a['agent_type'] ?? 'general').toString())} — ${quoted(a['description'])}',
    'todo_write' => _planLine(a['todos']),
    // Sessions from before `task` replaced it still show sensibly.
    'delegate' => '${quoted(a['helper']).replaceAll('_', ' ')}: ${quoted(a['task'])}',
    _ => call.name,
  };
}

String _planLine(Object? todos) {
  if (todos is! List) return 'Updated the plan';
  final done = todos.where((t) => t is Map && t['status'] == 'completed').length;
  return 'Updated the plan ($done/${todos.length} done)';
}

/// [StudioServices] over the real app.
class _AppStudioServices implements StudioServices {
  _AppStudioServices(this.controller);

  final StudioController controller;
  AgentRunner? lead;

  AppState get _state => controller.state;

  @override
  int countTokens(String text) => _state.estimateTokens(text);

  @override
  List<Character> get libraryCharacters => _state.characters;

  @override
  List<Lorebook> get libraryLorebooks => _state.lorebooks;

  @override
  bool get canGenerateImages => _state.imageGenReady;

  @override
  Future<String> generatePicture({
    required String prompt,
    required String characterId,
  }) async {
    final images = await _state.generateImages(
      prompt: prompt,
      characterId: characterId,
    );
    return images.first.image;
  }

  @override
  Future<List<String>> playtest({
    required Character character,
    required List<Lorebook> lorebooks,
    required List<String> userTurns,
    int greetingIndex = 0,
  }) {
    final client = ChatClient();
    // A stop has to reach a playtest that is mid-reply, too.
    final watcher = Timer.periodic(const Duration(milliseconds: 200), (t) {
      if (lead?.cancelled ?? false) {
        client.cancel();
        t.cancel();
      }
    });
    return _state
        .playtestCharacter(
          character: character,
          lorebooks: lorebooks,
          userTurns: userTurns,
          greetingIndex: greetingIndex,
          client: client,
        )
        .whenComplete(watcher.cancel);
  }

  @override
  Future<StudioTaskOutcome> runTask({
    required String agentType,
    required String description,
    required String prompt,
    required String callId,
    String? taskId,
  }) =>
      controller._runTask(
        agentType: agentType,
        description: description,
        prompt: prompt,
        callId: callId,
        taskId: taskId,
      );
}

/// Keeps open sessions' controllers alive across screens. A controller is made
/// on first open and kept while its agent runs; an idle one is let go when its
/// screen closes.
class StudioHub {
  StudioHub._();

  static final StudioHub instance = StudioHub._();

  final Map<String, StudioController> _open = <String, StudioController>{};

  StudioController? find(String sessionId) => _open[sessionId];

  StudioController open({
    required AppState state,
    required StudioStore store,
    required StudioSession session,
  }) =>
      _open.putIfAbsent(
        session.id,
        () => StudioController(state: state, store: store, session: session),
      );

  /// Called when a session's screen closes: an idle controller is disposed,
  /// a running one is kept so its agent can finish.
  void release(String sessionId) {
    final controller = _open[sessionId];
    if (controller == null || controller.running) return;
    _open.remove(sessionId);
    unawaited(controller.flush().whenComplete(controller.dispose));
  }

  /// Stops and forgets a session, for deleting it.
  Future<void> close(String sessionId) async {
    final controller = _open.remove(sessionId);
    if (controller == null) return;
    controller.stop();
    await controller.flush();
    controller.dispose();
  }

  /// Whether any session's agent is working (the list shows a badge).
  bool isRunning(String sessionId) => _open[sessionId]?.running ?? false;
}

/// A session for a new character.
StudioSession newStudioSession() {
  final now = DateTime.now();
  return StudioSession(
    id: now.microsecondsSinceEpoch.toString(),
    title: '',
    workspace: StudioWorkspace(
      character: Character(id: '${now.microsecondsSinceEpoch}', name: ''),
    ),
  );
}

/// A session that edits [character] from the library, with its lorebooks.
StudioSession studioSessionFor(AppState state, Character character) {
  final now = DateTime.now();
  return StudioSession(
    id: now.microsecondsSinceEpoch.toString(),
    title: character.displayName,
    sourceCharacterId: character.id,
    appliedSinceChange: true,
    workspace: StudioWorkspace(
      character: character.clone(),
      lorebooks: [for (final b in state.lorebooksOf(character)) b.copyWith()],
    ),
  );
}

/// What the Changes tab says a change was made by.
String changeAuthor(StudioOp op) {
  if (op.tool == 'manual') return 'You';
  final at = op.tool.indexOf(' · ');
  return at == -1 ? 'Studio' : op.tool.substring(0, at).replaceAll('_', ' ');
}
