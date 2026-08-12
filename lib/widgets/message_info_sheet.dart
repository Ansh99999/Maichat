import 'package:flutter/material.dart';

import '../models/message.dart';
import '../services/token_estimator.dart';
import '../state/app_state.dart';

/// Per-message info: its position in the thread, its own token cost, the total
/// context assembled up to it, and a section-by-section breakdown of that
/// context (Main / Description / History / …) with proportional bars.
class MessageInfoSheet extends StatelessWidget {
  const MessageInfoSheet({
    super.key,
    required this.assembled,
    required this.messageNumber,
    required this.messageCount,
    required this.message,
  });

  final AssembledPrompt assembled;
  final int messageNumber;
  final int messageCount;
  final ChatMessage message;

  static const _estimator = HeuristicTokenEstimator();

  int get _messageTokens => _estimator.estimate(message.content) + 4;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final total = assembled.totalTokens;
    final pct = assembled.maxContext > 0
        ? (total / assembled.maxContext * 100).round()
        : 0;
    // The largest section drives the bar scale so proportions read clearly.
    final maxSection = assembled.sections.fold<int>(
        1, (m, s) => s.tokens > m ? s.tokens : m);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Message info', style: text.titleMedium),
            const SizedBox(height: 12),
            _StatRow(
                label: 'Position', value: 'Message $messageNumber of $messageCount'),
            _StatRow(label: 'Role', value: message.role),
            _StatRow(label: 'This message', value: '~$_messageTokens tokens'),
            _StatRow(
              label: 'Context total',
              value: '~$total / ${assembled.maxContext} tokens ($pct%)',
            ),
            const SizedBox(height: 16),
            Text('Context breakdown', style: text.titleSmall),
            const SizedBox(height: 4),
            Text(
              'What the request behind this message is made of — an estimate.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            if (assembled.sections.isEmpty)
              Text('Nothing assembled yet.',
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant))
            else
              for (final s in assembled.sections)
                _SectionBar(
                  label: s.label,
                  tokens: s.tokens,
                  messageCount: s.messageCount,
                  fraction: (s.tokens / maxSection).clamp(0.0, 1.0),
                ),
          ],
        ),
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(label,
                style: TextStyle(color: scheme.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

class _SectionBar extends StatelessWidget {
  const _SectionBar({
    required this.label,
    required this.tokens,
    required this.messageCount,
    required this.fraction,
  });

  final String label;
  final int tokens;
  final int messageCount;
  final double fraction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  messageCount > 1 ? '$label ($messageCount)' : label,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Text('~$tokens',
                  style: TextStyle(color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 6,
              backgroundColor: scheme.surfaceContainerHighest,
            ),
          ),
        ],
      ),
    );
  }
}
