import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/embedding.dart';
import '../../services/document_sources.dart';
import '../../state/app_state.dart';
import '../../widgets/library_drawer.dart';
import '../../widgets/tag_filter_sheet.dart';
import 'document_edit_screen.dart';
import 'embeddings_config_screen.dart';
import 'embeddings_info_screen.dart';

/// How the document shelf is ordered.
enum EmbeddingsSort {
  recent('Recently added'),
  name('Name (A–Z)'),
  size('Most content');

  const EmbeddingsSort(this.label);
  final String label;
}

/// The Embeddings screen: a document library that reads like the Lorebooks
/// shelf — a hamburger to the library drawer, a relaxed title with an info
/// button, import + configuration in the app bar, a search bar with sort and
/// tag filters, and the documents themselves as cards.
class EmbeddingsScreen extends StatefulWidget {
  const EmbeddingsScreen({super.key});

  @override
  State<EmbeddingsScreen> createState() => _EmbeddingsScreenState();
}

class _EmbeddingsScreenState extends State<EmbeddingsScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  EmbeddingsSort _sort = EmbeddingsSort.recent;
  final Set<String> _tagFilter = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // <!-- EMB-APPEND -->

  // --- filtering / sorting -------------------------------------------------

  List<String> _allTags(List<EmbeddingDocument> docs) {
    final tags = <String>{};
    for (final d in docs) {
      tags.addAll(d.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  List<EmbeddingDocument> _visible(List<EmbeddingDocument> docs) {
    final result = docs.where((d) {
      if (_tagFilter.isNotEmpty && !_tagFilter.every((t) => d.tags.contains(t))) {
        return false;
      }
      return d.matches(_query);
    }).toList();
    switch (_sort) {
      case EmbeddingsSort.recent:
        result.sort((a, b) => b.addedAt.compareTo(a.addedAt));
      case EmbeddingsSort.name:
        result.sort((a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      case EmbeddingsSort.size:
        result.sort((a, b) => b.tokens.compareTo(a.tokens));
    }
    return result;
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // --- import --------------------------------------------------------------

  void _showImportSheet() {
    if (!context.read<AppState>().embeddingReady) {
      _promptSetup();
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _importTile(sheetContext, Icons.link_outlined, 'Web or Wikipedia link',
                'Fetch a page and remember its text', _addUrl),
            _importTile(sheetContext, Icons.upload_file_outlined,
                'File (text, markdown or PDF)', 'Pick a document from your device',
                _addFile),
            _importTile(sheetContext, Icons.edit_note_outlined, 'Type or paste text',
                'Open an editor for the title, tags and text', _addText),
            const Divider(height: 1),
            _importTile(sheetContext, Icons.folder_zip_outlined,
                'Import a MaiChat documents file', 'A .json bundle exported here',
                _importBundle),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _importTile(BuildContext sheetContext, IconData icon, String title,
      String subtitle, VoidCallback action) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      onTap: () {
        Navigator.of(sheetContext).pop();
        action();
      },
    );
  }

  void _promptSetup() {
    _say('Turn embeddings on and pick a provider in Configuration first.');
  }

  Future<void> _addText() async {
    await Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const DocumentEditScreen()));
  }

  Future<void> _addFile() async {
    try {
      final doc = await pickDocumentFile();
      if (doc == null) return;
      await _ingest(doc);
    } on DocumentSourceException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Could not read that file.');
    }
  }

  Future<void> _addUrl() async {
    final url = await _askText('Add a web link',
        'https://en.wikipedia.org/wiki/…', multiline: false);
    if (url == null || url.trim().isEmpty) return;
    _say('Fetching…');
    try {
      final doc = await fetchDocumentUrl(url);
      await _ingest(doc);
    } on DocumentSourceException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Could not fetch that link.');
    }
  }

  Future<void> _ingest(DocumentText doc) async {
    final state = context.read<AppState>();
    _say('Indexing "${doc.name}"…');
    try {
      final saved = await state.importDocument(doc);
      if (saved != null) _say('Added "${saved.displayName}".');
    } catch (e) {
      _say('Indexing failed: $e');
    }
  }

  // <!-- EMB-APPEND-2 -->

  // --- export --------------------------------------------------------------

  /// Exports every document as a re-importable JSON bundle (title, tags and the
  /// reconstructed text — not the vectors, which are rebuilt on import).
  Future<void> _exportAll() async {
    final state = context.read<AppState>();
    final docs = state.documents;
    if (docs.isEmpty) {
      _say('No documents to export.');
      return;
    }
    _say('Preparing export…');
    final items = <Map<String, dynamic>>[];
    for (final d in docs) {
      items.add({
        'name': d.name,
        if (d.tags.isNotEmpty) 'tags': d.tags,
        'text': await state.documentText(d.id),
      });
    }
    if (!mounted) return;
    final json = const JsonEncoder.withIndent('  ')
        .convert({'maichatDocuments': items});
    await _offerExport(json, 'maichat-documents-${docs.length}.json');
  }

  Future<void> _importBundle() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
          type: FileType.any, withData: true, dialogTitle: 'Import documents');
    } catch (_) {
      result = null;
    }
    final files = result?.files ?? const [];
    if (files.isEmpty) return;
    final bytes = files.first.bytes;
    if (bytes == null) return;
    if (!mounted) return;
    final state = context.read<AppState>();
    var added = 0;
    try {
      final json = jsonDecode(utf8.decode(bytes));
      final items = json is Map ? json['maichatDocuments'] : null;
      if (items is! List) {
        _say('That is not a MaiChat documents file.');
        return;
      }
      for (final item in items) {
        if (item is! Map) continue;
        final text = item['text']?.toString() ?? '';
        if (text.trim().isEmpty) continue;
        final tags = (item['tags'] as List?)
                ?.map((e) => e.toString())
                .where((s) => s.isNotEmpty)
                .toList() ??
            const <String>[];
        final saved = await state.importDocument(
          pastedDocument(item['name']?.toString() ?? 'Document', text),
          tags: tags,
        );
        if (saved != null) added++;
      }
      _say('Imported $added document${added == 1 ? '' : 's'}.');
    } catch (e) {
      _say('Could not import that file: $e');
    }
  }

  Future<void> _offerExport(String json, String fileName) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.save_alt_outlined),
              title: const Text('Save as .json file'),
              onTap: () => Navigator.of(context).pop('file'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_all_outlined),
              title: const Text('Copy to clipboard'),
              onTap: () => Navigator.of(context).pop('clipboard'),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    if (choice == 'clipboard') {
      await Clipboard.setData(ClipboardData(text: json));
      _say('Copied to clipboard.');
      return;
    }
    String? path;
    try {
      path = await FilePicker.saveFile(
        dialogTitle: 'Save documents',
        fileName: fileName,
        bytes: Uint8List.fromList(utf8.encode(json)),
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
    } catch (_) {
      path = null;
    }
    _say(path == null ? 'Export cancelled.' : 'Saved to $path');
  }

  // --- per-document actions ------------------------------------------------

  Future<void> _open(EmbeddingDocument doc) async {
    final state = context.read<AppState>();
    // Every document opens in the same editor: you can see its text, change the
    // title and tags in one place, and (for a text/edited doc) re-index on save.
    _say('Loading…');
    final text = await state.documentText(doc.id);
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => DocumentEditScreen(document: doc, initialText: text)));
  }

  Future<void> _delete(EmbeddingDocument doc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('"${doc.displayName}" and its embeddings will be removed, '
            'and it will be detached from any chat using it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true && mounted) {
      await context.read<AppState>().deleteDocument(doc.id);
    }
  }

  // --- pickers -------------------------------------------------------------

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<EmbeddingsSort>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in EmbeddingsSort.values)
              ListTile(
                title: Text(s.label),
                trailing: _sort == s ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _sort = picked);
  }

  void _showTagFilter(List<String> tags) {
    if (tags.isEmpty) {
      _say('No tags on any document yet.');
      return;
    }
    showTagFilterSheet(context,
        tags: tags, selected: _tagFilter, onChanged: () => setState(() {}));
  }

  Future<String?> _askText(String title, String hint,
      {String initial = '', bool multiline = false}) async {
    final controller = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 8 : 1,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  // <!-- EMB-BUILD -->

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final docs = state.documents;
    final tags = _allTags(docs);
    final visible = _visible(docs);
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      drawer: const LibraryDrawer(selected: LibrarySection.embeddings),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Embeddings'),
            IconButton(
              tooltip: 'What are embeddings?',
              icon: const Icon(Icons.info_outline, size: 20),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const EmbeddingsInfoScreen())),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: _showImportSheet,
          ),
          IconButton(
            tooltip: 'Export documents',
            icon: const Icon(Icons.download_outlined),
            onPressed: _exportAll,
          ),
          IconButton(
            tooltip: 'Configuration',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => const EmbeddingsConfigScreen())),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportSheet,
        icon: const Icon(Icons.add),
        label: const Text('Add'),
      ),
      body: CustomScrollView(
        slivers: [
          if (!state.embeddingReady)
            SliverToBoxAdapter(child: _SetupBanner(onOpen: () {
              Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const EmbeddingsConfigScreen()));
            })),
          SliverToBoxAdapter(child: _searchAndControls(tags)),
          if (docs.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyShelf(onAdd: _showImportSheet),
            )
          else if (visible.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _NoMatches())
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
              sliver: SliverList.builder(
                itemCount: visible.length,
                itemBuilder: (context, i) => _DocCard(
                  doc: visible[i],
                  onTap: () => _open(visible[i]),
                  onDelete: () => _delete(visible[i]),
                ),
              ),
            ),
          SliverToBoxAdapter(child: SizedBox(height: 96 + bottom)),
        ],
      ),
    );
  }

  Widget _searchAndControls(List<String> tags) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        children: [
          SearchBar(
            controller: _search,
            hintText: 'Search documents',
            padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 14)),
            leading: const Icon(Icons.search),
            trailing: [
              if (_query.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
            ],
            onChanged: (v) => setState(() => _query = v),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              _ControlChip(
                  icon: Icons.sort, label: _sort.label, onTap: _pickSort),
              const SizedBox(width: 8),
              _ControlChip(
                icon: Icons.label_outline,
                label: _tagFilter.isEmpty
                    ? 'Tags'
                    : '${_tagFilter.length} tag${_tagFilter.length == 1 ? '' : 's'}',
                selected: _tagFilter.isNotEmpty,
                onTap: () => _showTagFilter(tags),
              ),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }
}

