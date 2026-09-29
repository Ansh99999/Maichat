import 'dart:async';
import 'dart:convert';

import '../../models/agent_message.dart';
import '../../models/studio.dart';
import '../agent_client.dart';
import '../chat_client.dart';
import 'studio_tools.dart';

/// One model turn: stream the reply to [messages] over [client], offering
/// [tools]. The Studio passes `AppState.streamAgentTurn`, which meters it;
/// tests pass a script.
typedef AgentTurn = Stream<AgentDelta> Function(
  AgentClient client,
  List<AgentMessage> messages,
  List<ToolSpec> tools,
);

/// What an agent run tells whoever is watching it. Every callback names the
/// [agent] — `studio` for the lead, a helper's name otherwise — because helpers
/// run inside the lead's turn and their activity is shown under it.
class AgentObserver {
  const AgentObserver({
    this.onText,
    this.onReasoning,
    this.onToolStart,
    this.onToolEnd,
    this.onMessage,
    this.onCompacted,
  });

  final void Function(String agent, String delta)? onText;
  final void Function(String agent, String delta)? onReasoning;
  final void Function(String agent, ToolCall call)? onToolStart;
  final void Function(String agent, ToolCall call, AgentMessage result)? onToolEnd;

  /// A finished turn or tool result was added to the transcript.
  final void Function(String agent, AgentMessage message)? onMessage;

  /// The agent's earlier conversation was just summarised.
  final void Function(String agent, StudioCompaction compaction)? onCompacted;
}

/// How a run ended.
enum AgentRunEnd {
  /// The model answered without asking for a tool.
  finished,

  /// It was still working when it hit the step ceiling.
  stepLimit,

  /// The user stopped it.
  cancelled,
}

class AgentRunOutcome {
  const AgentRunOutcome(this.end, this.lastText);

  final AgentRunEnd end;

  /// The last thing the model said in words — a helper's report.
  final String lastText;
}

/// Tool output older than this many turns is shortened on the wire (the
/// transcript keeps it whole): a draft read three edits ago is stale anyway, and
/// long sessions otherwise resend every `get_draft` they ever made.
const int kFreshToolTurns = 2;
const int _staleToolChars = 400;

/// What the model is told on its last allowed step, sent with no tools so it
/// can only answer in words (OpenCode's max-steps prompt, in spirit).
const String kStepLimitNote =
    '[Studio note] You have reached the step limit for this message, so tools '
    'are switched off. Reply in words only: summarise what was done, what '
    'remains, and what the user should do next (for example, reply "continue").';

/// How an agent keeps its requests inside its model's context: Claude Code's
/// auto-compact. Before each model call the request is measured; once it
/// passes [threshold] of [budget], the older part of the conversation is
/// summarised by the model itself and only the summary is sent in its place.
class AgentCompactor {
  const AgentCompactor({
    required this.budget,
    required this.compactions,
    this.estimate = roughTokens,
    this.threshold = kCompactThreshold,
    this.keep = kCompactKeep,
  });

  /// The request size, in tokens, the model can take.
  final int budget;

  /// Where this agent's summaries are kept (the session's, or its
  /// sub-agent's), newest last. The runner appends to it.
  final List<StudioCompaction> compactions;

  /// How many tokens a piece of text is.
  final int Function(String text) estimate;

  /// The share of [budget] a request may reach before it is compacted.
  final double threshold;

  /// The share of [budget] the newest turns may keep, verbatim, after it.
  final double keep;

  StudioCompaction? get latest => compactions.isEmpty ? null : compactions.last;

  /// Four characters to a token: the fallback when no tokenizer is handed in.
  static int roughTokens(String text) => (text.length / 4).ceil();

  /// How many tokens [message] costs on the wire, near enough.
  int cost(AgentMessage message) {
    var n = estimate(message.text) + 4;
    for (final call in message.toolCalls) {
      n += estimate(call.name) + estimate(jsonEncode(call.arguments)) + 4;
    }
    // A picture is priced like a modest block of text; its bytes are not.
    return n + message.images.length * 800;
  }

