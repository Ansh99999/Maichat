import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/lorebook.dart';
import '../../state/app_state.dart';
import '../../widgets/app_drawer.dart';
import '../../widgets/avatar_image.dart';
import '../section_screen.dart';
import '../summary/summary_edit_screen.dart';
import 'embeddings_screen.dart';
import 'lorebook_edit_screen.dart';
import 'lorebooks_screen.dart';
import 'summaries_screen.dart';

/// The Library: the shelf everything the user *writes* rather than chats with
/// lives on — lorebooks today, scenarios and embeddings once they exist.
///
/// Deliberately unhurried. This is a place to browse, so it leads with a large
/// title, one search field that covers the whole library rather than one
/// section of it, and three roomy cards instead of a dense list.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final books = state.lorebooks;
    final searching = _query.trim().isNotEmpty;

    return Scaffold(
      drawer: const AppDrawer(selected: DrawerSection.library),
      body: CustomScrollView(
        slivers: [
          const SliverAppBar.large(title: Text('Library')),
          SliverToBoxAdapter(child: _searchField(context)),
          if (searching)
            ..._results(context, books)
          else
            ..._sections(context, books),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ),
    );
  }

  /// One field for the whole library, not one per section — the point of a
  /// library is that you can look for a fact without first knowing which shelf
  /// it is on.
  Widget _searchField(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
        child: SearchBar(
          controller: _search,
          hintText: 'Search the library',
          leading: const Icon(Icons.search),
          trailing: [
            if (_query.isNotEmpty)
              IconButton(
                tooltip: 'Clear',
                icon: const Icon(Icons.close),
                onPressed: () {
                  _search.clear();
                  setState(() => _query = '');
                },
              ),
          ],
          onChanged: (value) => setState(() => _query = value),
        ),
      );

  /// The resting state: what the library holds, one card per shelf.
  List<Widget> _sections(BuildContext context, List<Lorebook> books) {
    final entries = books.fold<int>(0, (sum, b) => sum + b.entries.length);
    final summaries = context.read<AppState>().conversationsWithSummary.length;
    final recent = [...books]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return [
      SliverToBoxAdapter(
        child: _SectionCard(
          icon: Icons.auto_stories_outlined,
          title: 'Lorebooks',
          subtitle: books.isEmpty
              ? 'Facts the model is told when the chat mentions them'
              : '${_count(books.length, 'book')} · ${_count(entries, 'entry', 'entries')}',
          onTap: () => _open(const LorebooksScreen()),
        ),
      ),
      SliverToBoxAdapter(
        child: _SectionCard(
          icon: Icons.summarize_outlined,
          title: 'Summary',
          subtitle: summaries == 0
              ? 'Running memories your chats keep of themselves'
              : '${_count(summaries, 'chat')} with a summary',
          onTap: () => _open(const SummariesScreen()),
        ),
      ),
      SliverToBoxAdapter(
        child: _SectionCard(
          icon: Icons.theater_comedy_outlined,
          title: 'Scenarios',
          subtitle: 'Reusable openings and settings — not built yet',
          onTap: () => _open(const SectionScreen(
              title: 'Scenarios', icon: Icons.theater_comedy_outlined)),
        ),
      ),
      SliverToBoxAdapter(
        child: _SectionCard(
          icon: Icons.hub_outlined,
          title: 'Embeddings',
          subtitle: 'Semantic recall of past messages, lore and documents',
          onTap: () => _open(const EmbeddingsScreen()),
        ),
      ),
      if (recent.isNotEmpty) ...[
        _header(context, 'Recently edited'),
        SliverList.builder(
          itemCount: recent.length.clamp(0, 3),
          itemBuilder: (context, i) => _BookRow(
            book: recent[i],
            onTap: () => _open(LorebookEditScreen(book: recent[i])),
          ),
        ),
      ],
    ];
  }

  /// Search results. Books and the individual facts inside them are listed
  /// separately, because "where did I write that down" is the more common
  /// question and an entry's own name is rarely the book's.
  List<Widget> _results(BuildContext context, List<Lorebook> books) {
    final q = _query.trim().toLowerCase();
    bool bookMatches(Lorebook b) =>
        b.name.toLowerCase().contains(q) ||
        b.description.toLowerCase().contains(q) ||
        b.tags.any((t) => t.toLowerCase().contains(q));
    bool entryMatches(LorebookEntry e) =>
        e.name.toLowerCase().contains(q) ||
        e.content.toLowerCase().contains(q) ||
        e.keys.any((k) => k.toLowerCase().contains(q));

    final matchedBooks = books.where(bookMatches).toList();
    final matchedEntries = <(Lorebook, LorebookEntry)>[
      for (final book in books)
        for (final entry in book.entries)
          if (entryMatches(entry)) (book, entry),
    ];
    final matchedSummaries = [
      for (final c in context.read<AppState>().conversationsWithSummary)
        if ((c.summary!.title.toLowerCase().contains(q)) ||
            c.summary!.combinedText.toLowerCase().contains(q) ||
            c.title.toLowerCase().contains(q))
          c,
    ];

    if (matchedBooks.isEmpty &&
        matchedEntries.isEmpty &&
        matchedSummaries.isEmpty) {
      return [
        SliverToBoxAdapter(
          child: _Nothing(query: _query.trim()),
        ),
      ];
    }

    return [
      if (matchedBooks.isNotEmpty) ...[
        _header(context, 'Lorebooks'),
        SliverList.builder(
          itemCount: matchedBooks.length,
          itemBuilder: (context, i) => _BookRow(
            book: matchedBooks[i],
            onTap: () => _open(LorebookEditScreen(book: matchedBooks[i])),
          ),
        ),
      ],
      if (matchedSummaries.isNotEmpty) ...[
        _header(context, 'Summaries'),
        SliverList.builder(
          itemCount: matchedSummaries.length,
          itemBuilder: (context, i) {
            final c = matchedSummaries[i];
            return ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              leading: Icon(Icons.summarize_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
              title: Text(
                  c.summary!.title.trim().isEmpty ? c.title : c.summary!.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              subtitle: Text(c.title,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () =>
                  _open(SummaryEditScreen(conversationId: c.id)),
            );
          },
        ),
      ],
      if (matchedEntries.isNotEmpty) ...[
        _header(context, 'Entries'),
        SliverList.builder(
          itemCount: matchedEntries.length,
          itemBuilder: (context, i) {
            final (book, entry) = matchedEntries[i];
            return _EntryRow(
              book: book,
              entry: entry,
              onTap: () => _open(LorebookEditScreen(book: book)),
            );
          },
        ),
      ],
    ];
  }

  Widget _header(BuildContext context, String label) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ),
      );
}

