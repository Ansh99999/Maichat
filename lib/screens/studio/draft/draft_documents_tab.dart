import 'package:flutter/material.dart';

import '../../../models/studio.dart';
import '../../../services/studio/studio_controller.dart';
import 'draft_widgets.dart';

/// The draft's background documents — the texts too long or loose for a
/// lorebook entry. Each folds open to its full text and can be renamed,
/// rewritten or removed; new ones can be written here too.
class DraftDocumentsTab extends StatelessWidget {
  const DraftDocumentsTab({super.key, required this.controller});

  final StudioController controller;

  Future<void> _add(BuildContext context) async {
    final name = await editDraftText(
      context,
      label: 'Document name',
      value: '',
      tall: false,
    );
    if (name == null || name.trim().isEmpty || !context.mounted) return;
    final text = await editDraftText(context, label: name.trim(), value: '');
    if (text == null || text.trim().isEmpty) return;
    controller.editByHand('Wrote document "${name.trim()}" by hand', (ws) {
      ws.documents.add(
        StudioDocument(
          id: DateTime.now().microsecondsSinceEpoch.toString(),
          name: name.trim(),
          text: text.trim(),
        ),
      );
    });
  }

  Future<void> _menu(BuildContext context, StudioDocument doc) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('Rename'),
              onTap: () => Navigator.of(sheet).pop('rename'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('Remove from draft'),
              onTap: () => Navigator.of(sheet).pop('remove'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted) return;
    if (action == 'rename') {
      final name = await editDraftText(
        context,
        label: 'Document name',
        value: doc.name,
        tall: false,
      );
      if (name == null || name.trim().isEmpty) return;
      controller.editByHand(
        'Renamed document "${doc.name}" by hand',
        (ws) => ws.document(doc.id)?.name = name.trim(),
      );
    } else if (action == 'remove') {
      controller.editByHand(
        'Removed document "${doc.name}"',
        (ws) => ws.documents.removeWhere((d) => d.id == doc.id),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final ws = controller.session.workspace;
    final state = controller.state;
    final locked = controller.running;
    return ListView(
      key: const PageStorageKey('draft-documents'),
      padding: draftListPadding(context),
      children: [
        if (locked) const DraftLockedNote(),
        DraftSectionLabel('Documents', count: ws.documents.length, first: true),
        if (ws.documents.isEmpty)
          const DraftEmpty(
            icon: Icons.description_outlined,
            text:
                'No documents yet. They hold background — a history, a '
                'setting guide — recalled by meaning when embeddings are on.',
          )
        else
          DraftCard(
            children: [
              for (final doc in ws.documents)
                DraftFieldRow(
                  key: ValueKey('draft-doc-${doc.id}'),
                  label: doc.name.trim().isEmpty
                      ? 'Untitled document'
                      : doc.name,
                  value: doc.text,
                  tokens: state.estimateTokens(doc.text),
                  onEdit: locked
                      ? null
                      : () async {
                          final next = await editDraftText(
                            context,
                            label: doc.name,
                            value: doc.text,
                          );
                          if (next == null) return;
                          controller.editByHand(
                            'Edited document "${doc.name}" by hand',
                            (ws) => ws.document(doc.id)?.text = next,
                          );
                        },
                  trailing: IconButton(
                    tooltip: 'More for ${doc.name}',
                    onPressed: locked ? null : () => _menu(context, doc),
                    icon: const Icon(Icons.more_vert, size: 20),
                  ),
                ),
            ],
          ),
        DraftAddButton(
          label: 'New document',
          onPressed: locked ? null : () => _add(context),
        ),
      ],
    );
  }
}
