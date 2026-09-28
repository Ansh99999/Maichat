import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/agent_message.dart';
import '../../services/studio/studio_controller.dart';
import '../../state/app_state.dart';
import '../../widgets/message_markdown.dart';
import '../../widgets/thinking_block.dart';

/// The conversation with the Studio: what the user asked, what the agent said,
/// and every tool it called, as a chip that opens onto what went in and what
/// came back.
class StudioAgentView extends StatefulWidget {
  const StudioAgentView({super.key, required this.controller});

  final StudioController controller;

  @override
  State<StudioAgentView> createState() => _StudioAgentViewState();
}

class _StudioAgentViewState extends State<StudioAgentView>
    with AutomaticKeepAliveClientMixin {
  final TextEditingController _input = TextEditingController();

  StudioController get _c => widget.controller;

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || _c.running) return;
    _input.clear();
    _c.send(text);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        final items = _items(context);
        return Column(
          children: [
            Expanded(
              child: items.isEmpty
                  ? _Intro(onPick: (text) => _input.text = text)
                  // Bottom-anchored like a chat: the newest turn sits above the
                  // composer and a growing reply pushes older ones up.
                  : ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      itemCount: items.length,
                      itemBuilder: (context, i) => items[items.length - 1 - i],
                    ),
            ),
            if (_c.notice != null) _Notice(controller: _c),
            _Composer(
              controller: _input,
              running: _c.running,
              onSend: _send,
              onStop: _c.stop,
            ),
          ],
        );
      },
    );
  }

  List<Widget> _items(BuildContext context) {
    final transcript = _c.session.transcript;
    final results = <String, AgentMessage>{
      for (final m in transcript)
        if (m.role == AgentRole.tool && m.toolCallId != null) m.toolCallId!: m,
    };
    final out = <Widget>[];
    for (final m in transcript) {
      switch (m.role) {
        case AgentRole.user:
          out.add(m.text.startsWith('[Studio note]')
              ? _Note(text: m.text.substring('[Studio note]'.length).trim())
              : _UserBubble(text: m.text));
        case AgentRole.assistant:
          if (m.reasoning.isNotEmpty) {
            out.add(ThinkingBlock(reasoning: m.reasoning));
          }
          if (m.text.isNotEmpty) out.add(_AgentText(text: m.text));
          for (final call in m.toolCalls) {
            out.add(_ToolChip(
              call: call,
              result: results[call.id],
              running: _c.activeCalls.containsKey(call.id),
              helper: _c.helpers[call.id],
            ));
          }
        case AgentRole.tool:
        case AgentRole.system:
          break;
      }
    }
    if (_c.running) {
      if (_c.liveReasoning.isNotEmpty) {
        out.add(ThinkingBlock(reasoning: _c.liveReasoning, inProgress: true));
      }
      if (_c.liveText.isNotEmpty) {
        out.add(_AgentText(text: _c.liveText));
      } else if (_c.activeCalls.isEmpty) {
        out.add(const _Working());
      }
    }
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
  const _UserBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.fromLTRB(48, 8, 0, 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: scheme.primaryContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: SelectableText(
          text,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: scheme.onPrimaryContainer),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
      child: Row(
        children: [
          Icon(Icons.history, size: 16, color: theme.colorScheme.outline),
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

IconData _toolIcon(String name) => switch (name) {
      'get_draft' || 'read_document' || 'read_library_item' => Icons.visibility_outlined,
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
      'playtest' => Icons.forum_outlined,
      'list_library' => Icons.local_library_outlined,
      'delegate' => Icons.groups_outlined,
      _ => Icons.build_outlined,
    };

/// One tool call: a line saying what it did, and — opened — what the agent
/// sent and what came back. A `delegate` call shows its helper's steps while
/// the helper works.
class _ToolChip extends StatefulWidget {
  const _ToolChip({
    required this.call,
    required this.result,
    required this.running,
    this.helper,
  });

  final ToolCall call;
  final AgentMessage? result;
  final bool running;
  final HelperRun? helper;

  @override
  State<_ToolChip> createState() => _ToolChipState();
}

class _ToolChipState extends State<_ToolChip> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = widget.result;
    final failed = result?.isError ?? false;
    final helper = widget.helper;
    final small = theme.textTheme.bodySmall;
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
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
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
                        describeCall(widget.call),
                        maxLines: _open ? 3 : 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    const SizedBox(width: 8),
                    status,
                  ],
                ),
                if (helper != null && (widget.running || _open) && helper.steps.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 28, top: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final step in _open
                            ? helper.steps
                            : helper.steps.skip(
                                (helper.steps.length - 3).clamp(0, 1 << 30)))
                          Text('· $step',
                              style: small?.copyWith(
                                  color: scheme.onSurfaceVariant)),
                      ],
                    ),
                  ),
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

class _Notice extends StatelessWidget {
  const _Notice({required this.controller});

  final StudioController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final error = controller.noticeIsError;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: error ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              controller.notice ?? '',
              style: TextStyle(
                color: error
                    ? scheme.onErrorContainer
                    : scheme.onSecondaryContainer,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: const Icon(Icons.close, size: 18),
            onPressed: controller.dismissNotice,
          ),
        ],
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.running,
    required this.onSend,
    required this.onStop,
  });

  final TextEditingController controller;
  final bool running;
  final VoidCallback onSend;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  hintText: running
                      ? 'Working — you can type the next message'
                      : 'Describe the vibe, or ask for a change',
                  filled: true,
                  fillColor: scheme.surfaceContainerHigh,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(24),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 6),
            running
                ? IconButton.filledTonal(
                    tooltip: 'Stop',
                    icon: const Icon(Icons.stop),
                    onPressed: onStop,
                  )
                : IconButton.filled(
                    tooltip: 'Send',
                    icon: const Icon(Icons.arrow_upward),
                    onPressed: onSend,
                  ),
          ],
        ),
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
        'a city lorebook.',
    'Cozy fantasy: the grumpy dwarf baker in a mountain village, with three '
        'different openings.',
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = context.watch<AppState>().studioProvider() != null;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Icon(Icons.auto_awesome, size: 40, color: theme.colorScheme.primary),
        const SizedBox(height: 12),
        Text('What are we making?', style: theme.textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(
          'Describe the character — a whole brief or just the vibe. The Studio '
          'writes the card, greetings, a lorebook and anything else it needs, '
          'then playtests it with your chat setup. Watch the Draft tab fill in; '
          'nothing reaches your library until you apply it.',
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