  int costOf(Iterable<AgentMessage> messages) =>
      messages.fold(0, (n, m) => n + cost(m));
}

/// Past this share of the budget a request is compacted.
const double kCompactThreshold = 0.75;

/// The share of the budget the newest turns keep, verbatim, after a
/// compaction.
const double kCompactKeep = 0.3;

/// The note a compaction's summary is sent as, in place of what it covers.
String compactionNote(String summary) =>
    '[Studio note] Summary of earlier conversation (older turns were '
    'summarised to save space; call get_draft for the draft as it is now):\n'
    '$summary';

/// What the model is told when asked to summarise its own conversation.
const String kCompactionPrompt =
    'You are summarising your own working session so that you can carry on '
    'after the older part of it is dropped. Write the summary for yourself, not '
    'for the user. Cover, in short plain sections:\n'
    '- Goals: what the user wants, in their own terms, and any preferences or '
    'rules they have stated.\n'
    '- Decisions: what has been settled and why.\n'
    '- The draft: its key facts as they stand (the draft can be re-read with '
    'get_draft, so do not copy fields out in full).\n'
    '- Sub-agents: which were started, their task_ids and where they stand.\n'
    '- Open work: unfinished todos and what you were about to do next.\n'
    'Be specific and brief. Reply with the summary only.';

/// Runs one agent: ask the model, run the tools it calls, hand back the
/// results, and repeat until it answers in words, runs out of steps, or is
/// stopped.
///
/// Every call is answered — with its result, an error, or "cancelled" — before
/// the run returns. A transcript left holding a call with no result is one no
/// dialect will accept again, so a stop can never leave the session unusable.
class AgentRunner {
  AgentRunner({
    required this.name,
    required this.systemPrompt,
    required this.tools,
    required this.context,
    required this.turn,
    this.maxSteps = 40,
    this.observer = const AgentObserver(),
    this.takeInbox,
    this.inboxWaiting,
    this.compactor,
  });

  final String name;
  final String systemPrompt;
  final List<StudioTool> tools;
  final StudioToolContext context;
  final AgentTurn turn;
  final int maxSteps;
  final AgentObserver observer;

  /// Messages that arrived while the agent worked — the user steering it, a
  /// background sub-agent's report — taken in at each step boundary: after
  /// the current turn's tool results, before the next model call. Also asked
  /// when the agent answers in words, so a message that arrives at the very
  /// end is still answered in this run.
  final List<AgentMessage> Function()? takeInbox;

  /// Whether anything is waiting to be taken in by [takeInbox], without taking
  /// it.
  final bool Function()? inboxWaiting;

  /// Keeps the requests inside the model's context, when given.
  final AgentCompactor? compactor;

  final Set<AgentClient> _clients = <AgentClient>{};
  final Set<AgentRunner> _children = <AgentRunner>{};
  bool _cancelled = false;
  final Completer<void> _cancelledSignal = Completer<void>();

  /// The transcript length at which compaction last found nothing it could
  /// summarise, so it is not asked again every step until the conversation
  /// has grown.
  int _compactGaveUpAt = -1;

  bool get cancelled => _cancelled;

  /// Completes when the run is stopped — for waits that must end with it.
  Future<void> get whenCancelled => _cancelledSignal.future;

  /// Stops the run and every helper it started. Safe to call at any time.
  void cancel() {
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
    _cancelled = true;
    for (final client in _clients.toList()) {
      client.cancel();
    }
    for (final child in _children.toList()) {
      child.cancel();
    }
  }

  /// Starts [child] as part of this run, so stopping this stops it too.
  Future<AgentRunOutcome> runChild(
    AgentRunner child,
    List<AgentMessage> transcript,
  ) async {
    _children.add(child);
    if (_cancelled) child.cancel();
    try {
      return await child.run(transcript);
    } finally {
      _children.remove(child);
    }
  }

