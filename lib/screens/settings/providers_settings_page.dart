import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../state/app_state.dart';
import 'provider_settings_page.dart';

/// Lists the configured providers: pick which one is active with the radio,
/// tap a row to edit it, or add another with the button.
class ProvidersSettingsPage extends StatelessWidget {
  const ProvidersSettingsPage({super.key});

  void _edit(BuildContext context, [Provider? provider]) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ProviderSettingsPage(provider: provider),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final providers = state.providers;
    final activeId = state.activeProvider?.id;

    return Scaffold(
      appBar: AppBar(title: const Text('Providers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context),
        icon: const Icon(Icons.add),
        label: const Text('Add provider'),
      ),
      body: providers.isEmpty
          ? _empty(context)
          : RadioGroup<String>(
              groupValue: activeId,
              onChanged: (id) {
                if (id != null) state.selectProvider(id);
              },
              child: ListView(
                padding: EdgeInsets.only(
                  top: 8,
                  bottom: 96 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  for (final provider in providers)
                    _ProviderTile(
                      provider: provider,
                      onEdit: () => _edit(context, provider),
                    ),
                ],
              ),
            ),
    );
  }

  Widget _empty(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 96),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.dns_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No providers yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add an OpenAI-compatible, Anthropic or Gemini endpoint to start '
              'chatting.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// One row in the list: a radio marks the active provider, the body describes
/// it, and tapping anywhere but the radio opens the editor.
class _ProviderTile extends StatelessWidget {
  const _ProviderTile({required this.provider, required this.onEdit});

  final Provider provider;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final host = Uri.tryParse(provider.baseUrl)?.host ?? provider.baseUrl;
    final model = provider.model.trim();
    final keyCount = provider.usableKeys.length;
    final parts = <String>[
      provider.kind.label,
      host,
      model.isEmpty ? 'no model' : model,
      if (keyCount > 1) '$keyCount keys',
    ];
    return ListTile(
      onTap: onEdit,
      leading: Radio<String>(value: provider.id),
      title: Text(
        provider.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        parts.join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: const Icon(Icons.chevron_right),
    );
  }
}
