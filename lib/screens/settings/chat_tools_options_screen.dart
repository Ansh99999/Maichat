import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/chat_tool.dart';
import '../../models/conversation.dart';
import '../../state/app_state.dart';
import 'chat_tools_edit_screen.dart';
import 'chat_tools_page.dart';

/// The Tools ▸ settings sub-screen: every knob that is not the tool list —
/// the master switch, the in-chat display choices, the run limits, the
/// tracker placement, and import/export/create. Reached from the ⚙ in the
/// Tools page's app bar.
///
/// Same persistence path as the list page itself: every save goes through
/// [AppState.saveChatToolConfig] with the same [conversationId], so nothing
/// here can write the global library while a chat page thinks it is editing
/// its own copy, or the other way round.
class ChatToolsOptionsScreen extends StatelessWidget {
  const ChatToolsOptionsScreen({super.key, this.conversationId});

  final String? conversationId;

  Future<void> _save(
    BuildContext context,
    AppState state,
    ChatToolConfig config,
  ) async {
    try {
      await state.saveChatToolConfig(config, conversationId: conversationId);
    } catch (error) {
      if (context.mounted) {
        toastToolError(
          context,
          'Could not save tool settings: ${friendlyError(error)}',
        );
      }
    }
  }

  Future<void> _resetToDefaults(BuildContext context, AppState state) async {
    try {
      await state.resetChatToolConfig(conversationId!);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(content: Text('Following app defaults again')),
          );
      }
    } catch (error) {
      if (context.mounted) toastToolError(context, '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversation = conversationId == null
        ? null
        : state.conversationById(conversationId!);
    final config = state.chatToolConfigFor(conversation);

    return Scaffold(
      appBar: AppBar(title: const Text('Tools settings')),
      body: ListView(
        key: const Key('chat-tools-options-list'),
        padding: EdgeInsets.fromLTRB(
          8,
          8,
          8,
          16 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          _ScopeNote(
            conversationId: conversationId,
            conversation: conversation,
          ),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.build_outlined),
            title: const Text('Enable tool calls'),
            subtitle: const Text(
              'The character\'s AI may ask MaiChat to run an operation, then '
              'react to the recorded result.',
            ),
            value: config.enabled,
            onChanged: (value) =>
                _save(context, state, config.copyWith(enabled: value)),
          ),
          SwitchListTile(
            dense: true,
            secondary: const Icon(Icons.visibility_off_outlined),
            title: const Text('Hide tool calls in chat'),
            subtitle: const Text(
              'Tools keep working, but their call details stay out of replies. '
              'Details stay visible in View prompt.',
            ),
            value: config.hideToolCallsInChat,
            onChanged: (value) => _save(
              context,
              state,
              config.copyWith(hideToolCallsInChat: value),
            ),
          ),
          _RunLimitsCard(
            config: config,
            onChanged: (rounds, calls) => _save(
              context,
              state,
              config.copyWith(maxRounds: rounds, maxCalls: calls),
            ),
          ),
          _TrackerPlacementCard(
            value: config.trackerPlacement,
            onChanged: (value) =>
                _save(context, state, config.copyWith(trackerPlacement: value)),
          ),
          if (conversationId != null && conversation?.chatToolConfig != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              child: OutlinedButton.icon(
                onPressed: () => _resetToDefaults(context, state),
                icon: const Icon(Icons.restore),
                label: const Text('Follow app defaults'),
              ),
            ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: FilledButton.tonalIcon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ChatToolEditScreen(
                    conversationId: conversationId,
                    existingNames: {
                      for (final tool in config.customTools) tool.name,
                    },
                  ),
                ),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Create a custom tool'),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: OutlinedButton.icon(
              onPressed: () =>
                  importChatTools(context, conversationId: conversationId),
              icon: const Icon(Icons.upload_outlined),
              label: const Text('Import tools'),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: OutlinedButton.icon(
              onPressed: () => exportChatTools(
                context,
                state,
                conversationId: conversationId,
              ),
              icon: const Icon(Icons.download_outlined),
              label: const Text('Export tools'),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScopeNote extends StatelessWidget {
  const _ScopeNote({required this.conversationId, required this.conversation});

  final String? conversationId;
  final Conversation? conversation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = conversationId == null ? 'App-wide tools' : 'This chat only';
    final detail = conversationId == null
        ? 'These settings apply to every chat without its own tool overrides.'
        : 'These settings override the app-wide ones for this chat only.';
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      elevation: 0,
      color: scheme.secondaryContainer.withValues(alpha: 0.7),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              conversationId == null
                  ? Icons.travel_explore_outlined
                  : Icons.forum_outlined,
              color: scheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: scheme.onSecondaryContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSecondaryContainer.withValues(alpha: .8),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RunLimitsCard extends StatelessWidget {
  const _RunLimitsCard({required this.config, required this.onChanged});

  final ChatToolConfig config;
  final void Function(int rounds, int calls) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Run limits',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            _LimitSlider(
              key: const Key('chat-tools-rounds'),
              label: 'Follow-up rounds',
              value: config.maxRounds,
              min: 1,
              max: 10,
              onChanged: (value) => onChanged(value, config.maxCalls),
            ),
            const SizedBox(height: 4),
            _LimitSlider(
              key: const Key('chat-tools-calls'),
              label: 'Total tool calls',
              value: config.maxCalls,
              min: 1,
              max: 50,
              onChanged: (value) => onChanged(config.maxRounds, value),
            ),
          ],
        ),
      ),
    );
  }
}

class _LimitSlider extends StatelessWidget {
  const _LimitSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '$value',
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        Slider(
          value: value.toDouble(),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          label: '$value',
          onChanged: (changed) => onChanged(changed.round()),
        ),
      ],
    );
  }
}

class _TrackerPlacementCard extends StatelessWidget {
  const _TrackerPlacementCard({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  static const Map<String, String> _labels = {
    'message': 'Below the reply',
    'pinned': 'Pinned panel',
    'hidden': 'Hidden',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      elevation: 0,
      color: scheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Tracker placement',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Where tracker updates from tools are shown.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                key: const Key('chat-tools-tracker-placement'),
                showSelectedIcon: false,
                segments: [
                  for (final entry in _labels.entries)
                    ButtonSegment(value: entry.key, label: Text(entry.value)),
                ],
                selected: {_labels.containsKey(value) ? value : 'message'},
                onSelectionChanged: (selection) => onChanged(selection.first),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