  Future<AgentRunOutcome> run(List<AgentMessage> transcript) async {
    final specs = [for (final t in tools) t.spec];
    final byName = {for (final t in tools) t.name: t};
    var lastText = '';
    for (var step = 0; step < maxSteps; step++) {
      if (_cancelled) return AgentRunOutcome(AgentRunEnd.cancelled, lastText);
      _takeInbox(transcript);
      // The last allowed step (after at least one working one) goes out with
      // no tools and a note asking for a summary, so a run that hits the
      // ceiling still ends with an account of where it got to.
      final last = step == maxSteps - 1 && step > 0;
      if (last) {
        final note = AgentMessage.user(kStepLimitNote);
        transcript.add(note);
        observer.onMessage?.call(name, note);
      }
      await _compactIfNeeded(transcript);
      if (_cancelled) return AgentRunOutcome(AgentRunEnd.cancelled, lastText);
      final client = AgentClient();
      _clients.add(client);
      final text = StringBuffer();
      final reasoning = StringBuffer();
      final calls = <ToolCall>[];
      try {
        await for (final delta in turn(
          client,
          request(transcript),
          last ? const <ToolSpec>[] : specs,
        )) {
          if (delta.text.isNotEmpty) {
            text.write(delta.text);
            observer.onText?.call(name, delta.text);
          }
          if (delta.reasoning.isNotEmpty) {
            reasoning.write(delta.reasoning);
            observer.onReasoning?.call(name, delta.reasoning);
          }
          calls.addAll(delta.toolCalls);
        }
      } on ChatApiException {
        // A stop closes the connection, which surfaces as a transport error;
        // keep whatever was written and end quietly.
        if (!_cancelled) rethrow;
      } finally {
        _clients.remove(client);
      }
      // A cancelled stream may have yielded calls; a call with no result
      // would poison the transcript, so a stop mid-stream keeps words only.
      // A model that calls a tool on the summary step (it was offered none)
      // is held to words the same way.
      if (_cancelled || last) calls.clear();
      final said = text.toString().trim();
      if (said.isNotEmpty) lastText = said;
      if (said.isEmpty && calls.isEmpty) {
        if (_cancelled) return AgentRunOutcome(AgentRunEnd.cancelled, lastText);
        if (last) return AgentRunOutcome(AgentRunEnd.stepLimit, lastText);
        // A message that arrived while it answered is answered now.
        if (_hasInbox()) continue;
        // A turn with no words and no calls (thinking alone, or nothing) is an
        // answer too, but it is not recorded: resending an empty assistant
        // turn is something several hosts reject outright.
        return AgentRunOutcome(AgentRunEnd.finished, lastText);
      }
      final assistant = AgentMessage(
        role: AgentRole.assistant,
        text: said,
        reasoning: reasoning.toString().trim(),
        toolCalls: calls,
      );
      transcript.add(assistant);
      observer.onMessage?.call(name, assistant);
      if (_cancelled) return AgentRunOutcome(AgentRunEnd.cancelled, lastText);
      if (last) return AgentRunOutcome(AgentRunEnd.stepLimit, lastText);
      if (calls.isEmpty) {
        // Answered in words — unless something arrived meanwhile, which the
        // next step takes in and answers.
        if (_hasInbox()) continue;
        return AgentRunOutcome(AgentRunEnd.finished, lastText);
      }

      // All of a turn's calls run together: helpers asked for side by side
      // really do work side by side, and every edit is atomic on its own.
      final results = await Future.wait([
        for (final call in calls) _runCall(call, byName[call.name]),
      ]);
      for (final result in results) {
        transcript.add(result);
        observer.onMessage?.call(name, result);
      }
    }
    return AgentRunOutcome(AgentRunEnd.stepLimit, lastText);
  }

