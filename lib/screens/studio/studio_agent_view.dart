import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/agent_message.dart';
import '../../models/studio.dart';
import '../../services/studio/studio_controller.dart';
import '../../services/studio/studio_tools.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/message_markdown.dart';
import '../../widgets/smooth_image.dart';
import '../../widgets/thinking_block.dart';
import 'shell/shell_format.dart';
import 'shell/studio_chrome.dart';

/// One agent's conversation: what it was asked, what it said, and every tool it
/// called, as a chip that opens onto what went in and what came back. The main
/// agent's by default; with [agentId] a sub-agent's, read-only.
///
/// A `task` chip — the main agent spawning a sub-agent — shows that sub-agent's
/// live status and opens its conversation through [onOpenAgent].
class StudioAgentView extends StatefulWidget {
  const StudioAgentView({
    super.key,
    required this.controller,
    this.agentId = kMainAgent,
    this.onOpenAgent,
    this.onPickExample,
  });

  final StudioController controller;
  final String agentId;
  final ValueChanged<String>? onOpenAgent;

  /// An opening picked from the empty state, for the composer to take.
  final ValueChanged<String>? onPickExample;

  @override
  State<StudioAgentView> createState() => _StudioAgentViewState();
}

class _StudioAgentViewState extends State<StudioAgentView>
    with AutomaticKeepAliveClientMixin {
  StudioController get _c => widget.controller;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final items = _items(context);
        if (items.isEmpty && widget.agentId == kMainAgent) {
          return _Intro(onPick: (text) => widget.onPickExample?.call(text));
        }
        // Bottom-anchored like a chat: the newest turn sits above the composer
        // and a growing reply pushes older ones up.
        // The shell's chrome floats over the list: the menu squares at the top,
        // the composer at the bottom. The list runs underneath both, and its
        // padding lets the newest turn rest above the composer and the oldest
        // scroll clear of the squares.
        final chrome = StudioChrome.of(context);
        return ListView.builder(
          key: PageStorageKey<String>('studio-transcript-${widget.agentId}'),
          reverse: true,
          padding: EdgeInsets.fromLTRB(12, chrome.top, 12, chrome.bottom + 12),
          itemCount: items.length,
          itemBuilder: (context, i) => items[items.length - 1 - i],
        );
      },
    );
  }

  List<Widget> _items(BuildContext context) {
    final id = widget.agentId;
    final transcript = _c.transcriptFor(id);
    final live = _c.liveFor(id);
    final subagent = id == kMainAgent ? null : _c.subagent(id);
    final results = <String, AgentMessage>{
      for (final m in transcript)
        if (m.role == AgentRole.tool && m.toolCallId != null) m.toolCallId!: m,
    };
    final running = subagent?.running ?? _c.running;
    final compactions = {
      for (final c in (subagent?.compactions ?? _c.session.compactions))
        c.upTo: c,
    };
    final out = <Widget>[];
    var first = true;
    for (var i = 0; i < transcript.length; i++) {
      final m = transcript[i];
      // Where the agent stopped seeing its older turns verbatim.
      final compaction = compactions[i];
      if (compaction != null) out.add(_CompactionDivider(compaction: compaction));
      switch (m.role) {
        case AgentRole.user:
          final background = _backgroundReport.firstMatch(m.text);
          if (subagent != null && first) {
            out.add(_TaskBrief(subagent: subagent));
          } else if (background != null) {
            out.add(_BackgroundReport(
              label: background.group(1)!,
              taskId: background.group(2)!,
              onOpen: widget.onOpenAgent,
            ));
          } else if (m.text.startsWith('[Studio note]')) {
            out.add(_Note(text: m.text.substring('[Studio note]'.length).trim()));
          } else if (m.text.startsWith(_fromMain)) {
            out.add(_Note(
              text: 'From Main: ${m.text.substring(_fromMain.length).trim()}',
              icon: Icons.forward_to_inbox_outlined,
            ));
          } else {
            out.add(_UserBubble(message: m));
          }
        case AgentRole.assistant:
          if (m.reasoning.isNotEmpty) {
            out.add(ThinkingBlock(reasoning: m.reasoning));
          }
          if (m.text.isNotEmpty) out.add(_AgentText(text: m.text));
          for (final call in m.toolCalls) {
            final spawned =
                call.name == 'task' ? _c.subagentForCall(call.id) : null;
            out.add(_ToolChip(
              key: ValueKey<String>('chip-${call.id}'),
              call: call,
              result: results[call.id],
              running: live.activeCalls.containsKey(call.id) ||
                  (spawned?.running ?? false),
              subagent: spawned,
              onOpenAgent: widget.onOpenAgent,
            ));
          }
        case AgentRole.tool:
        case AgentRole.system:
          break;
      }
      first = false;
    }
    if (running) {
      if (live.reasoning.isNotEmpty) {
        out.add(ThinkingBlock(reasoning: live.reasoning, inProgress: true));
      }
      if (live.text.isNotEmpty) {
        out.add(_AgentText(text: live.text));
      } else if (live.activeCalls.isEmpty) {
        out.add(const _Working());
      }
    }
    if (subagent != null && !subagent.running) {
      out.add(_Outcome(subagent: subagent));
    }
    // Messages that have not been read yet, below what the agent is doing.
    if (subagent == null) {
      for (final q in _c.queued) {
        out.add(_QueuedBubble(
          key: ValueKey<String>('queued-${q.id}'),
          text: q.text,
          pictures: q.images.length,
          onCancel: () => _c.cancelQueued(q.id),
        ));
      }
    } else {
      for (final m in _c.queuedForAgent(subagent.id)) {
        out.add(_Note(
          text: 'Waiting for its next step — from Main: '
              '${m.text.replaceFirst(_fromMain, '').trim()}',
          icon: Icons.schedule_send_outlined,
        ));
      }
    }
    final todos = _c.todosFor(id);
    if (todos.isNotEmpty) out.add(_Plan(todos: todos));
    return out;
  }
}

