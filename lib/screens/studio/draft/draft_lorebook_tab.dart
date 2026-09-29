import 'package:flutter/material.dart';

import '../../../models/lorebook.dart';
import '../../../services/studio/studio_controller.dart';
import '../../library/lorebook_edit_screen.dart';
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
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LorebookEditScreen(
            book: book,
            onSave: (edited) async {
              final isNew =
                  controller.session.workspace.lorebook(edited.id) == null;
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
        ),
      );

  Future<void> _remove(BuildContext context, Lorebook book) async {
    final fromLibrary = controller.state.lorebookById(book.id) != null;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove "${book.displayName}"?'),
        content: Text(
          fromLibrary
              ? 'It is taken out of the draft and detached. The copy in your '
                    'library stays as it is.'
              : 'It is taken out of the draft. It was never saved to your '
                    'library.',
        ),
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
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
    );
    return ListView(
      key: const PageStorageKey('draft-lorebook'),
      padding: draftListPadding(context),
      children: [
        if (locked) const DraftLockedNote(),
        DraftSectionLabel('Lorebooks', count: ws.lorebooks.length, first: true),
        if (ws.lorebooks.isEmpty)
          const DraftEmpty(
            icon: Icons.menu_book_outlined,
            text:
                'No lorebooks yet. Ask the Studio for a world, or start one '
                'yourself.',
          )
        else
          for (final book in ws.lorebooks) ...[
            if (book != ws.lorebooks.first) const SizedBox(height: 12),
            _BookCard(
              key: ValueKey('draft-book-${book.id}'),
              book: book,
              fromLibrary: controller.state.lorebookById(book.id) != null,
              muted: muted,
              onOpen: locked ? null : () => _open(context, book),
              onRemove: locked ? null : () => _remove(context, book),
            ),
          ],
        DraftAddButton(
          label: 'New lorebook',
          onPressed: locked ? null : () => _open(context, null),
        ),
      ],
    );
  }
}

/// One lorebook as a roomy card: its name, how many entries, and where it came
/// from — the entries themselves wait in the editor a tap away.
class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.book,
    required this.fromLibrary,
    required this.muted,
    this.onOpen,
    this.onRemove,
  });

  final Lorebook book;
  final bool fromLibrary;
  final TextStyle? muted;
  final VoidCallback? onOpen;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final n = book.entries.length;
    final accent = book.color == null
        ? scheme.primaryContainer
        : Color(book.color!);
    final description = book.description.trim();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kDraftCardInset),
      child: Material(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(kDraftOuterRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 8, 20),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: Icon(
                    Icons.menu_book,
                    size: 26,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 2),
                      Text(book.displayName, style: theme.textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        '$n entr${n == 1 ? 'y' : 'ies'}'
                        '${fromLibrary ? ' · from your library' : ''}',
                        style: muted,
                      ),
                      if (description.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(
                          description,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Edit ${book.displayName}',
                  onPressed: onOpen,
                  icon: const Icon(Icons.edit_outlined, size: 20),
                ),
                PopupMenuButton<String>(
                  tooltip: 'More for ${book.displayName}',
                  enabled: onRemove != null,
                  onSelected: (_) => onRemove?.call(),
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                      value: 'remove',
                      child: ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.delete_outline),
                        title: Text(
                          'Remove from draft',
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
