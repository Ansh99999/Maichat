import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/lorebook.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../library/lorebook_edit_screen.dart';
import 'creator_controls.dart';
import 'creator_draft.dart';

/// The lorebooks that travel with this character.
///
/// A book attached here activates in every chat with them — that is the whole
/// point, and it is joined onto whatever books a chat switched on for itself in
/// `AppState.lorebooksFor`. It also travels: an exported card carries its first
/// book as the spec's `character_book`, so the world info arrives with the
/// character in SillyTavern, Agnai or here.
class LorebooksTab extends StatelessWidget {
  const LorebooksTab({super.key});

  @override
  Widget build(BuildContext context) {
    final draft = context.watch<CreatorDraft>();
    final state = context.watch<AppState>();
    final attached = <Lorebook>[
      for (final id in draft.lorebookIds) ?state.lorebookById(id),
    ];

    return CreatorTabBody(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
      children: [
        const CreatorNote(
          'Facts that appear when they are mentioned. A book attached here is in '
          'force in every chat with this character, and rides along when the card '
          'is exported.',
        ),
        if (attached.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
            child: Text('No lorebook attached.'),
          ),
        for (final book in attached)
          _BookRow(
            book: book,
            onOpen: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => LorebookEditScreen(book: book),
              ),
            ),
            onDetach: () => draft.detachLorebook(book.id),
          ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              key: const Key('creator-attach-lorebook'),
              onPressed: () => _attach(context, draft, state),
              icon: const Icon(Icons.link, size: 18),
              label: const Text('Attach a lorebook'),
            ),
            OutlinedButton.icon(
              key: const Key('creator-new-lorebook'),
              onPressed: () => _createNew(context, draft),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Create a new one'),
            ),
          ],
        ),
      ],
    );
  }

  /// Opens the library and attaches what is chosen. Books already attached are
  /// shown ticked, so this doubles as the way to take one off.
  Future<void> _attach(
    BuildContext context,
    CreatorDraft draft,
    AppState state,
  ) async {
    if (state.lorebooks.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          content: Text('No lorebooks in your library yet — create one.'),
        ));
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _AttachSheet(draft: draft),
    );
  }

  /// The existing lorebook editor, on top of the creator. It saves the book to the
  /// library itself and pops it back, which is exactly the handle needed to attach
  /// it — so "create a new one" is one screen, not a parallel editor.
  Future<void> _createNew(BuildContext context, CreatorDraft draft) async {
    final book = await Navigator.of(context).push<Lorebook>(
      MaterialPageRoute<Lorebook>(
        builder: (_) => const LorebookEditScreen(),
      ),
    );
    if (book == null) return;
    draft.attachLorebook(book.id);
  }
}

class _BookRow extends StatelessWidget {
  const _BookRow({
    required this.book,
    required this.onOpen,
    required this.onDetach,
  });

  final Lorebook book;
  final VoidCallback onOpen;
  final VoidCallback onDetach;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = avatarImage(
      book.thumbnail,
      displaySize: 44,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onOpen,
        leading: CircleAvatar(
          backgroundColor: book.color == null
              ? scheme.secondaryContainer
              : Color(book.color!),
          backgroundImage: provider,
          onBackgroundImageError: provider == null ? null : (_, _) {},
          child: provider == null
              ? Icon(Icons.menu_book_outlined,
                  size: 20, color: scheme.onSecondaryContainer)
              : null,
        ),
        title: Text(book.displayName,
            maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          '${book.entries.length} '
          '${book.entries.length == 1 ? 'entry' : 'entries'}'
          '${book.vectorized ? ' · semantic' : ''}',
        ),
        trailing: IconButton(
          tooltip: 'Detach',
          icon: const Icon(Icons.link_off),
          onPressed: onDetach,
        ),
      ),
    );
  }
}

/// The library, with a tick beside every book this character carries.
class _AttachSheet extends StatefulWidget {
  const _AttachSheet({required this.draft});

  final CreatorDraft draft;

  @override
  State<_AttachSheet> createState() => _AttachSheetState();
}

class _AttachSheetState extends State<_AttachSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final media = MediaQuery.of(context);
    final books = state.lorebooks
        .where((b) => _query.isEmpty || b.matches(_query))
        .toList();

    return Padding(
      padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Attach a lorebook',
                  style: Theme.of(context).textTheme.titleMedium),
            ),
            if (state.lorebooks.length > 6)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: SearchBar(
                  controller: _search,
                  hintText: 'Search lorebooks',
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 14),
                  ),
                  leading: const Icon(Icons.search),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (books.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(20),
                      child: Text('Nothing matches that.'),
                    ),
                  for (final book in books)
                    CheckboxListTile(
                      key: Key('attach-${book.id}'),
                      value: widget.draft.lorebookIds.contains(book.id),
                      title: Text(book.displayName),
                      subtitle: Text(book.blurb,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      onChanged: (on) {
                        if (on == true) {
                          widget.draft.attachLorebook(book.id);
                        } else {
                          widget.draft.detachLorebook(book.id);
                        }
                        setState(() {});
                      },
                    ),
                ],
              ),
            ),
            SizedBox(height: media.padding.bottom + 8),
          ],
        ),
      ),
    );
  }
}
