import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/conversation.dart';
import '../state/app_state.dart';
import '../widgets/app_drawer.dart';
import '../widgets/startup_screen.dart';
import 'chat_screen.dart';
import 'chats_screen.dart';
import 'settings_screen.dart';

/// The section you land on: a Home dashboard. It leads with where replies come
/// from (the provider setup reminder) and offers a quick peek at recent chats,
/// keeping the full list one tap away. Conversations open on top as detail
/// screens, so Back always returns here — the standard Android flow.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _newChat(BuildContext context, AppState state) {
    state.newConversation();
    _pushChat(context);
  }

  void _openChat(BuildContext context, AppState state, String id) {
    state.selectConversation(id);
    _pushChat(context);
  }

  void _pushChat(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ChatScreen()),
      );

  void _openChats(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const ChatsScreen()),
      );

  void _openSettings(BuildContext context) => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
      );

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) return const StartupScreen();
    // Brand-new, never-sent threads stay hidden until they hold a message.
    final chats = state.conversations.where((c) => !c.isEmpty).toList();
    final recent = chats.take(3).toList();
    final bottom = MediaQuery.paddingOf(context).bottom;
    final loadError = state.loadError;

    return Scaffold(
      drawer: const AppDrawer(selected: DrawerSection.home),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _newChat(context, state),
        icon: const Icon(Icons.add),
        label: const Text('New chat'),
      ),
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('Home')),
          if (loadError != null)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              sliver: SliverToBoxAdapter(
                child: LoadErrorCard(message: loadError),
              ),
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
          if (recent.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _WelcomeHome(configured: state.isConfigured),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    const Expanded(child: _SectionHeader('Recent chats')),
                    TextButton(
                      onPressed: () => _openChats(context),
                      child: const Text('See all'),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 96 + bottom),
              sliver: SliverList.builder(
                itemCount: recent.length,
                itemBuilder: (context, index) => ChatCard(
                  conversation: recent[index],
                  onTap: () => _openChat(context, state, recent[index].id),
                  onDelete: () => _confirmDelete(context, state, recent[index]),
                ),
              ),
            ),
          ],
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
// APPEND-MARKER

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
    final active = state.activeProvider;

    if (active == null || !active.isConfigured) {
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
                active == null
                    ? 'Add an OpenAI-compatible or Anthropic provider to chat.'
                    : 'Add a base URL, API key and model before you can chat.',
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

    final model = active.model.trim();
    return Card(
      color: scheme.surfaceContainerHighest,
      elevation: 0,
      child: ListTile(
        leading: Icon(Icons.cloud_done_outlined, color: scheme.primary),
        title: Text(
          active.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${active.kind.label} · ${model.isEmpty ? 'no model' : model}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: onSettings,
      ),
    );
  }
}

/// Fills the body on a fresh Home with no chats yet — a friendly nudge towards
/// the New chat button (or settings, when the provider is not configured).
class _WelcomeHome extends StatelessWidget {
  const _WelcomeHome({required this.configured});

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
            Icon(Icons.waving_hand_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('Welcome to MaiChat',
                style: Theme.of(context).textTheme.titleMedium),
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
