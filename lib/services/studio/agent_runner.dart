import 'dart:async';

import '../../models/agent_message.dart';
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
  });

  final void Function(String agent, String delta)? onText;
  final void Function(String agent, String delta)? onReasoning;
  final void Function(String agent, ToolCall call)? onToolStart;
  final void Function(String agent, ToolCall call, AgentMessage result)? onToolEnd;

  /// A finished turn or tool result was added to the transcript.
  final void Function(String agent, AgentMessage message)? onMessage;
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
  });

  final String name;
  final String systemPrompt;
  final List<StudioTool> tools;
  final StudioToolContext context;
  final AgentTurn turn;
  final int maxSteps;
  final AgentObserver observer;

  final Set<AgentClient> _clients = <AgentClient>{};
  final Set<AgentRunner> _children = <AgentRunner>{};
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  /// Stops the run and every helper it started. Safe to call at any time.
  void cancel() {
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
      final client = AgentClient();
      _clients.add(client);
      final text = StringBuffer();
      final reasoning = StringBuffer();
      final calls = <ToolCall>[];
      try {
        await for (final delta in turn(
          client,
          [AgentMessage.system(systemPrompt), ...wireView(transcript)],
          specs,
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
      if (_cancelled) calls.clear();
      final said = text.toString().trim();
      if (said.isNotEmpty) lastText = said;
      if (said.isEmpty && calls.isEmpty) {
        if (_cancelled) return AgentRunOutcome(AgentRunEnd.cancelled, lastText);
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
      if (calls.isEmpty) return AgentRunOutcome(AgentRunEnd.finished, lastText);

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
      final out = await tool.call(context, call.arguments);
      result = AgentMessage.toolResult(call, out.text, isError: out.isError);
    }
    observer.onToolEnd?.call(name, call, result);
    return result;
  }

  /// The transcript as it is sent: whole, except that tool output from before
  /// the last [kFreshToolTurns] assistant turns is cut short.
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
            '${transcript[i].text.substring(0, _staleToolChars)}… '
            '[older tool output shortened; call the tool again if you need it]',
            isError: transcript[i].isError,
          )
        else
          transcript[i],
    ];
  }
}