MarkdownStyles _styles(BuildContext context) {
  final theme = Theme.of(context);
  final scheme = theme.colorScheme;
  final base = (theme.textTheme.bodyMedium ?? const TextStyle())
      .copyWith(color: scheme.onSurface, height: 1.4);
  return MarkdownStyles(
    base: base,
    emphasis: scheme.onSurface,
    quote: scheme.onSurface,
    codeBackground: scheme.surfaceContainerHighest,
    codeForeground: scheme.onSurface,
    link: scheme.primary,
  );
}

class _AgentText extends StatelessWidget {
  const _AgentText({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 24, 8),
        child: SelectableText.rich(
          TextSpan(children: buildMessageSpans(text, _styles(context))),
        ),
      );
}

class _UserBubble extends StatelessWidget {
  const _UserBubble({required this.message});

  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(48, 8, 0, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.images.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: message.text.isEmpty ? 0 : 8),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final image in message.images)
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: SizedBox.square(
                          dimension: 96,
                          child: switch (avatarImage(
                            image.ref,
                            displaySize: 96,
                            devicePixelRatio: dpr,
                          )) {
                            final ImageProvider p =>
                              SmoothImage(image: p, fit: BoxFit.cover),
                            null => ColoredBox(
                                color: scheme.surfaceContainerHighest,
                                child: Icon(Icons.broken_image_outlined,
                                    color: scheme.onSurfaceVariant),
                              ),
                          },
                        ),
                      ),
                  ],
                ),
              ),
            if (message.text.isNotEmpty)
              SelectableText(
                message.text,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onPrimaryContainer),
              ),
          ],
        ),
      ),
    );
  }
}

/// A sub-agent's first message: the task the main agent gave it.
class _TaskBrief extends StatelessWidget {
  const _TaskBrief({required this.subagent});

  final StudioSubagent subagent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Task from Main · ${_roleLabel(subagent.role)}',
            style: theme.textTheme.labelMedium
                ?.copyWith(color: scheme.onTertiaryContainer),
          ),
          const SizedBox(height: 4),
          SelectableText(
            subagent.prompt,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: scheme.onTertiaryContainer),
          ),
        ],
      ),
    );
  }
}

/// How a finished sub-agent ended, and its report.
class _Outcome extends StatelessWidget {
  const _Outcome({required this.subagent});

  final StudioSubagent subagent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final how = switch (subagent.status) {
      StudioAgentStatus.done => 'Finished',
      StudioAgentStatus.failed => 'Failed',
      StudioAgentStatus.cancelled => 'Stopped',
      StudioAgentStatus.running => 'Running',
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Text(
        '$how after ${formatElapsed(subagent.elapsed())} · '
        '${formatTokens(subagent.tokens)} tokens — its report went back to Main.',
        style: muted,
      ),
    );
  }
}

/// The agent's plan from its last `todo_write`: a compact checklist at the foot
/// of its conversation, the step in progress picked out.
class _Plan extends StatelessWidget {
  const _Plan({required this.todos});

