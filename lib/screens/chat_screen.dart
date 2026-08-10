import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../models/conversation.dart';
import '../models/provider.dart';
import '../services/chat_client.dart';
import '../state/app_state.dart';
import '../widgets/message_bubble.dart';
import '../widgets/model_picker.dart';
import 'settings_screen.dart';

/// A single conversation: the thread, a composer, and a tap-through to the
/// quick provider/model picker. Opened on top of the home hub.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send(AppState state) async {
    final text = _input.text;
    if (text.trim().isEmpty || state.streaming) return;
    if (!state.isConfigured) {
      _openSettings();
      return;
    }
    _input.clear();
    _scrollToEnd();
    await state.send(text);
    _scrollToEnd();
  }

  void _openSettings() => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );

  void _openQuickSettings() => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _QuickSettingsSheet(onManage: () {
          Navigator.of(context).pop();
          _openSettings();
        }),
      );

  /// Sticks to the newest message after the frame that added it.
  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final conversation = state.active;
    if (state.streaming) _scrollToEnd();
    final active = state.activeProvider;
    final subtitle = active == null
        ? null
        : '${active.displayName}${active.model.trim().isEmpty ? '' : ' · ${active.model.trim()}'}';

    return Scaffold(
      appBar: AppBar(
        title: InkWell(
          onTap: _openQuickSettings,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  conversation.isEmpty ? 'MaiChat' : conversation.title,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          subtitle,
                          style: Theme.of(context).textTheme.labelSmall,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const Icon(Icons.arrow_drop_down, size: 16),
                    ],
                  ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Quick settings',
            onPressed: _openQuickSettings,
            icon: const Icon(Icons.tune),
          ),
          IconButton(
            tooltip: 'New chat',
            onPressed: state.streaming ? null : state.newConversation,
            icon: const Icon(Icons.add_comment_outlined),
          ),
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: conversation.isEmpty
                  ? _EmptyState(
                      configured: state.isConfigured,
                      onSettings: _openSettings,
                    )
                  : _messageList(conversation, state),
            ),
            _composer(state),
          ],
        ),
      ),
    );
  }

  Widget _messageList(Conversation conversation, AppState state) {
    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: conversation.messages.length,
      itemBuilder: (context, index) {
        final isLast = index == conversation.messages.length - 1;
        return MessageBubble(
          message: conversation.messages[index],
          pending: isLast && state.streaming,
        );
      },
    );
  }

  Widget _composer(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 5,
              textInputAction: TextInputAction.newline,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'Message',
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _sendButton(state),
        ],
      ),
    );
  }

  /// Doubles as the stop control while a reply is streaming.
  Widget _sendButton(AppState state) {
    final scheme = Theme.of(context).colorScheme;
    if (state.streaming) {
      return IconButton.filled(
        tooltip: 'Stop',
        onPressed: state.stop,
        style: IconButton.styleFrom(
          backgroundColor: scheme.error,
          foregroundColor: scheme.onError,
        ),
        icon: const Icon(Icons.stop),
      );
    }
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _input,
      builder: (context, value, _) => IconButton.filled(
        tooltip: 'Send',
        onPressed:
            value.text.trim().isEmpty ? null : () => _send(state),
        icon: const Icon(Icons.arrow_upward),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.configured, required this.onSettings});

  final bool configured;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              configured ? Icons.forum_outlined : Icons.key_outlined,
              size: 44,
              color: scheme.outline,
            ),
            const SizedBox(height: 16),
            Text(
              configured
                  ? 'Say something to get started.'
                  : 'Add a provider with a model to start chatting.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
            if (!configured) ...[
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                onPressed: onSettings,
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open settings'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The chat-screen quick picker: switch the active provider and choose its
/// model without leaving the conversation. "Manage providers" drops into the
/// full settings for adding, editing or deleting.
class _QuickSettingsSheet extends StatefulWidget {
  const _QuickSettingsSheet({required this.onManage});

  final VoidCallback onManage;

  @override
  State<_QuickSettingsSheet> createState() => _QuickSettingsSheetState();
}

class _QuickSettingsSheetState extends State<_QuickSettingsSheet> {
  bool _loadingModels = false;

  Future<void> _browseModels(AppState state, Provider active) async {
    setState(() => _loadingModels = true);
    List<String>? models;
    String? error;
    try {
      models = await state.fetchModels(active);
    } on ChatApiException catch (e) {
      error = e.message;
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
    if (!mounted) return;
    if (error != null || models == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error ?? 'Could not list models.')),
      );
      return;
    }
    final picked = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ModelPicker(
        models: models!,
        selected: active.model.trim(),
      ),
    );
    if (picked == null || !mounted) return;
    await state.setActiveModel(picked);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final providers = state.providers;
    final active = state.activeProvider;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(
                'Provider',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (providers.isEmpty)
              const ListTile(
                leading: Icon(Icons.dns_outlined),
                title: Text('No providers yet'),
                subtitle: Text('Add one to start chatting'),
              )
            else
              Flexible(
                child: RadioGroup<String>(
                  groupValue: active?.id,
                  onChanged: (id) {
                    if (id != null) state.selectProvider(id);
                  },
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final provider in providers)
                        RadioListTile<String>(
                          value: provider.id,
                          title: Text(
                            provider.displayName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            provider.kind.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            const Divider(height: 1),
            if (active != null)
              ListTile(
                leading: const Icon(Icons.memory_outlined),
                title: const Text('Model'),
                subtitle: Text(
                  active.model.trim().isEmpty ? 'None selected' : active.model,
                ),
                trailing: _loadingModels
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.expand_more),
                onTap:
                    _loadingModels ? null : () => _browseModels(state, active),
              ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Manage providers'),
              onTap: widget.onManage,
            ),
          ],
        ),
      ),
    );
  }
}
