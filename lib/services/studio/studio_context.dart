import 'dart:convert';

import '../../models/agent_message.dart';
import '../../models/studio.dart';
import '../agent_client.dart';
import 'agent_runner.dart';
import 'custom_agents.dart';
import 'studio_tools.dart';

/// Where the tokens of an agent's next request go, by kind — the rows of the
/// context inspector, in the order the request carries them.
enum StudioContextCategory {
  instructions('Instructions'),
  web('Web guidance'),
  agentTypes('Your agent types'),
  memory('Memory'),
  skills('Skills'),
  tools('Tool definitions'),
  summary('Earlier conversation'),
  conversation('Conversation'),
  toolResults('Tool results'),
  waiting('Waiting to be read'),
  pictures('Pictures');

  const StudioContextCategory(this.label);
  final String label;

  static StudioContextCategory ofPart(StudioPromptPart part) => switch (part) {
        StudioPromptPart.instructions => instructions,
        StudioPromptPart.web => web,
        StudioPromptPart.agentTypes => agentTypes,
        StudioPromptPart.memory => memory,
        StudioPromptPart.skills => skills,
      };
}

/// One thing in the request: a turn, a tool result, a tool's schema, a part
/// of the instructions.
class StudioContextItem {
  const StudioContextItem({
    required this.label,
    required this.preview,
    required this.full,
    required this.tokens,
    this.note,
  });

  final String label;

  /// One line of it, for the folded row.
  final String preview;

  /// All of it, as it is sent.
  final String full;
  final int tokens;

  /// Something worth knowing — "shortened on the wire from 5.2k".
  final String? note;
}

class StudioContextSection {
  const StudioContextSection(this.category, this.items);

  final StudioContextCategory category;
  final List<StudioContextItem> items;

  int get tokens => items.fold(0, (n, i) => n + i.tokens);
}

/// What an agent's next request is made of, and how close it is to the point
/// where its older conversation gets summarised.
class StudioContextReport {
  const StudioContextReport({
    required this.agentId,
    required this.sections,
    required this.budget,
    required this.threshold,
    required this.wouldCompact,
    required this.summarisedTurns,
    this.lastRequest,
  });

  final String agentId;

  /// Only the categories with something in them.
  final List<StudioContextSection> sections;

  /// The request size the agent's model is given (the Studio's context
  /// budget, capped by the model's own window when known).
  final int budget;

  /// The share of [budget] past which the older conversation is summarised.
  final double threshold;

  /// Whether the next step would summarise first.
  final bool wouldCompact;

  /// How many turns the current summary covers (0 without one).
  final int summarisedTurns;

  /// The host's own count of the last request, when it reported one.
  final StudioRequestSize? lastRequest;

  int get total => sections.fold(0, (n, s) => n + s.tokens);

  /// How much of [budget] the request uses, 0..1 (can pass 1).
  double get fraction => budget <= 0 ? 0 : total / budget;

  int get compactAt => (budget * threshold).floor();

  StudioContextSection? section(StudioContextCategory category) {
    for (final s in sections) {
      if (s.category == category) return s;
    }
    return null;
  }
}

/// Everything an agent's next request is built from, assembled by the one
/// function the run itself uses (`StudioController.nextRequestFor`), so the
/// inspector shows what goes out rather than a guess at it.
class StudioAgentRequest {
  const StudioAgentRequest({
    required this.agentId,
    required this.promptParts,
    required this.systemPrompt,
    required this.tools,
    required this.transcript,
    required this.waiting,
    required this.latest,
    required this.messages,
    required this.budget,
    required this.wire,
    this.lastRequest,
  });

  final String agentId;
  final List<(StudioPromptPart, String)> promptParts;
  final String systemPrompt;
  final List<StudioTool> tools;

  /// The agent's conversation, with what is waiting to be read appended as it
  /// will be when the next step takes it in.
  final List<AgentMessage> transcript;

  /// How many of [transcript]'s last turns are waiting rather than read.
  final int waiting;

  /// The summary in force, when the conversation has been compacted.
  final StudioCompaction? latest;

  /// The request's messages, as `AgentRunner.buildRequest` makes them.
  final List<AgentMessage> messages;
  final int budget;

  /// The assembled request, or null when no provider is set up.
  final AgentWireRequest? wire;
  final StudioRequestSize? lastRequest;

