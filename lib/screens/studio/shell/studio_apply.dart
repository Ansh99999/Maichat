import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../../services/studio/studio_controller.dart';
import '../../../state/app_state.dart';

/// Asks whether to save the draft to the library — saying exactly what it will
/// add or replace — and does it, with a snackbar saying what was written. The
/// one route by which a Studio draft reaches the library; the Changes page
/// offers it.
Future<void> showStudioApplyFlow(
  BuildContext context,
  StudioController controller,
) async {
  final state = context.read<AppState>();
  final session = controller.session;
  final ws = session.workspace;
  final c = ws.character;
  if (c.name.trim().isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('The character needs a name before it can be saved.'),
      ),
    );
    return;
  }
  final existing = state.characterById(c.id) != null;
  var folder = session.folderId != null;
  final go = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialog) => AlertDialog(
        title: const Text('Apply to library'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              existing
                  ? 'Replaces ${c.displayName} in your library with this draft.'
                  : 'Adds ${c.displayName} to your characters.',
            ),
            if (ws.lorebooks.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Saves ${ws.lorebooks.length} lorebook'
                '${ws.lorebooks.length == 1 ? '' : 's'}, attached to them.',
              ),
            ],
            if (ws.documents.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                state.embeddingReady
                    ? 'Indexes ${ws.documents.length} document'
                          '${ws.documents.length == 1 ? '' : 's'} into embeddings.'
                    : '${ws.documents.length} document'
                          '${ws.documents.length == 1 ? ' is' : 's are'} left out: '
                          'embeddings are off.',
              ),
            ],
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: folder,
              onChanged: (v) => setDialog(() => folder = v ?? false),
              title: const Text('Bundle into a folder'),
              subtitle: const Text(
                'The character, its lorebooks and '
                'documents, together.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    ),
  );
  if (go != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await controller.apply(bundleFolder: folder);
    final parts = <String>[
      'Saved ${result.characterName}',
      if (result.lorebooks > 0)
        '${result.lorebooks} lorebook${result.lorebooks == 1 ? '' : 's'}',
      if (result.documents > 0)
        '${result.documents} document${result.documents == 1 ? '' : 's'}',
      if (result.folderName != null) 'folder "${result.folderName}"',
    ];
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${parts.join(', ')}.'
          '${result.documentsSkipped > 0 ? ' ${result.documentsSkipped} document(s) skipped.' : ''}',
        ),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Could not apply: $e')));
  }
}