  final List<StudioTodo> todos;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = todos.where((t) => t.status == StudioTodoStatus.completed).length;
    return Container(
      key: const Key('studio-plan'),
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Plan · $done of ${todos.length} done',
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: scheme.primary)),
          const SizedBox(height: 6),
          for (final t in todos)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    switch (t.status) {
                      StudioTodoStatus.completed => Icons.check_circle,
                      StudioTodoStatus.inProgress => Icons.radio_button_checked,
                      StudioTodoStatus.pending => Icons.radio_button_unchecked,
                    },
                    size: 16,
                    color: t.status == StudioTodoStatus.pending
                        ? scheme.outline
                        : scheme.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.content,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: t.status == StudioTodoStatus.completed
                            ? scheme.onSurfaceVariant
                            : scheme.onSurface,
                        fontWeight: t.status == StudioTodoStatus.inProgress
                            ? FontWeight.w600
                            : null,
                        decoration: t.status == StudioTodoStatus.completed
                            ? TextDecoration.lineThrough
                            : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The note a background sub-agent's report arrives as (see the controller's
/// `_deliver`): its label and task id.
final RegExp _backgroundReport = RegExp(
  r'^\[Studio note\] (Subagent \d+) \(task_id "([^"]+)"\) finished in the background',
);

/// How a `send_message` from the main agent reads in a sub-agent's chat.
const String _fromMain = '[Message from the main agent]';

class _Note extends StatelessWidget {
  const _Note({required this.text, this.icon = Icons.history});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.outline),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _Working extends StatelessWidget {
  const _Working();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 0, 8),
      child: Row(
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text('Working…',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

String _roleLabel(String role) => studioAgentTypeLabel(role);

IconData _toolIcon(String name) => switch (name) {
      'get_draft' || 'read_document' || 'read_library_item' =>
        Icons.visibility_outlined,
      'set_fields' || 'edit_field' => Icons.edit_note,
      'add_greeting' || 'remove_greeting' => Icons.waving_hand_outlined,
      'upsert_scenario' || 'delete_scenario' => Icons.theaters_outlined,
      'create_lorebook' ||
      'update_lorebook' ||
      'delete_lorebook' ||
      'upsert_lore_entry' ||
      'delete_lore_entry' ||
      'attach_library_lorebook' =>
        Icons.menu_book_outlined,
      'upsert_document' || 'delete_document' => Icons.description_outlined,
      'generate_avatar' => Icons.palette_outlined,
      'search_images' => Icons.image_search_outlined,
      'set_avatar_from_url' => Icons.add_link,
      'list_gallery' || 'use_gallery_picture' => Icons.photo_library_outlined,
      'playtest' => Icons.forum_outlined,
      'list_library' => Icons.local_library_outlined,
      'task' || 'delegate' => Icons.smart_toy_outlined,
      'todo_write' => Icons.checklist,
      _ => Icons.build_outlined,
    };

/// One tool call: a line saying what it did, and — opened — what the agent
/// sent and what came back. A `task` call carries its sub-agent's live status
/// and a way into its conversation.
class _ToolChip extends StatefulWidget {
  const _ToolChip({
    super.key,
    required this.call,
    required this.result,
    required this.running,
    this.subagent,
    this.onOpenAgent,
  });

  final ToolCall call;
  final AgentMessage? result;
  final bool running;
  final StudioSubagent? subagent;
  final ValueChanged<String>? onOpenAgent;

  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip> {
  bool _open = false;

  String _title() {
    final call = widget.call;
    if (call.name == 'task') {
      final type = (call.arguments['agent_type'] ?? widget.subagent?.role ?? '')
          .toString();
      final description = (call.arguments['description'] ??
              widget.subagent?.description ??
              '')
          .toString()
          .trim();
      final who = widget.subagent?.label ?? 'Sub-agent';
      final resumed = widget.subagent != null &&
          widget.subagent!.callId != call.id;
      return '$who · ${_roleLabel(type)}'
          '${description.isEmpty ? '' : ' — $description'}'
          '${resumed ? ' (continued)' : ''}';
    }
    return describeCall(call);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = widget.result;
    final failed = result?.isError ?? false;
    final subagent = widget.subagent;
    final muted = theme.textTheme.bodySmall
        ?.copyWith(color: scheme.onSurfaceVariant);
    Widget status;
    if (widget.running) {
      status = const SizedBox(
        width: 14,
        height: 14,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (result == null) {
      status = Icon(Icons.remove_circle_outline, size: 16, color: scheme.outline);
    } else if (failed) {
      status = Icon(Icons.error_outline, size: 16, color: scheme.error);
    } else {
      status = Icon(Icons.check, size: 16, color: scheme.primary);
    }
    final isTask = widget.call.name == 'task';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: isTask ? scheme.secondaryContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => setState(() => _open = !_open),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(_toolIcon(widget.call.name),
                        size: 18, color: scheme.onSurfaceVariant),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _title(),
                        maxLines: _open ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    status,
                  ],
                ),
                if (subagent != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 2),
                    child: Row(
                      children: [
                        Expanded(
                          child: Ticking(
                            active: subagent.running,
                            builder: (_) => Text(
                              '${formatElapsed(subagent.elapsed())} • '
                              '${formatTokens(subagent.tokens)} tokens'
                              '${subagent.toolCallCount > 0 ? ' • ${subagent.toolCallCount} tool calls' : ''}',
                              style: muted,
                            ),
                          ),
                        ),
                        if (widget.onOpenAgent != null)
                          TextButton.icon(
                            key: Key('open-agent-${subagent.id}'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => widget.onOpenAgent!(subagent.id),
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('Open chat'),
                          ),
                      ],
                    ),
                  ),
                if (result != null && !failed)
                  ..._thumbnails(result.text),
                if (_open) ...[
                  const SizedBox(height: 8),
                  _Detail(label: 'Sent', text: _pretty(widget.call.arguments)),
                  if (result != null)
                    _Detail(
                      label: failed ? 'Failed' : 'Returned',
                      text: _prettyText(result.text),
                    ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The pictures a picture tool found or chose, as a strip of small
  /// thumbnails under the chip — tap one to see it larger. Nothing for any
  /// other tool.
  List<Widget> _thumbnails(String resultText) {
    if (!_pictureTools.contains(widget.call.name)) return const <Widget>[];
    final pictures = pictureRefsOf(resultText);
    if (pictures.isEmpty) return const <Widget>[];
    return [
      Padding(
        padding: const EdgeInsets.only(left: 28, top: 8, bottom: 2),
        child: SizedBox(
          height: 64,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: pictures.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) => _Thumb(
              key: ValueKey('tool-thumb-${widget.call.id}-$i'),
              thumb: pictures[i].thumb,
              full: pictures[i].full,
              label: pictures[i].label,
            ),
          ),
        ),
      ),
    ];
  }

  static const Set<String> _pictureTools = {
    'search_images',
    'set_avatar_from_url',
    'list_gallery',
    'use_gallery_picture',
  };

  static String _pretty(Object value) =>
      const JsonEncoder.withIndent('  ').convert(value);

  /// A tool result, pretty-printed when it is JSON, and shortened: a draft read
  /// can be many screens long.
  static String _prettyText(String text) {
    var out = text;
    try {
      out = _pretty(jsonDecode(text) as Object);
    } catch (_) {}
    return out.length <= 6000 ? out : '${out.substring(0, 6000)}\n…';
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.text});

  final String label;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.primary)),
          const SizedBox(height: 2),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              text,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
            ),
          ),
        ],
      ),
    );
  }
}