/// A small pill button for the sort and tag controls under the search bar.
class _ControlChip extends StatelessWidget {
  const _ControlChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: Icon(icon,
          size: 18,
          color:
              selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant),
      label: Text(label),
      backgroundColor: selected ? scheme.secondaryContainer : null,
      side: selected ? BorderSide.none : null,
      onPressed: onTap,
    );
  }
}

/// One document row: source icon, title, a size/chunk line, tags, and an
/// actions menu.
class _DocCard extends StatelessWidget {
  const _DocCard({
    required this.doc,
    required this.onTap,
    required this.onDelete,
  });

  final EmbeddingDocument doc;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (doc.source) {
      DocSource.file => Icons.description_outlined,
      DocSource.url => Icons.public_outlined,
      DocSource.paste => Icons.notes_outlined,
    };
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ListTile(
        onTap: onTap,
        isThreeLine: doc.tags.isNotEmpty,
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          foregroundColor: scheme.onSecondaryContainer,
          child: Icon(icon),
        ),
        title: Text(doc.displayName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 2),
            Text(
              '${doc.source.label} · ${doc.chunkCount} chunk'
              '${doc.chunkCount == 1 ? '' : 's'}'
              '${doc.tokens > 0 ? ' · ~${doc.tokens} tokens' : ''}',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            if (doc.tags.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final t in doc.tags) _TagPill(label: t)],
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) => switch (v) {
            'edit' => onTap(),
            'delete' => onDelete(),
            _ => null,
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
                value: 'edit',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.edit_outlined),
                  title: Text('Open & edit'),
                )),
            PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  leading: Icon(Icons.delete_outline),
                  title: Text('Delete'),
                )),
          ],
        ),
      ),
    );
  }
}

/// A small, tidy tag pill (Material's Chip is too tall/bulky for a list row).
class _TagPill extends StatelessWidget {
  const _TagPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: scheme.onSecondaryContainer),
      ),
    );
  }
}


/// Shown above the shelf when the feature is not yet ready to use.
class _SetupBanner extends StatelessWidget {
  const _SetupBanner({required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: scheme.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Embeddings are off. Turn them on and choose a provider and model '
              'to start remembering documents and past messages.',
              style: TextStyle(color: scheme.onPrimaryContainer),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton(onPressed: onOpen, child: const Text('Set up')),
        ],
      ),
    );
  }
}

class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.scatter_plot_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No documents yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Add a file, a web link, or your own text. Its content is remembered '
              'by meaning and pulled into a chat when it is relevant. Attach a '
              "document from a chat's Memory panel.",
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a document'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search_off_outlined, size: 48, color: scheme.outline),
            const SizedBox(height: 12),
            Text('No documents match your search.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}



