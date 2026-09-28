import 'package:flutter/material.dart';

import '../../../models/lorebook.dart';
import '../../../services/studio/studio_controller.dart';
import '../../library/lorebook_edit_screen.dart';
import 'draft_header.dart';
import 'draft_widgets.dart';

/// The draft's lorebooks, each opened in the app's own lorebook editor — the
/// same screen the library uses, pointed at the draft: Save hands the book back
/// here, where it replaces the draft's copy as a recorded change, and nothing
/// reaches the library until the draft is applied.
class DraftLorebookTab extends StatelessWidget {
  const DraftLorebookTab({super.key, required this.controller});

  final StudioController controller;

  /// Opens [book] (or a new one when null) in the lorebook editor.
  Future<void> _open(BuildContext context, Lorebook? book) =>
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => LorebookEditScreen(
          book: book,
          onSave: (edited) async {
            final isNew = controller.session.workspace.lorebook(edited.id) == null;
            controller.editByHand(
              isNew
                  ? 'Added lorebook "${edited.displayName}" by hand'
                  : 'Edited lorebook "${edited.displayName}" by hand',
              (ws) {
                final at = ws.lorebooks.indexWhere((b) => b.id == edited.id);
                if (at == -1) {
                  ws.lorebooks.add(edited.copyWith());
                } else {
                  ws.lorebooks[at] = edited.copyWith();
                }
                if (!ws.character.lorebookIds.contains(edited.id)) {
                  ws.character.lorebookIds.add(edited.id);
                }
              },
            );
          },
        ),
      ));

  Future<void> _remove(BuildContext context, Lorebook book) async {
    final fromLibrary = controller.state.lorebookById(book.id) != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${book.displayName}"?'),
        content: Text(fromLibrary
            ? 'It is taken out of the draft and detached. The copy in your '
                'library stays as it is.'
            : 'It is taken out of the draft. It was never saved to your '
                'library.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    controller.editByHand('Removed lorebook "${book.displayName}"', (ws) {
      ws.lorebooks.removeWhere((b) => b.id == book.id);
      ws.character.lorebookIds.remove(book.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ws = controller.session.workspace;
    final locked = controller.running;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted =
        theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return ListView(
      key: const PageStorageKey('draft-lorebook'),
      padding: EdgeInsets.only(bottom: 24 + MediaQuery.paddingOf(context).bottom),
      children: [
        DraftHeader(character: ws.character),
        if (locked) const DraftLockedNote(),
        DraftSectionLabel('Lorebooks · ${ws.lorebooks.length}'),
        if (ws.lorebooks.isEmpty)
          const DraftEmpty(
            icon: Icons.menu_book_outlined,
            text: 'No lorebooks yet. Ask the Studio for a world, or start one '
                'yourself.',
          )
        else
          for (final book in ws.lorebooks)
            _BookCard(
              key: ValueKey('draft-book-${book.id}'),
              book: book,
              fromLibrary: controller.state.lorebookById(book.id) != null,
              tokens: controller.state.estimateTokens(
                book.entries.where((e) => e.enabled).map((e) => e.content).join('\n'),
              ),
              muted: muted,
              onOpen: locked ? null : () => _open(context, book),
              onRemove: locked ? null : () => _remove(context, book),
            ),
        DraftAddButton(
          label: 'New lorebook',
          onPressed: locked ? null : () => _open(context, null),
        ),
      ],
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.book,
    required this.fromLibrary,
    required this.tokens,
    required this.muted,
    this.onOpen,
    this.onRemove,
  });

  final Lorebook book;
  final bool fromLibrary;
  final int tokens;
  final TextStyle? muted;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entries = book.entries;
    final keys = <String>{
      for (final e in entries)
        for (final k in e.keys)
          if (k.trim().isNotEmpty) k.trim(),
    }.take(12).toList();
    final accent = book.color == null ? scheme.primaryContainer : Color(book.color!);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Material(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(24),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: accent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(Icons.menu_book,
                          size: 22, color: scheme.onPrimaryContainer),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(book.displayName,
                              style: theme.textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600)),
                          Text(
                            '${entries.length} entr${entries.length == 1 ? 'y' : 'ies'}'
                            ' · $tokens tok'
                            '${fromLibrary ? ' · from your library' : ''}',
                            style: muted,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Edit ${book.displayName}',
                      onPressed: onOpen,
                      icon: const Icon(Icons.edit_outlined, size: 20),
                    ),
                    IconButton(
                      tooltip: 'Remove ${book.displayName}',
                      onPressed: onRemove,
                      icon: const Icon(Icons.delete_outline, size: 20),
                    ),
                  ],
                ),
                if (book.description.trim().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(book.description.trim(),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium),
                  ),
                ],
                if (keys.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: DraftTagStrip(tags: keys),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
