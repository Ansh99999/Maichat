import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../state/app_state.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// The screen you land on: a hub of recent chats with a prominent way to start
/// a new one. A single conversation opens on top as a detail screen, so the
/// back button always returns here — the standard Android hub-and-detail flow.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _openChat(BuildContext context, AppState state, String id) {
    state.selectConversation(id);
    _pushChat(context);
  }

  void _newChat(BuildContext context, AppState state) {
    state.newConversation();
    _pushChat(context);
  }

  void _pushChat(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
      );

  void _openSettings(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    // Brand-new, never-sent threads have nothing to show, so they stay out of
    // the list until they hold a message.
    final chats = state.conversations.where((c) => !c.isEmpty).toList();
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newChat(context, state),
        icon: const Icon(Icons.add),
        label: const Text('New chat'),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: const Text('MaiChat'),
            actions: [
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => _openSettings(context),
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            sliver: SliverToBoxAdapter(
              child: _ProviderCard(
                state: state,
                onSettings: () => _openSettings(context),
              ),
            ),
          ),
          if (chats.isNotEmpty)
            const SliverPadding(
              padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
              sliver: SliverToBoxAdapter(child: _SectionHeader('Recent chats')),
            ),
          if (chats.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyHome(configured: state.settings.isConfigured),
            )
          else
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 96 + bottom),
              sliver: SliverList.builder(
                itemCount: chats.length,
                itemBuilder: (context, index) => _ChatCard(
                  conversation: chats[index],
                  onTap: () => _openChat(context, state, chats[index].id),
                  onDelete: () => _confirmDelete(context, state, chats[index]),
                ),
              ),
            ),
        ],
      ),
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

/// A left-aligned label that titles a run of cards below it.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Shows where replies come from. Unconfigured, it is a prominent call to
/// action; once set up, it shrinks to a quiet status line into settings.
class _ProviderCard extends StatelessWidget {
  const _ProviderCard({required this.state, required this.onSettings});

  final AppState state;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final settings = state.settings;

    if (!settings.isConfigured) {
      return Card(
        color: scheme.primaryContainer,
        elevation: 0,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.key_outlined, color: scheme.onPrimaryContainer),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Finish setup',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: scheme.onPrimaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Add a base URL, API key and model before you can chat.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: scheme.onPrimaryContainer,
                    ),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: onSettings,
                  icon: const Icon(Icons.settings_outlined),
                  label: const Text('Open settings'),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final host = Uri.tryParse(settings.baseUrl)?.host ?? settings.baseUrl;
    return Card(
      color: scheme.surfaceContainerHighest,
      elevation: 0,
      child: ListTile(
        leading: Icon(Icons.cloud_done_outlined, color: scheme.primary),
        title: Text(
          settings.model.isEmpty ? 'No model selected' : settings.model,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(host, maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: const Icon(Icons.chevron_right),
        onTap: onSettings,
      ),
    );
  }
}

/// One conversation in the recent list: title, a preview of the last turn, how
/// long ago it was touched, and an overflow menu to delete it.
class _ChatCard extends StatelessWidget {
  const _ChatCard({
    required this.conversation,
    required this.onTap,
    required this.onDelete,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final preview = conversation.messages.isEmpty
        ? 'Empty'
        : conversation.messages.last.content
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(
            Icons.chat_bubble_outline,
            color: scheme.onSecondaryContainer,
            size: 20,
          ),
        ),
        title: Text(
          conversation.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              preview.isEmpty ? 'Empty' : preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              relativeTime(conversation.updatedAt),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
        isThreeLine: true,
        trailing: PopupMenuButton<String>(
          tooltip: 'More',
          icon: const Icon(Icons.more_vert),
          onSelected: (value) {
            if (value == 'delete') onDelete();
          },
          itemBuilder: (context) => const [
            PopupMenuItem<String>(
              value: 'delete',
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline),
                title: Text('Delete'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Fills the body when there are no chats yet — a friendly nudge towards the
/// New chat button (or settings, when the provider is not configured).
class _EmptyHome extends StatelessWidget {
  const _EmptyHome({required this.configured});

  final bool configured;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.forum_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              'No chats yet',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              configured
                  ? 'Tap New chat to start your first conversation.'
                  : 'Set up a provider, then tap New chat to begin.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A compact "time since" label: minutes, hours, days, weeks, then years.
String relativeTime(DateTime time) {
  final diff = DateTime.now().difference(time);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  if (diff.inDays < 365) return '${diff.inDays ~/ 7}w ago';
  return '${diff.inDays ~/ 365}y ago';
}
