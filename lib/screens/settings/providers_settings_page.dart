import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/provider.dart';
import '../../services/tokenizer.dart';
import '../../state/app_state.dart';
import 'provider_settings_page.dart';
import 'setting_anchors.dart';
import 'setting_highlight.dart';

/// Lists the configured providers (pick the active one, edit, or add) and, at
/// the top, the app-wide tokenizer used for all token counting.
class ProvidersSettingsPage extends StatelessWidget {
  const ProvidersSettingsPage({super.key, this.highlight});

  final SettingAnchor? highlight;

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
      body: RadioGroup<String>(
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
            SettingHighlight(
              active: highlight == SettingAnchor.tokenizer,
              child: const _TokenizerSection(),
            ),
            const Divider(height: 24),
            _header(context, 'Providers'),
            if (providers.isEmpty)
              _emptyHint(context)
            else
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

  Widget _emptyHint(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Text(
        'No providers yet. Add an OpenAI-compatible, Anthropic or Gemini '
        'endpoint to start chatting.',
        style: Theme.of(context)
            .textTheme
            .bodyMedium
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

Widget _header(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
      ),
    );

/// The app-wide tokenizer picker: which real tokenizer counts context tokens
/// everywhere (budget, breakdowns, info). A live sample proves it is working.
class _TokenizerSection extends StatelessWidget {
  const _TokenizerSection();

  static const _sample = 'The quick brown fox jumps over the lazy dog.';

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = state.tokenizerConfig;
    final scheme = Theme.of(context).colorScheme;
    final sampleCount = state.estimateTokens(_sample);
    final encoding = state.activeTokenizerEncoding;

    String subtitle() => switch (config.kind) {
          TokenizerKind.openai =>
            'Exact tiktoken counts; encoding follows the active model.',
          TokenizerKind.anthropic =>
            'Approximate offline (o200k); exact counts show in a message’s '
                'Info when a Claude key is set.',
          TokenizerKind.custom => 'Uses the chosen BPE encoding everywhere.',
        };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _header(context, 'Tokenizer'),
        ListTile(
          dense: true,
          leading: const Icon(Icons.calculate_outlined),
          title: const Text('Token counter'),
          subtitle: Text(subtitle()),
          trailing: DropdownButton<TokenizerKind>(
            value: config.kind,
            underline: const SizedBox.shrink(),
            onChanged: (kind) {
              if (kind != null) {
                state.updateTokenizerConfig(config.copyWith(kind: kind));
              }
            },
            items: [
              for (final k in TokenizerKind.values)
                DropdownMenuItem(value: k, child: Text(k.label)),
            ],
          ),
        ),
        if (config.kind == TokenizerKind.custom)
          ListTile(
            dense: true,
            leading: const Icon(Icons.abc_outlined),
            title: const Text('Encoding'),
            trailing: DropdownButton<BpeEncoding>(
              value: config.customEncoding,
              underline: const SizedBox.shrink(),
              onChanged: (e) {
                if (e != null) {
                  state.updateTokenizerConfig(
                      config.copyWith(customEncoding: e));
                }
              },
              items: [
                for (final e in BpeEncoding.values)
                  DropdownMenuItem(value: e, child: Text(e.label)),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Text(
            'Sample: “$_sample” → $sampleCount tokens · ${encoding.id}',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ),
      ],
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
