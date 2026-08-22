import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/embedding.dart';
import '../../models/provider.dart';
import '../../services/document_sources.dart';
import '../../state/app_state.dart';

/// Settings + document library for the embeddings ("semantic memory") feature.
/// Replaces the old "coming soon" placeholder. Everything here is opt-in; with
/// the master switch off nothing indexes, retrieves, or costs anything.
class EmbeddingsScreen extends StatefulWidget {
  const EmbeddingsScreen({super.key});

  @override
  State<EmbeddingsScreen> createState() => _EmbeddingsScreenState();
}

class _EmbeddingsScreenState extends State<EmbeddingsScreen> {
  late final TextEditingController _model = TextEditingController(
    text: context.read<AppState>().embeddingConfig.model,
  );

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  AppState get _state => context.read<AppState>();

  void _update(EmbeddingConfig next) => _state.updateEmbeddingConfig(next);

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final cfg = state.embeddingConfig;
    final openai = state.providers
        .where((p) => p.kind == ProviderKind.openai)
        .toList(growable: false);
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(title: const Text('Embeddings')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(0, 8, 0, 24 + bottom),
        children: [
          SwitchListTile(
            secondary: const Icon(Icons.scatter_plot_outlined),
            title: const Text('Enable embeddings'),
            subtitle: const Text(
                'Recall past messages and reference documents by meaning, not '
                'just keywords.'),
            value: cfg.enabled,
            onChanged: (v) => _update(cfg.copyWith(enabled: v)),
          ),
          const Divider(height: 1),
          if (cfg.enabled) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text('Provider',
                  style: Theme.of(context).textTheme.titleSmall),
            ),
            ListTile(
              title: const Text('Embedding provider'),
              subtitle: Text(openai.isEmpty
                  ? 'Add an OpenAI-format provider first'
                  : 'The provider whose /embeddings endpoint is used'),
              trailing: DropdownButton<String?>(
                value: openai.any((p) => p.id == cfg.providerId)
                    ? cfg.providerId
                    : null,
                hint: const Text('Choose'),
                onChanged: openai.isEmpty
                    ? null
                    : (id) => _update(id == null
                        ? cfg.copyWith(clearProvider: true)
                        : cfg.copyWith(providerId: id)),
                items: [
                  for (final p in openai)
                    DropdownMenuItem(value: p.id, child: Text(p.displayName)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _model,
                decoration: const InputDecoration(
                  labelText: 'Embedding model',
                  helperText: 'e.g. text-embedding-3-small',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (v) => _update(cfg.copyWith(
                    model: v.trim().isEmpty ? kDefaultEmbeddingModel : v.trim())),
                onEditingComplete: () => _update(cfg.copyWith(
                    model: _model.text.trim().isEmpty
                        ? kDefaultEmbeddingModel
                        : _model.text.trim())),
              ),
            ),
            const Divider(height: 1),
            SwitchListTile(
              title: const Text('Recall in new chats by default'),
              subtitle: const Text(
                  'New chats start with semantic recall on. Existing chats keep '
                  'their own setting.'),
              value: cfg.chatRecallDefault,
              onChanged: (v) => _update(cfg.copyWith(chatRecallDefault: v)),
            ),
            SwitchListTile(
              title: const Text('Activate lorebooks semantically'),
              subtitle: const Text(
                  'Books marked "Use embeddings" can activate by meaning, not '
                  'only by keyword.'),
              value: cfg.loreActivation,
              onChanged: (v) => _update(cfg.copyWith(loreActivation: v)),
            ),
            _AdvancedTuning(cfg: cfg, onChanged: _update),
            const Divider(height: 1),
            _DocumentsSection(onAddFile: _addFile, onAddUrl: _addUrl, onPaste: _paste),
          ],
        ],
      ),
    );
  }

  // --- Document ingestion --------------------------------------------------

  Future<void> _addFile() async {
    try {
      final doc = await pickDocumentFile();
      if (doc == null) return;
      await _importWithProgress(doc);
    } on DocumentSourceException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not read that file.');
    }
  }

  Future<void> _addUrl() async {
    final url = await _prompt('Add a web link', 'https://en.wikipedia.org/wiki/…');
    if (url == null || url.trim().isEmpty) return;
    _snack('Fetching…');
    try {
      final doc = await fetchDocumentUrl(url);
      await _importWithProgress(doc);
    } on DocumentSourceException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('Could not fetch that link.');
    }
  }

  Future<void> _paste() async {
    final text = await _prompt('Paste text', 'Paste the document text',
        multiline: true);
    if (text == null || text.trim().isEmpty) return;
    final name = await _prompt('Name this document', 'e.g. Lore notes') ?? '';
    await _importWithProgress(pastedDocument(name, text));
  }

  Future<void> _importWithProgress(DocumentText doc) async {
    if (!mounted) return;
    _snack('Indexing "${doc.name}"…');
    try {
      final saved = await _state.importDocument(doc);
      if (saved != null) _snack('Added "${saved.displayName}".');
    } on Exception catch (e) {
      _snack('Indexing failed: $e');
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<String?> _prompt(String title, String hint,
      {bool multiline = false}) async {
    final controller = TextEditingController();
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          maxLines: multiline ? 8 : 1,
          minLines: multiline ? 4 : 1,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Add')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }
}

/// The ST-style retrieval knobs, tucked behind a disclosure so the common case
/// (just turn it on) stays simple.
class _AdvancedTuning extends StatelessWidget {
  const _AdvancedTuning({required this.cfg, required this.onChanged});

  final EmbeddingConfig cfg;
  final ValueChanged<EmbeddingConfig> onChanged;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: const Icon(Icons.tune_outlined),
      title: const Text('Retrieval tuning'),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        _slider(context, 'Similarity threshold',
            cfg.threshold, 0.05, 0.9, (v) => onChanged(cfg.copyWith(threshold: v)),
            display: cfg.threshold.toStringAsFixed(2)),
        _slider(context, 'Memories to inject', cfg.insert.toDouble(), 1, 10,
            (v) => onChanged(cfg.copyWith(insert: v.round())),
            divisions: 9, display: '${cfg.insert}'),
        _slider(context, 'Query message count', cfg.queryMessages.toDouble(), 1,
            8, (v) => onChanged(cfg.copyWith(queryMessages: v.round())),
            divisions: 7, display: '${cfg.queryMessages}'),
        _slider(context, 'Protect recent messages', cfg.protect.toDouble(), 0,
            20, (v) => onChanged(cfg.copyWith(protect: v.round())),
            divisions: 20, display: '${cfg.protect}'),
        _slider(context, 'Injection depth', cfg.depth.toDouble(), 0, 20,
            (v) => onChanged(cfg.copyWith(depth: v.round())),
            divisions: 20, display: '${cfg.depth}'),
        _slider(context, 'Message chunk size', cfg.messageChunkSize.toDouble(),
            100, 2000, (v) => onChanged(cfg.copyWith(messageChunkSize: v.round())),
            divisions: 19, display: '${cfg.messageChunkSize}'),
        _slider(context, 'Document chunk size', cfg.docChunkSize.toDouble(), 500,
            10000, (v) => onChanged(cfg.copyWith(docChunkSize: v.round())),
            divisions: 19, display: '${cfg.docChunkSize}'),
      ],
    );
  }

  Widget _slider(BuildContext context, String label, double value, double min,
      double max, ValueChanged<double> onChanged,
      {int? divisions, required String display}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
              Text(display, style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
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

/// The attached-anywhere document library: add from file / web / paste, then
/// see each document's chunk count and remove it.
class _DocumentsSection extends StatelessWidget {
  const _DocumentsSection({
    required this.onAddFile,
    required this.onAddUrl,
    required this.onPaste,
  });

  final VoidCallback onAddFile;
  final VoidCallback onAddUrl;
  final VoidCallback onPaste;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final docs = state.documents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text('Documents',
              style: Theme.of(context).textTheme.titleSmall),
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'Add reference material, then attach it to a chat from its Memory '
            'panel. Searched semantically alongside the chat.',
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: onAddFile,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('File'),
              ),
              OutlinedButton.icon(
                onPressed: onAddUrl,
                icon: const Icon(Icons.link_outlined),
                label: const Text('Web link'),
              ),
              OutlinedButton.icon(
                onPressed: onPaste,
                icon: const Icon(Icons.content_paste_outlined),
                label: const Text('Paste'),
              ),
            ],
          ),
        ),
        if (docs.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('No documents yet.')),
          )
        else
          for (final d in docs)
            ListTile(
              leading: Icon(switch (d.source) {
                DocSource.file => Icons.description_outlined,
                DocSource.url => Icons.public_outlined,
                DocSource.paste => Icons.notes_outlined,
              }),
              title: Text(d.displayName),
              subtitle: Text(
                  '${d.source.label} · ${d.chunkCount} chunk${d.chunkCount == 1 ? '' : 's'}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Delete',
                onPressed: () => state.deleteDocument(d.id),
              ),
            ),
      ],
    );
  }
}


