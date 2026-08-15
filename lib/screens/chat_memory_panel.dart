import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/lorebook.dart';
import '../state/app_state.dart';
import '../widgets/avatar_image.dart';

/// The in-sidebar Memory experience for the chat screen: which lorebooks are
/// switched on for *this* chat, with a way to switch one off and a searchable
/// picker for adding another.
///
/// This panel deliberately does not edit books. A chat's memory is a set of
/// pointers ([Conversation.lorebookIds]) into the shared library, so editing a
/// book here would quietly change every other chat that uses it — that belongs
/// in the library, and keeping the two apart is what makes switching a book on
/// feel safe.
class ChatMemoryPanel extends StatefulWidget {
  const ChatMemoryPanel({super.key, required this.onBack});

  /// Return to the drawer's main menu. The panel is rendered *inside* the chat
  /// drawer rather than pushed as a route, so popping the navigator here would
  /// close the drawer instead of going back one level.
  final VoidCallback onBack;

  @override
  State<ChatMemoryPanel> createState() => _ChatMemoryPanelState();
}

class _ChatMemoryPanelState extends State<ChatMemoryPanel> {
  /// Offers the books that are *not* already on for this chat, and switches the
  /// chosen one on.
  ///
  /// The picker is built from a snapshot taken when it opens; the sheet closes
  /// on the first tap, so it never has to survive the list changing underneath.
  Future<void> _addBook(AppState state) async {
    final conversation = state.active;
    final active = conversation.lorebookIds.toSet();
    final choices = [
      for (final book in state.lorebooks)
        if (!active.contains(book.id)) book,
    ]..sort((a, b) =>
        a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      // The sheet carries a search field, so it has to be able to rise above
      // the soft keyboard rather than being clipped by it.
      isScrollControlled: true,
      builder: (context) => _LorebookPickerSheet(books: choices),
    );
    if (chosen == null || !mounted) return;
    await state.toggleConversationLorebook(conversation.id, chosen);
  }

  /// A row tap is informational only: it surfaces what the book is for, since
  /// the list itself has no room for a description.
  void _describe(Lorebook book) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${book.displayName} — ${book.blurb}'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final conversation = state.active;
    // Resolved through AppState rather than read off the id list directly, so a
    // book deleted from the library simply stops appearing here.
    final books = state.lorebooksFor(conversation);

    return Column(
      children: [
        _PanelHeader(title: 'Memory', onBack: widget.onBack),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Text(
            'Lorebooks active in this chat. Their entries are injected when the '
            'conversation mentions their keywords.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
            children: [
              if (books.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 32),
                  child: Center(
                    child: Text(
                      'No lorebooks active in this chat',
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                )
              else
                for (final book in books)
                  _ActiveBookRow(
                    book: book,
                    onTap: () => _describe(book),
                    // Toggling is switching the book off *for this chat only* —
                    // the book itself is untouched.
                    onRemove: () => state.toggleConversationLorebook(
                      conversation.id,
                      book.id,
                    ),
                  ),
              const Padding(
                padding: EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Divider(height: 1),
              ),
              ListTile(
                leading: const Icon(Icons.add),
                title: const Text('Add lorebook'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                onTap: () => _addBook(state),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One switched-on book: its picture (or a tinted glyph), its name, how much it
/// holds, and a close button that drops it from this chat.
class _ActiveBookRow extends StatelessWidget {
  const _ActiveBookRow({
    required this.book,
    required this.onTap,
    required this.onRemove,
  });

  final Lorebook book;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = book.color != null ? Color(book.color!) : scheme.primary;
    // The book's own colour, laid over the surface rather than used raw, so a
    // saturated accent picked in the library stays readable in both themes.
    final tint = book.color != null
        ? Color.alphaBlend(accent.withValues(alpha: 0.16), scheme.surface)
        : scheme.surfaceContainerLow;

    return Card(
      elevation: 0,
      color: tint,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        leading: _BookThumbnail(book: book, accent: accent),
        title: Text(
          book.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(_entryCountLabel(book)),
        trailing: IconButton(
          tooltip: 'Remove from this chat',
          icon: const Icon(Icons.close),
          onPressed: onRemove,
        ),
      ),
    );
  }
}

/// How much a book holds, in one line. Entries that are switched off are called
/// out because they do not activate — a book showing "12 entries" that injects
/// nothing would otherwise look broken.
String _entryCountLabel(Lorebook book) {
  final total = book.entries.length;
  final off = total - book.enabledCount;
  final entries = total == 1 ? '1 entry' : '$total entries';
  return off > 0 ? '$entries · $off off' : entries;
}

/// A book's picture at row size, falling back to a glyph tinted with the book's
/// own colour so an un-illustrated book still reads as itself in the list.
class _BookThumbnail extends StatelessWidget {
  const _BookThumbnail({required this.book, required this.accent});

  final Lorebook book;
  final Color accent;

  /// The drawn size, which is also what the bitmap is decoded at.
  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    final provider = book.hasThumbnail
        ? avatarImage(
            book.thumbnail,
            displaySize: _size,
            devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
          )
        : null;

    Widget fallback() => Container(
          width: _size,
          height: _size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(Icons.auto_stories, size: 20, color: accent),
        );

    if (provider == null) return fallback();
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image(
        image: provider,
        width: _size,
        height: _size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      ),
    );
  }
}

/// A back-arrow + title bar for the panel, matching the preset panel's header.
/// A private copy, so the two in-drawer panels stay visually identical without
/// either owning the other's layout.
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Back',
            onPressed: onBack,
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

/// The "add lorebook" picker: the books this chat is not already running,
/// searchable, popping the chosen book's id.
///
/// Search runs through [Lorebook.matches], which looks inside entries as well as
/// at the name — the book you want is often remembered by a fact it holds
/// ("the capital of...") rather than by what its author called it.
class _LorebookPickerSheet extends StatefulWidget {
  const _LorebookPickerSheet({required this.books});

  final List<Lorebook> books;

  @override
  State<_LorebookPickerSheet> createState() => _LorebookPickerSheetState();
}

class _LorebookPickerSheetState extends State<_LorebookPickerSheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final matches = [
      for (final book in widget.books)
        if (book.matches(_query)) book,
    ];

    return Padding(
      // Lift the sheet clear of the soft keyboard while typing.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SizedBox(
          // Tall enough to show a handful of books without swallowing the chat.
          height: MediaQuery.sizeOf(context).height * 0.6,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Add lorebook',
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: SearchBar(
                  hintText: 'Search lorebooks',
                  leading: const Icon(Icons.search, size: 20),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: matches.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            widget.books.isEmpty
                                ? 'You have no other lorebooks'
                                : 'Nothing matches',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      )
                    : ListView(
                        padding: const EdgeInsets.only(bottom: 8),
                        children: [
                          for (final book in matches)
                            ListTile(
                              title: Text(
                                book.displayName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: Text(
                                book.blurb,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Text(
                                _entryCountLabel(book),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                              onTap: () =>
                                  Navigator.of(context).pop(book.id),
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