  bool _hasInbox() => inboxWaiting?.call() ?? false;

  void _takeInbox(List<AgentMessage> transcript) {
    final arrived = takeInbox?.call();
    if (arrived == null || arrived.isEmpty) return;
    for (final message in arrived) {
      transcript.add(message);
      observer.onMessage?.call(name, message);
    }
  }

  /// The request for the next model call: the system prompt, the newest
  /// summary (when the conversation has been compacted) in place of what it
  /// covers, then the rest of the transcript as [wireView] sends it.
  List<AgentMessage> request(List<AgentMessage> transcript) {
    final latest = compactor?.latest;
    final from = latest == null
        ? 0
        : latest.upTo.clamp(0, transcript.length);
    return [
      AgentMessage.system(systemPrompt),
      if (latest != null) AgentMessage.user(compactionNote(latest.summary)),
      ...wireView(from == 0 ? transcript : transcript.sublist(from)),
    ];
  }

  /// Summarises the older part of [transcript] when the next request would
  /// pass the compactor's threshold.
  Future<void> _compactIfNeeded(List<AgentMessage> transcript) async {
    final compactor = this.compactor;
    if (compactor == null || _compactGaveUpAt == transcript.length) return;
    final size = compactor.costOf(request(transcript)) +
        compactor.estimate(systemPrompt);
    if (size <= compactor.budget * compactor.threshold) return;
    final from = compactor.latest?.upTo ?? 0;
    final upTo = compactionBoundary(
      transcript,
      from: from,
      keepTokens: (compactor.budget * compactor.keep).floor(),
      cost: compactor.cost,
    );
    if (upTo == null) {
      _compactGaveUpAt = transcript.length;
      return;
    }
    final client = AgentClient();
    _clients.add(client);
    final summary = StringBuffer();
    try {
      await for (final delta in turn(
        client,
        [
          AgentMessage.system(kCompactionPrompt),
          AgentMessage.user(renderForSummary(
            transcript.sublist(from, upTo),
            previous: compactor.latest?.summary,
          )),
        ],
        const <ToolSpec>[],
      )) {
        summary.write(delta.text);
      }
    } on ChatApiException {
      // A failed summary is not a failed run: the request goes out whole and
      // the host says whether it fits.
      if (!_cancelled) _compactGaveUpAt = transcript.length;
      return;
    } finally {
      _clients.remove(client);
    }
    final text = summary.toString().trim();
    if (_cancelled || text.isEmpty) {
      _compactGaveUpAt = transcript.length;
      return;
    }
    final record = StudioCompaction(summary: text, upTo: upTo, tokensBefore: size);
    compactor.compactions.add(record);
    observer.onCompacted?.call(name, record);
  }

  /// Where a compaction of `transcript[from..]` should end: the newest turns
  /// worth [keepTokens] stay verbatim, and the boundary is always the start of
  /// a turn — never between a tool call and its result, which would leave a
  /// result with no call on the wire. Null when there is nothing worth
  /// summarising.
  static int? compactionBoundary(
    List<AgentMessage> transcript, {
    required int from,
    required int keepTokens,
    required int Function(AgentMessage) cost,
  }) {
    if (transcript.length - from < 3) return null;
    var kept = 0;
    var boundary = transcript.length;
    while (boundary > from + 1) {
      final next = kept + cost(transcript[boundary - 1]);
      if (next > keepTokens) break;
      kept = next;
      boundary--;
    }
    // Keep at least the newest turn: the model has to see what it is
    // answering.
    if (boundary >= transcript.length) boundary = transcript.length - 1;
    // A tool result belongs with the call before it: step back to that call.
    while (boundary > from && transcript[boundary].role == AgentRole.tool) {
      boundary--;
    }
    if (boundary - from < 2) return null;
    return boundary;
  }