  List<ToolSpec> get specs => [for (final t in tools) t.spec];
}

/// Token counts, cached. A turn never changes once it is in a transcript
/// (AgentMessage is immutable), so it is counted once and remembered by
/// identity; a prompt part or a tool schema is remembered by its text.
/// That is what lets the inspector follow a streaming 200-turn session on
/// the UI thread without re-tokenizing the whole of it on every repaint.
class StudioContextCounter {
  StudioContextCounter(this.estimate);

  final int Function(String text) estimate;

  final Expando<_TurnTokens> _turns = Expando<_TurnTokens>('studio-turn-tokens');
  final Expando<int> _specs = Expando<int>('studio-tool-tokens');
  final Map<String, int> _texts = <String, int>{};
  static const int _textCacheMax = 64;

  /// The same per-turn overhead the compactor counts.
  static const int overhead = 4;

  /// How many tokens [text] is, remembered.
  int text(String text) {
    if (text.isEmpty) return 0;
    final cached = _texts.remove(text);
    if (cached != null) {
      _texts[text] = cached;
      return cached;
    }
    final n = estimate(text);
    _texts[text] = n;
    if (_texts.length > _textCacheMax) _texts.remove(_texts.keys.first);
    return n;
  }

  _TurnTokens _of(AgentMessage m) => _turns[m] ??= _TurnTokens(
        text: estimate(m.text),
        calls: [
          for (final c in m.toolCalls)
            estimate(c.name) + estimate(jsonEncode(c.arguments)) + overhead,
        ],
      );

  /// A turn's tokens as the compactor prices it: its words, its calls, a
  /// picture at a flat rate (its bytes are never tokenized), the overhead.
  int turn(AgentMessage m) {
    final t = _of(m);
    return t.text +
        t.calls.fold<int>(0, (n, c) => n + c) +
        m.images.length * kPictureTokens +
        overhead;
  }

  /// A stale tool result's tokens once it is shortened on the wire.
  int shortened(AgentMessage m) {
    final t = _of(m);
    return t.shortened ??=
        estimate(AgentRunner.shortenMiddle(m.text)) + overhead;
  }

  /// A tool's schema, as it rides in every request.
  int tool(ToolSpec spec) => _specs[spec] ??= estimate(jsonEncode({
        'name': spec.name,
        'description': spec.description,
        'parameters': spec.parameters,
      }));

  /// The whole of a request — its messages and its tools — as the Studio
  /// estimates it: what a host's own count is compared with.
  int request(List<AgentMessage> messages, List<ToolSpec> tools) {
    var n = 0;
    for (final m in messages) {
      n += m.role == AgentRole.system ? text(m.text) + overhead : turn(m);
    }
    for (final t in tools) {
      n += tool(t);
    }
    return n;
  }
}

/// What a picture is counted as — the compactor's flat rate.
const int kPictureTokens = 800;

class _TurnTokens {
  _TurnTokens({required this.text, required this.calls});

  final int text;
  final List<int> calls;
  int? shortened;
}

