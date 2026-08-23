import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/embedding.dart';
import '../../models/provider.dart';
import '../../services/chat_client.dart';
import '../../state/app_state.dart';
import '../presets/preset_pickers.dart';

/// All embedding settings in one place: enable, which provider/model does the
/// embedding, defaults, and the retrieval tuning — each explained in plain
/// English. Opened from the gear on the Embeddings screen.
class EmbeddingsConfigScreen extends StatelessWidget {
  const EmbeddingsConfigScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cfg = state.embeddingConfig;
    final openai = state.providers
        .where((p) => p.kind == ProviderKind.openai)
        .toList(growable: false);
    final bottom = MediaQuery.paddingOf(context).bottom;
    void update(EmbeddingConfig next) => state.updateEmbeddingConfig(next);

    final providerName = openai
        .where((p) => p.id == cfg.providerId)
        .map((p) => p.displayName)
        .cast<String?>()
        .firstWhere((_) => true, orElse: () => null);

    return Scaffold(
      appBar: AppBar(title: const Text('Embeddings settings')),
      body: ListView(
        padding: EdgeInsets.only(bottom: 24 + bottom),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.scatter_plot_outlined),
            title: const Text('Enable embeddings'),
            subtitle: const Text(
                'Master switch. While off, nothing is indexed and nothing costs '
                'anything.'),
            value: cfg.enabled,
            onChanged: (v) => update(cfg.copyWith(enabled: v)),
          ),
          if (cfg.enabled) ...[
            const Divider(height: 1),
            _sectionLabel(context, 'Connection'),
            ListTile(
              leading: const Icon(Icons.dns_outlined),
              title: const Text('Provider'),
              subtitle: Text(openai.isEmpty
                  ? 'Add an OpenAI-format provider in Settings first'
                  : (providerName ?? 'Not chosen')),
              trailing: DropdownButton<String?>(
                value:
                    openai.any((p) => p.id == cfg.providerId) ? cfg.providerId : null,
                hint: const Text('Choose'),
                underline: const SizedBox.shrink(),
                onChanged: openai.isEmpty
                    ? null
                    : (id) => update(id == null
                        ? cfg.copyWith(clearProvider: true)
                        : cfg.copyWith(providerId: id)),
                items: [
                  for (final p in openai)
                    DropdownMenuItem(value: p.id, child: Text(p.displayName)),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.memory_outlined),
              title: const Text('Embedding model'),
              subtitle: Text(cfg.model),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _pickModel(context, state, cfg),
            ),
            const Divider(height: 1),
            _sectionLabel(context, 'Defaults'),
            SwitchListTile(
              title: const Text('Recall in new chats'),
              subtitle: const Text(
                  'New chats start with semantic recall turned on. Existing '
                  'chats keep their own setting.'),
              value: cfg.chatRecallDefault,
              onChanged: (v) => update(cfg.copyWith(chatRecallDefault: v)),
            ),
            SwitchListTile(
              title: const Text('Activate lorebooks by meaning'),
              subtitle: const Text(
                  'Books marked "Use embeddings" can trigger their entries by '
                  'meaning, not only by keyword.'),
              value: cfg.loreActivation,
              onChanged: (v) => update(cfg.copyWith(loreActivation: v)),
            ),
            const Divider(height: 1),
            _sectionLabel(context, 'Retrieval tuning'),
            _explainedSlider(context,
                title: 'How closely must it match',
                help:
                    'Higher means only very related text is recalled; lower lets '
                    'in loosely related text. 0.25 is a good start.',
                value: cfg.threshold,
                min: 0.05,
                max: 0.9,
                display: cfg.threshold.toStringAsFixed(2),
                onChanged: (v) => update(cfg.copyWith(threshold: v))),
            _explainedSlider(context,
                title: 'How many pieces to recall',
                help:
                    'The number of matching chunks added to each reply. More '
                    'gives the AI more to work with, but uses more of the prompt.',
                value: cfg.insert.toDouble(),
                min: 1,
                max: 10,
                divisions: 9,
                display: '${cfg.insert}',
                onChanged: (v) => update(cfg.copyWith(insert: v.round()))),
            _explainedSlider(context,
                title: 'How much of your message to search with',
                help:
                    'How many of your most recent messages are used as the '
                    '"question" when looking for related text.',
                value: cfg.queryMessages.toDouble(),
                min: 1,
                max: 8,
                divisions: 7,
                display: '${cfg.queryMessages}',
                onChanged: (v) => update(cfg.copyWith(queryMessages: v.round()))),
            _explainedSlider(context,
                title: 'Recent messages to leave alone',
                help:
                    'The newest messages are already in view, so they are never '
                    're-added as "recalled" memory. This is how many to skip.',
                value: cfg.protect.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                display: '${cfg.protect}',
                onChanged: (v) => update(cfg.copyWith(protect: v.round()))),
            _explainedSlider(context,
                title: 'Where recalled text is placed',
                help:
                    'How far back from the newest message the recalled text is '
                    'inserted. 2 keeps it close to the latest turn.',
                value: cfg.depth.toDouble(),
                min: 0,
                max: 20,
                divisions: 20,
                display: '${cfg.depth}',
                onChanged: (v) => update(cfg.copyWith(depth: v.round()))),
            _explainedSlider(context,
                title: 'Message piece size',
                help:
                    'Long messages are split into pieces of about this many '
                    'characters before being remembered.',
                value: cfg.messageChunkSize.toDouble(),
                min: 100,
                max: 2000,
                divisions: 19,
                display: '${cfg.messageChunkSize}',
                onChanged: (v) =>
                    update(cfg.copyWith(messageChunkSize: v.round()))),
            _explainedSlider(context,
                title: 'Document piece size',
                help:
                    'Documents are split into pieces of about this many '
                    'characters. Bigger pieces keep more context together.',
                value: cfg.docChunkSize.toDouble(),
                min: 500,
                max: 10000,
                divisions: 19,
                display: '${cfg.docChunkSize}',
                onChanged: (v) => update(cfg.copyWith(docChunkSize: v.round()))),
          ],
        ],
      ),
    );
  }

  Future<void> _pickModel(
      BuildContext context, AppState state, EmbeddingConfig cfg) async {
    final providerId = cfg.providerId;
    Provider? provider;
    for (final p in state.providers) {
      if (p.id == providerId) provider = p;
    }
    if (provider == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Choose a provider first.')));
      return;
    }
    final cached = state.cachedModels(providerId);
    final chosen = await showSearchPicker(
      context: context,
      title: 'Embedding model',
      selectedId: cfg.model,
      allowCustom: true,
      refreshOnEmpty: cached.isEmpty,
      entries: [
        for (final m in cached) PickerEntry(id: m, title: m),
      ],
      onRefresh: () async {
        try {
          final models = await state.refreshModels(provider!);
          return [for (final m in models) PickerEntry(id: m, title: m)];
        } on ChatApiException catch (e) {
          throw PickerRefreshException(e.message);
        }
      },
    );
    if (chosen != null && chosen.trim().isNotEmpty) {
      state.updateEmbeddingConfig(cfg.copyWith(model: chosen.trim()));
    }
  }

  Widget _sectionLabel(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(text,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700)),
      );

  Widget _explainedSlider(
    BuildContext context, {
    required String title,
    required String help,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
    int? divisions,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                  child: Text(title, style: theme.textTheme.bodyLarge)),
              Text(display, style: theme.textTheme.labelLarge),
            ],
          ),
          Text(help,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
