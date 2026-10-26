import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/agent_message.dart';
import '../models/chat_tool.dart';

/// Compact below-message presentation for one recorded logical tool run.
///
/// The widget is deliberately stateless with respect to app state: it renders
/// only what the durable [ChatToolRun] records. This keeps loading a transcript,
/// changing a swipe, or viewing an old variant from executing a tool again.
class ChatToolResults extends StatelessWidget {
  const ChatToolResults({
    super.key,
    required this.run,
    this.stale = false,
    this.showTrackers = true,
    this.hiddenTools = const {},
  });

  final ChatToolRun run;

  /// Whether the recorded effects failed their replay preconditions. When this
  /// is true the values shown are historical and must not be treated as current.
  final bool stale;

  /// The per-call rows include tracker effects in their details. A pinned panel
  /// can turn those off to avoid showing every value twice.
  final bool showTrackers;
  final Set<String> hiddenTools;

  @override
  Widget build(BuildContext context) {
    final calls = [
      for (final message in run.history)
        if (message.role == AgentRole.assistant) ...message.toolCalls,
    ];
    final results = <String, AgentMessage>{};
    for (final message in run.history) {
      if (message.role == AgentRole.tool && message.toolCallId != null) {
        results[message.toolCallId!] = message;
      }
    }

    final visibleCalls = calls
        .where(
          (call) =>
              !hiddenTools.contains(call.name) &&
              (showTrackers || !_isTrackerOnlyCall(call.name)),
        )
        .toList();
    final trackerEffects = showTrackers
        ? run.effects
              .where((effect) => effect.key.startsWith('tracker:'))
              .toList()
        : const <ChatToolEffect>[];
    final hasData =
        visibleCalls.isNotEmpty ||
        trackerEffects.isNotEmpty ||
        run.images.isNotEmpty;
    if (!hasData) return const SizedBox.shrink();

    return Container(
      decoration: _panelDecoration(context),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _StatusHeader(run: run, stale: stale),
          if (trackerEffects.isNotEmpty) ...[
            const SizedBox(height: 8),
            ChatTrackerPanel(values: _trackerValuesFromEffects(trackerEffects)),
          ],
          for (final call in visibleCalls)
            _ToolCallRow(
              call: call,
              result: results[call.id],
              running: run.status == 'running' && results[call.id] == null,
            ),
          if (visibleCalls.isEmpty && trackerEffects.isEmpty)
            _EmptyBody(hasImages: run.images.isNotEmpty),
          if (run.images.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
              child: _GeneratedImagesNote(count: run.images.length),
            )
          else
            const SizedBox(height: 10),
        ],
      ),
    );
  }

  static bool _isTrackerOnlyCall(String name) =>
      name == 'read_trackers' || name == 'define_tracker';

  static Map<String, dynamic> _trackerValuesFromEffects(
    List<ChatToolEffect> effects,
  ) {
    final values = <String, dynamic>{};
    for (final effect in effects) {
      final id = effect.key.substring('tracker:'.length);
      final after = effect.after;
      if (after is Map) {
        values[id] = Map<String, dynamic>.from(after);
      } else if (after != null) {
        values[id] = {'value': after};
      }
    }
    return values;
  }

  static BoxDecoration _panelDecoration(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return BoxDecoration(
      color: scheme.surfaceContainerLow.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.8)),
    );
  }
}

class _StatusHeader extends StatelessWidget {
  const _StatusHeader({required this.run, required this.stale});

  final ChatToolRun run;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final running = run.status == 'running';
    final failed = run.status == 'failed' || run.status == 'cancelled';
    final color = failed
        ? scheme.error
        : running
        ? scheme.tertiary
        : scheme.primary;
    final label = switch (run.status) {
      'running' => 'Tool calls running',
      'completed' => 'Tool calls completed',
      'failed' => 'Tool calls failed',
      'cancelled' => 'Tool calls cancelled',
      final other => 'Tool calls: $other',
    };