/// The report for [request], counted with [counter].
StudioContextReport buildContextReport(
  StudioAgentRequest request,
  StudioContextCounter counter,
) {
  final byCategory = <StudioContextCategory, List<StudioContextItem>>{};
  void add(StudioContextCategory c, StudioContextItem item) =>
      (byCategory[c] ??= <StudioContextItem>[]).add(item);

  // The instructions, part by part.
  for (final (part, text) in request.promptParts) {
    add(
      StudioContextCategory.ofPart(part),
      StudioContextItem(
        label: switch (part) {
          StudioPromptPart.instructions => 'How it works',
          StudioPromptPart.web => 'Researching the web',
          StudioPromptPart.agentTypes => 'Types you defined',
          StudioPromptPart.memory => 'What it remembers about you',
          StudioPromptPart.skills => 'The skills it can load',
        },
        preview: _line(text),
        full: text,
        tokens: counter.text(text),
      ),
    );
  }

  for (final t in request.tools) {
    add(
      StudioContextCategory.tools,
      StudioContextItem(
        label: t.name,
        preview: _line(t.spec.description),
        full: const JsonEncoder.withIndent('  ').convert({
          'name': t.spec.name,
          'description': t.spec.description,
          'parameters': t.spec.parameters,
        }),
        tokens: counter.tool(t.spec),
      ),
    );
  }

  final transcript = request.transcript;
  final latest = request.latest;
  final from = latest == null ? 0 : latest.upTo.clamp(0, transcript.length);
  if (latest != null) {
    final note = compactionNote(latest.summary);
    add(
      StudioContextCategory.summary,
      StudioContextItem(
        label: 'Summary of $from earlier turn${from == 1 ? '' : 's'}',
        preview: _line(latest.summary),
        full: note,
        tokens: counter.text(note) + StudioContextCounter.overhead,
      ),
    );
  }

  // The rest of the conversation, turn by turn, marked where the wire shortens
  // it. [AgentRunner.wireView] decides which results are shortened; the
  // inspector asks it rather than repeating its rule.
  final kept = from == 0 ? transcript : transcript.sublist(from);
  final wire = AgentRunner.wireView(kept);
  final firstWaiting = transcript.length - request.waiting;
  var pictures = 0;
  // The request's size as the compactor measures it, from the same counts:
  // the instructions twice over (as a turn, and once more on top, as the
  // runner does), the summary, and every turn as the wire sends it.
  final systemTokens = counter.text(request.systemPrompt);
  var size = systemTokens * 2 + StudioContextCounter.overhead;
  if (latest != null) {
    size += counter.text(compactionNote(latest.summary)) +
        StudioContextCounter.overhead;
  }
  for (var i = 0; i < kept.length; i++) {
    final m = kept[i];
    final waiting = from + i >= firstWaiting;
    pictures += m.images.length;
    switch (m.role) {
      case AgentRole.tool:
        final isShort = !identical(wire[i], m);
        final tokens = isShort
            ? counter.shortened(m)
            : counter.turn(m);
        size += tokens;
        add(
          StudioContextCategory.toolResults,
          StudioContextItem(
            label: '${m.isError ? 'Failed · ' : ''}${m.toolName ?? 'result'}',
            preview: _line(m.text),
            full: isShort ? wire[i].text : m.text,
            tokens: tokens,
            note: isShort
                ? 'Shortened on the wire, from ${_k(counter.turn(m))} tokens'
                : null,
          ),
        );
      case AgentRole.user:
      case AgentRole.assistant:
        size += counter.turn(m);
        final isNote = m.role == AgentRole.user && m.text.startsWith('[Studio note]');
        final calls = [for (final c in m.toolCalls) c.name];
        add(
          waiting
              ? StudioContextCategory.waiting
              : StudioContextCategory.conversation,
          StudioContextItem(
            label: m.role == AgentRole.assistant
                ? 'Agent'
                : isNote
                    ? 'Studio note'
                    : 'You',
            preview: m.text.trim().isNotEmpty
                ? _line(m.text)
                : calls.isNotEmpty
                    ? 'Called ${calls.join(', ')}'
                    : '(pictures only)',
            full: [
              if (m.text.trim().isNotEmpty) m.text,
              for (final c in m.toolCalls)
                '${c.name} ${const JsonEncoder.withIndent('  ').convert(c.arguments)}',
            ].join('\n\n'),
            // Pictures are counted on their own row, not in the turn's words.
            tokens: counter.turn(m) - m.images.length * kPictureTokens,
          ),
        );
      case AgentRole.system:
        break;
    }
  }
  if (pictures > 0) {
    add(
      StudioContextCategory.pictures,
      StudioContextItem(
        label: '$pictures picture${pictures == 1 ? '' : 's'}',
        preview: 'Sent as images; counted at about $kPictureTokens tokens each',
        full: 'Pictures are sent as images, not as text. The host prices them '
            'by their size; the Studio counts about $kPictureTokens tokens a '
            'picture, the same rate it uses to decide when to summarise.',
        tokens: pictures * kPictureTokens,
      ),
    );
  }

  const threshold = kCompactThreshold;

  return StudioContextReport(
    agentId: request.agentId,
    sections: [
      for (final c in StudioContextCategory.values)
        if (byCategory[c] != null) StudioContextSection(c, byCategory[c]!),
    ],
    budget: request.budget,
    threshold: threshold,
    wouldCompact: size > request.budget * threshold,
    summarisedTurns: from,
    lastRequest: request.lastRequest,
  );
}

String _line(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
}

String _k(int n) =>
    n >= 1000 ? '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k' : '$n';