  /// [messages] as one plain-text log for the summariser: tool traffic is
  /// written out in words (so the request carries no tool blocks, which some
  /// dialects refuse without tools on offer), and long tool output is cut.
  static String renderForSummary(
    List<AgentMessage> messages, {
    String? previous,
  }) {
    final out = StringBuffer();
    if (previous != null && previous.trim().isNotEmpty) {
      out
        ..writeln('Your summary of the conversation before this part:')
        ..writeln(previous.trim())
        ..writeln();
    }
    out.writeln('The conversation to summarise:');
    for (final m in messages) {
      switch (m.role) {
        case AgentRole.user:
          out.writeln('USER: ${m.text}');
          if (m.images.isNotEmpty) {
            out.writeln('  (${m.images.length} picture(s) attached)');
          }
        case AgentRole.assistant:
          if (m.text.isNotEmpty) out.writeln('YOU: ${m.text}');
          for (final c in m.toolCalls) {
            out.writeln('YOU CALLED ${c.name} ${shortenMiddle(jsonEncode(c.arguments))}');
          }
        case AgentRole.tool:
          out.writeln('${m.isError ? 'ERROR' : 'RESULT'} (${m.toolName}): '
              '${shortenMiddle(m.text)}');
        case AgentRole.system:
          break;
      }
    }
    out
      ..writeln()
      ..writeln('Summarise it as instructed.');
    return out.toString();
  }

  Future<AgentMessage> _runCall(ToolCall call, StudioTool? tool) async {
    observer.onToolStart?.call(name, call);
    AgentMessage result;
    if (_cancelled) {
      result = AgentMessage.toolResult(call, 'Cancelled by the user.', isError: true);
    } else if (tool == null) {
      result = AgentMessage.toolResult(
        call,
        'There is no tool called "${call.name}". Available: '
        '${tools.map((t) => t.name).join(', ')}.',
        isError: true,
      );
    } else if (call.argumentError != null) {
      result = AgentMessage.toolResult(call, call.argumentError!, isError: true);
    } else {
      final out = await tool.call(context.forCall(call), call.arguments);
      result = AgentMessage.toolResult(call, out.text, isError: out.isError);
    }
    observer.onToolEnd?.call(name, call, result);
    return result;
  }

  /// The transcript as it is sent: whole, except that tool output from before
  /// the last [kFreshToolTurns] assistant turns is cut down to its head and
  /// tail with a marker in the middle (the way Codex truncates tool output),
  /// so the model still sees what the result was about and how it ended.
  static List<AgentMessage> wireView(List<AgentMessage> transcript) {
    var assistantsSeen = 0;
    var cutoff = 0;
    for (var i = transcript.length - 1; i >= 0; i--) {
      if (transcript[i].role == AgentRole.assistant &&
          ++assistantsSeen == kFreshToolTurns) {
        cutoff = i;
        break;
      }
    }
    return [
      for (var i = 0; i < transcript.length; i++)
        if (i < cutoff &&
            transcript[i].role == AgentRole.tool &&
            transcript[i].text.length > _staleToolChars)
          AgentMessage.toolResult(
            ToolCall(
              id: transcript[i].toolCallId ?? '',
              name: transcript[i].toolName ?? '',
            ),
            shortenMiddle(transcript[i].text),
            isError: transcript[i].isError,
          )
        else
          transcript[i],
    ];
  }

  /// [text] with its middle cut out, keeping the first and last
  /// [_staleToolChars] / 2 characters and saying how much went.
  static String shortenMiddle(String text) {
    const keep = _staleToolChars ~/ 2;
    if (text.length <= _staleToolChars) return text;
    final cut = text.length - keep * 2;
    // Roughly four characters to a token — only a hint for the model.
    return '${text.substring(0, keep)}\n…${(cut / 4).ceil()} tokens truncated '
        '(older tool output; call the tool again if you need it)…\n'
        '${text.substring(text.length - keep)}';
  }
}
