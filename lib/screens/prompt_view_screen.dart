import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../state/app_state.dart';

/// Shows the fully assembled request behind a message — exactly what the model
/// receives — as an ordered list of role-tagged cards, with an estimated token
/// total. Mirrors Agnai's PromptModal (its "View prompt"), including the caveat
/// that the estimate is approximate.
class PromptViewScreen extends StatelessWidget {
  const PromptViewScreen({super.key, required this.assembled});

  final AssembledPrompt assembled;

  String get _plainText => assembled.messages
      .map((m) => '[${m.role}]\n${m.content}')
      .join('\n\n');

  /// Copies the literal HTTP request a send would make — endpoint, headers with
  /// credentials redacted, and the JSON body — so what the app transmits can be
  /// inspected directly rather than inferred from this rendering.
  void _copyRawRequest(BuildContext context) {
    final raw = context.read<AppState>().requestPreview(assembled);
    final messenger = ScaffoldMessenger.of(context);
    if (raw == null) {
      messenger.showSnackBar(const SnackBar(
        content: Text('No provider configured'),
        duration: Duration(seconds: 2),
      ));
      return;
    }
    Clipboard.setData(ClipboardData(text: raw));
    messenger.showSnackBar(const SnackBar(
      content: Text('Raw request copied (API key redacted)'),
      duration: Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = assembled.maxContext > 0
        ? (assembled.totalTokens / assembled.maxContext * 100).round()
        : 0;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Prompt'),
        actions: [
          IconButton(
            tooltip: 'Copy raw request',
            icon: const Icon(Icons.data_object),
            onPressed: () => _copyRawRequest(context),
          ),
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _plainText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Prompt copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
            12, 12, 12, 16 + MediaQuery.paddingOf(context).bottom),
        children: [
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '~${assembled.totalTokens} tokens'
                    ' · ${assembled.messages.length} messages'
                    ' · $pct% of ${assembled.maxContext}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'An estimate — the server may tokenise slightly differently.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (final m in assembled.messages) _PromptCard(message: m),
        ],
      ),
    );
  }
}

class _PromptCard extends StatelessWidget {
  const _PromptCard({required this.message});

  final ChatMessage message;

  Color _roleColor(ColorScheme s) => switch (message.role) {
        'system' => s.tertiary,
        'assistant' => s.primary,
        _ => s.secondary,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: _roleColor(scheme).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    message.role,
                    style: TextStyle(
                      color: _roleColor(scheme),
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              message.content,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