String _count(int n, String one, [String? many]) =>
    n == 1 ? '1 $one' : '$n ${many ?? '${one}s'}';

/// A shelf in the library: a tall, softly tinted card you cannot miss, with
/// room to say what the section is for rather than only naming it.
class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 16, 22),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: scheme.onSecondaryContainer),
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A lorebook in a list: its picture (or a tinted glyph in its own colour), its
/// name, and what it holds.
class _BookRow extends StatelessWidget {
  const _BookRow({required this.book, required this.onTap});

  final Lorebook book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = book.color == null ? scheme.primary : Color(book.color!);
    final picture = book.hasThumbnail
        ? avatarImage(book.thumbnail, displaySize: 44)
        : null;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: CircleAvatar(
        radius: 22,
        backgroundColor: tint.withValues(alpha: 0.16),
        foregroundImage: picture,
        child: picture == null
            ? Icon(Icons.auto_stories_outlined, color: tint, size: 20)
            : null,
      ),
      title: Text(book.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(book.blurb, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: book.starred
          ? Icon(Icons.star, size: 18, color: scheme.primary)
          : null,
      onTap: onTap,
    );
  }
}

/// A single fact found by search, labelled with the book it lives in.
class _EntryRow extends StatelessWidget {
  const _EntryRow({
    required this.book,
    required this.entry,
    required this.onTap,
  });

  final Lorebook book;
  final LorebookEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
      leading: Icon(Icons.short_text, color: scheme.onSurfaceVariant),
      title: Text(entry.displayName,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        entry.blurb.isEmpty ? book.displayName : '${book.displayName} · ${entry.blurb}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}

/// Nothing matched. Says so, and admits which shelves are still empty by
/// design, so an unhelpful search does not read as a broken one.
class _Nothing extends StatelessWidget {
  const _Nothing({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 48, 32, 32),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 40, color: scheme.onSurfaceVariant),
          const SizedBox(height: 16),
          Text(
            'Nothing in the library matches "$query"',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Lorebooks and summaries are searchable — scenarios and embeddings '
            'are not built yet.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}