/// What an empty session says: what the Studio does, and a few openings to
/// start from.
class _Intro extends StatelessWidget {
  const _Intro({required this.onPick});

  final void Function(String text) onPick;

  static const List<String> _examples = [
    'A retired sea witch who runs a lighthouse on a haunted coast. Slow-burn, '
        'melancholy, a little funny.',
    'A cyberpunk fixer who owes me a favour and hates that she does. Give her '
        'a city lorebook — use 4 sub-agents.',
    'Cozy fantasy: the grumpy dwarf baker in a mountain village, with three '
        'different openings.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = context.watch<AppState>().studioProvider() != null;
    final chrome = StudioChrome.of(context);
    return ListView(
      padding: EdgeInsets.fromLTRB(24, chrome.top + 8, 24, chrome.bottom + 24),
      children: [
        Icon(Icons.auto_awesome, size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text('What are we making?', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Describe the character — a whole brief or just the vibe. The Studio '
          'writes the card, greetings, a lorebook and anything else it needs, '
          'then playtests it with your chat setup. Ask for as many sub-agents '
          'as you like to split the work. Nothing reaches your library until '
          'you apply it.',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        if (!ready) ...[
          const SizedBox(height: 16),
          Text(
            'Set up a provider in Settings first — the Studio needs a model '
            'that can call tools.',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.error),
          ),
        ],
        const SizedBox(height: 20),
        for (final example in _examples)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: ActionChip(
              label: Text(example, maxLines: 3),
              onPressed: () => onPick(example),
            ),
          ),
      ],
    );
  }
}

/// A message sent while the agent was working, waiting for its next step:
/// the user's own bubble, quieter, with a way to take it back.
class _QueuedBubble extends StatelessWidget {
  const _QueuedBubble({
    super.key,
    required this.text,
    required this.pictures,
    required this.onCancel,
  });

