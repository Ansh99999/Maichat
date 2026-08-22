import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/conversation.dart';
import '../../models/summary.dart';
import '../../state/app_state.dart';
import '../../widgets/export_sheet.dart';
import '../../widgets/library_drawer.dart';
import '../summary/summary_edit_screen.dart';

/// The Library's global "Summary" shelf: every chat that keeps a running memory,
/// searchable, with per-item export/delete and a way to import a summary onto a
/// chat. Mirrors the lorebooks roster.
class SummariesScreen extends StatefulWidget {
  const SummariesScreen({super.key});

  @override
  State<SummariesScreen> createState() => _SummariesScreenState();
}

class _SummariesScreenState extends State<SummariesScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _title(Conversation c) =>
      c.summary!.title.trim().isEmpty ? c.title : c.summary!.title.trim();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final q = _query.trim().toLowerCase();
    final chats = [
      for (final c in state.conversationsWithSummary)
        if (q.isEmpty ||
            _title(c).toLowerCase().contains(q) ||
            c.title.toLowerCase().contains(q) ||
            c.summary!.combinedText.toLowerCase().contains(q))
          c,
    ];

    return Scaffold(
      drawer: const LibraryDrawer(selected: LibrarySection.summaries),
      appBar: AppBar(
        title: const Text('Summary'),
        actions: [
          IconButton(
            icon: const Icon(Icons.upload_file_outlined),
            tooltip: 'Import',
            onPressed: () => _import(state),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SearchBar(
              controller: _search,
              hintText: 'Search summaries',
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
          ),
          Expanded(
            child: chats.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        state.conversationsWithSummary.isEmpty
                            ? 'No chat has a summary yet. Turn one on from a '
                                'chat’s Memory panel.'
                            : 'Nothing matches',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                    itemCount: chats.length,
                    itemBuilder: (context, i) {
                      final c = chats[i];
                      return _SummaryRow(
                        title: _title(c),
                        chatTitle: c.title,
                        tokens: c.summary!.totalTokens,
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SummaryEditScreen(conversationId: c.id),
                          ),
                        ),
                        onExport: () => _export(c),
                        onDelete: () => _delete(state, c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
// APPEND-MARKER
  Future<void> _export(Conversation c) async {
    await offerExport(
      context,
      text: const JsonEncoder.withIndent('  ').convert(c.summary!.toJson()),
      fileName: '${safeFileName(_title(c))}_summary.json',
      subtitle: 'MaiChat summary',
      dialogTitle: 'Save summary',
    );
  }

  Future<void> _delete(AppState state, Conversation c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete summary?'),
        content: Text('Remove the summary from "${c.title}"? This cannot be '
            'undone.'),
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
    if (ok == true) await state.deleteSummary(c.id);
  }

  /// Imports a summary file, then asks which chat to attach it to.
  Future<void> _import(AppState state) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
          dialogTitle: 'Import summary', type: FileType.any, withData: true);
    } catch (_) {
      result = null;
    }
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null || !mounted) return;
    ChatSummary imported;
    try {
      imported = ChatSummary.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('That file is not a MaiChat summary.')));
      return;
    }
    final target = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Attach summary to which chat?')),
            for (final c in state.conversations)
              ListTile(
                title: Text(c.title,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.of(context).pop(c.id),
              ),
          ],
        ),
      ),
    );
    if (target == null) return;
    await state.setSummary(target, imported);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Summary imported.')));
    }
  }
}

/// One chat's summary in the roster.
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.title,
    required this.chatTitle,
    required this.tokens,
    required this.onTap,
    required this.onExport,
    required this.onDelete,
  });

  final String title;
  final String chatTitle;
  final int tokens;
  final VoidCallback onTap;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: scheme.secondaryContainer,
          child: Icon(Icons.summarize_outlined,
              color: scheme.onSecondaryContainer),
        ),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text('$chatTitle · $tokens tokens',
            maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          onSelected: (v) {
            switch (v) {
              case 'open':
                onTap();
              case 'export':
                onExport();
              case 'delete':
                onDelete();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'open', child: Text('Open')),
            PopupMenuItem(value: 'export', child: Text('Export')),
            PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
        ),
      ),
    );
  }
}

