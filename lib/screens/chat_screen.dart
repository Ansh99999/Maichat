import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../state/app_state.dart';
import '../widgets/message_bubble.dart';
import 'settings_screen.dart';

/// The one screen you land on: a thread, a composer, and a drawer of threads.
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
    if (!state.settings.isConfigured) {
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

    return Scaffold(
      drawer: _ConversationDrawer(onSettings: _openSettings),
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              conversation.isEmpty ? 'MaiChat' : conversation.title,
              overflow: TextOverflow.ellipsis,
            ),
            if (state.settings.model.isNotEmpty)
              Text(
                state.settings.model,
                style: Theme.of(context).textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
        actions: [
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
                      configured: state.settings.isConfigured,
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
                  : 'Add a base URL, API key and model to start chatting.',
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

class _ConversationDrawer extends StatelessWidget {
  const _ConversationDrawer({required this.onSettings});

  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final conversations = state.conversations;
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            ListTile(
              title: Text(
                'Chats',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              trailing: IconButton(
                tooltip: 'New chat',
                icon: const Icon(Icons.add),
                onPressed: state.streaming
                    ? null
                    : () {
                        state.newConversation();
                        Navigator.of(context).pop();
                      },
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: conversations.isEmpty
                  ? const Center(child: Text('No chats yet'))
                  : ListView.builder(
                      itemCount: conversations.length,
                      itemBuilder: (context, index) => _tile(
                        context,
                        state,
                        conversations[index],
                      ),
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('Settings'),
              onTap: () {
                Navigator.of(context).pop();
                onSettings();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, AppState state, Conversation c) {
    final selected = c.id == state.active.id;
    final preview = c.messages.isEmpty ? 'Empty' : c.messages.last.content;
    return ListTile(
      selected: selected,
      title: Text(c.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        preview.replaceAll(RegExp(r'\s+'), ' ').trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: IconButton(
        tooltip: 'Delete chat',
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _confirmDelete(context, state, c),
      ),
      onTap: state.streaming
          ? null
          : () {
              state.selectConversation(c.id);
              Navigator.of(context).pop();
            },
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppState state,
    Conversation c,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete chat?'),
        content: Text('"${c.title}" will be removed permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed ?? false) await state.deleteConversation(c.id);
  }
}
