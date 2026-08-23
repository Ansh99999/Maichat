import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/embedding.dart';
import '../../services/document_sources.dart';
import '../../state/app_state.dart';

/// Create or edit a plain-text document: a proper editor for the title, tags and
/// body, with a live token count. Used for the "Text" import option and for
/// editing an existing document's text.
class DocumentEditScreen extends StatefulWidget {
  const DocumentEditScreen({super.key, this.document, this.initialText});

  /// The document being edited, or null when creating a new one.
  final EmbeddingDocument? document;

  /// Pre-filled body when editing (its reconstructed text).
  final String? initialText;

  @override
  State<DocumentEditScreen> createState() => _DocumentEditScreenState();
}

class _DocumentEditScreenState extends State<DocumentEditScreen> {
  late final TextEditingController _title =
      TextEditingController(text: widget.document?.name ?? '');
  late final TextEditingController _tags = TextEditingController(
      text: widget.document?.tags.join(', ') ?? '');
  late final TextEditingController _body =
      TextEditingController(text: widget.initialText ?? '');
  bool _saving = false;

  bool get _isNew => widget.document == null;

  @override
  void initState() {
    super.initState();
    _body.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _title.dispose();
    _tags.dispose();
    _body.dispose();
    super.dispose();
  }

  List<String> get _tagList => _tags.text
      .split(',')
      .map((t) => t.trim())
      .where((t) => t.isNotEmpty)
      .toList();

  Future<void> _save() async {
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final text = _body.text.trim();
    if (text.isEmpty) {
      messenger.showSnackBar(
          const SnackBar(content: Text('Add some text first.')));
      return;
    }
    final title = _title.text.trim().isEmpty ? 'Text document' : _title.text.trim();
    setState(() => _saving = true);
    try {
      if (_isNew) {
        final saved = await state.importDocument(
          pastedDocument(title, text),
          tags: _tagList,
        );
        if (saved == null) {
          setState(() => _saving = false);
          return; // a notice was already surfaced
        }
      } else {
        await state.reindexDocument(
          widget.document!.id,
          text: text,
          name: title,
          tags: _tagList,
        );
      }
      messenger.showSnackBar(SnackBar(content: Text('Saved "$title".')));
      navigator.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not save: $e')));
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final tokens = state.estimateTokens(_body.text);
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isNew ? 'New text document' : 'Edit document'),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsets.all(14),
              child: SizedBox(
                  width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            )
          else
            TextButton(onPressed: _save, child: const Text('Save')),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 24 + bottom),
        children: [
          TextField(
            controller: _title,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Title',
              hintText: 'What this document is',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _tags,
            decoration: const InputDecoration(
              labelText: 'Tags',
              hintText: 'Comma separated — for filtering the shelf',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _body,
            minLines: 10,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(
              labelText: 'Text',
              hintText: 'Paste or type the document text here',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_body.text.trim().isEmpty ? 0 : _body.text.length} characters · '
              '~$tokens tokens',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