  final String text;
  final int pictures;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(48, 8, 0, 8),
        padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.schedule_send_outlined,
                          size: 14, color: scheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        'Queued — it reads this next',
                        style: theme.textTheme.labelMedium
                            ?.copyWith(color: scheme.primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text.isEmpty
                        ? '$pictures picture${pictures == 1 ? '' : 's'}'
                        : text,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            IconButton(
              key: const Key('studio-queued-cancel'),
              tooltip: 'Take back',
              visualDensity: VisualDensity.compact,
              onPressed: onCancel,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

/// Where the agent's older turns were summarised: they are still here to read,
/// but the agent now sees them as its own summary.
class _CompactionDivider extends StatelessWidget {
  const _CompactionDivider({required this.compaction});

  final StudioCompaction compaction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      key: const Key('studio-compaction-divider'),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
      child: Row(
        children: [
          Expanded(child: Divider(color: scheme.outlineVariant)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.compress_rounded, size: 16, color: scheme.outline),
                const SizedBox(width: 6),
                Text(
                  'Earlier conversation summarised',
                  style: theme.textTheme.labelMedium
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          Expanded(child: Divider(color: scheme.outlineVariant)),
        ],
      ),
    );
  }
}

/// A background sub-agent's report arriving: one quiet line that opens its
/// chat, rather than the whole report pasted into this one.
class _BackgroundReport extends StatelessWidget {
  const _BackgroundReport({
    required this.label,
    required this.taskId,
    required this.onOpen,
  });

  final String label;
  final String taskId;
  final ValueChanged<String>? onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: Material(
        color: scheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          key: Key('studio-background-report-$taskId'),
          borderRadius: BorderRadius.circular(20),
          onTap: onOpen == null ? null : () => onOpen!(taskId),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                Icon(Icons.mark_email_read_outlined,
                    size: 18, color: scheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '$label finished in the background',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ),
                if (onOpen != null)
                  Icon(Icons.chevron_right, color: scheme.onSecondaryContainer),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The pictures in a picture tool's result — search candidates, gallery
/// pictures, or the one picture chosen — as thumbnail, full picture and a
/// caption. At most eight: a chip is a glance, not a gallery.
List<({String thumb, String full, String label})> pictureRefsOf(String text) {
  Object? json;
  try {
    json = jsonDecode(text);
  } catch (_) {
    return const [];
  }
  if (json is! Map) return const [];
  final out = <({String thumb, String full, String label})>[];
  void add(Object? thumb, Object? full, Object? label) {
    final t = (thumb is String ? thumb : '').trim();
    final f = (full is String ? full : '').trim();
    if (t.isEmpty && f.isEmpty) return;
    out.add((
      thumb: t.isEmpty ? f : t,
      full: f.isEmpty ? t : f,
      label: label is String ? label : '',
    ));
  }

  final candidates = json['candidates'];
  if (candidates is List) {
    for (final c in candidates) {
      if (c is Map) add(c['thumbnail'], c['url'], c['title']);
    }
  }
  final pictures = json['pictures'];
  if (pictures is List) {
    for (final p in pictures) {
      if (p is Map) add(p['picture'], p['picture'], p['title']);
    }
  }
  if (json['picture'] is String) add(json['picture'], json['picture'], json['credit']);
  return out.take(8).toList();
}

/// One thumbnail in a picture tool's chip; tapped, the picture larger in a
/// dialog, with its caption.
class _Thumb extends StatelessWidget {
  const _Thumb({
    super.key,
    required this.thumb,
    required this.full,
    required this.label,
  });

  final String thumb;
  final String full;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final image = avatarImage(thumb, displaySize: 64, devicePixelRatio: dpr);
    return Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => _open(context),
        child: SizedBox.square(
          dimension: 64,
          child: image == null
              ? Icon(Icons.image_outlined, color: scheme.outline)
              : SmoothImage(
                  image: image,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      Icon(Icons.broken_image_outlined, color: scheme.outline),
                ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    final theme = Theme.of(context);
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
    final image = avatarImage(full, displaySize: 480, devicePixelRatio: dpr) ??
        avatarImage(thumb, displaySize: 480, devicePixelRatio: dpr);
    showDialog<void>(
      context: context,
      builder: (dialog) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (image != null)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(dialog).height * 0.6,
                ),
                child: SmoothImage(
                  image: image,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const Padding(
                    padding: EdgeInsets.all(32),
                    child: Icon(Icons.broken_image_outlined, size: 48),
                  ),
                ),
              ),
            if (label.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text(label, style: theme.textTheme.bodyMedium),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                child: TextButton(
                  onPressed: () => Navigator.of(dialog).pop(),
                  child: const Text('Close'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