    return Container(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(
            running
                ? Icons.hourglass_top_outlined
                : failed
                ? Icons.error_outline
                : Icons.check_circle_outline,
            size: 16,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (stale)
            Tooltip(
              message:
                  'Recorded results are historical. Regenerate this '
                  'reply to apply fresh tool effects.',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: scheme.errorContainer.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.history,
                      size: 13,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Stale',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ToolCallRow extends StatefulWidget {
  const _ToolCallRow({
    required this.call,
    required this.result,
    required this.running,
  });

  final ToolCall call;
  final AgentMessage? result;
  final bool running;

  @override
  State<_ToolCallRow> createState() => _ToolCallRowState();
}

class _ToolCallRowState extends State<_ToolCallRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final result = widget.result;
    final failed = result?.isError ?? false;
    final resultText = result?.text ?? '';
    final shortResult = result == null
        ? (widget.running ? 'Running…' : 'No result recorded')
        : _shortResult(resultText);
    final canOpen =
        result != null ||
        widget.call.arguments.isNotEmpty ||
        widget.call.argumentError != null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Material(
        color: failed
            ? scheme.errorContainer.withValues(alpha: 0.55)
            : scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: canOpen ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _toolIcon(widget.call.name),
                      size: 16,
                      color: failed
                          ? scheme.onErrorContainer
                          : scheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        readableToolName(widget.call.name),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (widget.running)
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    else
                      Icon(
                        failed ? Icons.error_outline : Icons.check,
                        size: 15,
                        color: failed ? scheme.error : scheme.primary,
                      ),
                    if (canOpen) ...[
                      const SizedBox(width: 6),
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Icon(
                          Icons.expand_more,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  shortResult,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: failed
                        ? scheme.onErrorContainer
                        : scheme.onSurfaceVariant,
                  ),
                ),
                AnimatedSize(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topCenter,
                  child: _open
                      ? Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (widget.call.arguments.isNotEmpty)
                                _Detail(
                                  label: 'Arguments',
                                  text: prettyJson(widget.call.arguments),
                                ),
                              if (result != null)
                                _Detail(
                                  label: failed ? 'Error' : 'Result',
                                  text: _displayResultText(resultText),
                                  color: failed ? scheme.error : scheme.primary,
                                ),
                            ],
                          ),
                        )
                      : const SizedBox(width: double.infinity, height: 0),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _displayResultText(String text) {
    try {
      return prettyJson(jsonDecode(text));
    } catch (_) {
      return text;
    }
  }

  static String _shortResult(String text) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return _plainShort(text);
    }
    final Object? value = decoded is Map || decoded is List ? decoded : null;
    if (value == null) return _plainShort(decoded.toString());
    if (value is Map) {
      for (final key in const [
        'result',
        'value',
        'total',
        'message',
        'error',
      ]) {
        if (value.containsKey(key)) return _plainShort(value[key].toString());
      }
    }
    return _plainShort(decoded.toString());
  }

  static String _plainShort(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (flat.isEmpty) return 'Empty result';
    return flat.length <= 96 ? flat : '${flat.substring(0, 96)}…';
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.text, this.color});

  final String label;
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color ?? theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
            ),
          ),
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
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyBody extends StatelessWidget {
  const _EmptyBody({required this.hasImages});

  final bool hasImages;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Text(
        hasImages
            ? 'No tool text was recorded.'
            : 'No tool calls were recorded.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

class _GeneratedImagesNote extends StatelessWidget {
  const _GeneratedImagesNote({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Text(
      '$count generated ${count == 1 ? 'picture' : 'pictures'} attached to '
      'this reply',
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}

/// A compact presentation of current tracker values.
///
/// [values] is the owner-supplied projection map, already resolved from
/// recorded effects. Its shape is deliberately UI-oriented rather than the raw
/// tracker storage format:
///
/// ```json
/// {"health": {"label": "Health", "value": 72, "unit": "%"}}
/// ```
class ChatTrackerPanel extends StatelessWidget {
  const ChatTrackerPanel({super.key, required this.values});

  final Map<String, dynamic> values;

  @override
  Widget build(BuildContext context) {
    final entries = values.entries.where((entry) {
      final value = entry.value;
      if (value is Map && (value['hidden'] as bool? ?? false)) return false;
      return true;
    }).toList()..sort((a, b) => a.key.compareTo(b.key));
    if (entries.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in entries)
            _TrackerChip(
              label: _labelOf(entry),
              value: entry.value is Map
                  ? (entry.value as Map)['value']
                  : entry.value,
              unit: entry.value is Map
                  ? (entry.value as Map)['unit']?.toString()
                  : null,
              scheme: scheme,
            ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  static String _labelOf(MapEntry<String, dynamic> entry) {
    final value = entry.value;
    if (value is Map) {
      final label = value['label']?.toString().trim();
      if (label != null && label.isNotEmpty) return label;
    }
    final words = entry.key.split(RegExp(r'[_.]'));
    return words
        .where((word) => word.isNotEmpty)
        .map((word) => '${word[0].toUpperCase()}${word.substring(1)}')
        .join(' ');
  }
}

class _TrackerChip extends StatelessWidget {
  const _TrackerChip({
    required this.label,
    required this.value,
    required this.unit,
    required this.scheme,
  });

  final String label;
  final Object? value;
  final String? unit;
  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text.rich(
          TextSpan(
            text: label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
            children: [
              TextSpan(
                text: '  ${_formatValue(value, unit)}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }

  static String _formatValue(Object? value, String? unit) {
    if (value is num) {
      final shown = value == value.roundToDouble()
          ? value.round().toString()
          : value.toStringAsFixed(2);
      return unit == '%' ? '$shown%' : '$shown${unit == null ? '' : ' $unit'}';
    }
    return value?.toString() ?? '—';
  }
}

/// Turns a stable tool name into a short human-readable label, without exposing
/// custom tool schemas by default.
String readableToolName(String name) {
  final words = name
      .replaceAll(RegExp(r'[^A-Za-z0-9_]+'), '_')
      .split('_')
      .where((word) => word.isNotEmpty)
      .map((word) => word[0].toUpperCase() + word.substring(1))
      .toList();
  return words.isEmpty ? 'Tool' : words.join(' ');
}

IconData _toolIcon(String name) => switch (name) {
  'roll_dice' => Icons.casino_outlined,
  'random_integer' => Icons.numbers,
  'read_trackers' ||
  'define_tracker' ||
  'update_tracker' => Icons.monitor_heart_outlined,
  'set_prompt_injection' => Icons.forum_outlined,
  'generate_image' => Icons.image_outlined,
  'list_tools' => Icons.build_outlined,
  'save_tool' => Icons.save_outlined,
  _ => Icons.extension_outlined,
};

/// Pretty-prints JSON, but never throws: a rendering path should still show a
/// malformed historical record.
String prettyJson(Object? value) {
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return value.toString();
  }
}
