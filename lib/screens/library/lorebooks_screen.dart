import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/lorebook.dart';
import '../../services/lorebook_codec.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/library_drawer.dart';
import 'lorebook_edit_screen.dart';

/// How the shelf is ordered.
enum LorebookSort {
  recent('Recently updated'),
  added('Recently added'),
  name('Name (A–Z)'),
  entries('Most entries');

  const LorebookSort(this.label);
  final String label;
}

/// The Lorebooks shelf: a search bar, sort / tag / view controls, a starred
/// shelf pinned above the rest, and per-book actions.
///
/// This is deliberately the Characters roster wearing a different object: the
/// two are browsed the same way (search, sort, tag filter, cards or rows,
/// long-press to multi-select, import from the app bar), and a user who has
/// learnt one should not have to learn the other. Search reaches inside the
/// books — [Lorebook.matches] looks at entry text and keywords too — because
/// what you usually remember is the fact, not which book you filed it in.
class LorebooksScreen extends StatefulWidget {
  const LorebooksScreen({super.key});

  @override
  State<LorebooksScreen> createState() => _LorebooksScreenState();
}

class _LorebooksScreenState extends State<LorebooksScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _cardView = true;
  LorebookSort _sort = LorebookSort.recent;
  final Set<String> _tagFilter = <String>{};
  bool _selecting = false;
  final Set<String> _selection = <String>{};

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  // --- filtering / sorting -------------------------------------------------

  /// Every tag across the shelf, for the tag-filter sheet.
  List<String> _allTags(List<Lorebook> books) {
    final tags = <String>{};
    for (final b in books) {
      tags.addAll(b.tags);
    }
    final sorted = tags.toList()..sort();
    return sorted;
  }

  /// Applies the text query and tag filter (tags match on AND), then the sort.
  List<Lorebook> _visible(List<Lorebook> books) {
    final result = books.where((b) {
      if (_tagFilter.isNotEmpty &&
          !_tagFilter.every((t) => b.tags.contains(t))) {
        return false;
      }
      return b.matches(_query);
    }).toList();

    switch (_sort) {
      case LorebookSort.recent:
        result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      case LorebookSort.added:
        result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case LorebookSort.name:
        result.sort((a, b) =>
            a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));
      case LorebookSort.entries:
        result.sort((a, b) => b.entries.length.compareTo(a.entries.length));
    }
    return result;
  }

  // --- selection -----------------------------------------------------------

  void _toggleSelect(String id) {
    setState(() {
      if (_selection.contains(id)) {
        _selection.remove(id);
      } else {
        _selection.add(id);
      }
    });
  }

  void _exitSelection() => setState(() {
        _selecting = false;
        _selection.clear();
      });

  Future<void> _deleteSelected(AppState state) async {
    if (_selection.isEmpty) return;
    final count = _selection.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete $count lorebook${count == 1 ? '' : 's'}?'),
        content: const Text('Chats using them keep working — they simply stop '
            'injecting these facts.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    for (final id in _selection.toList()) {
      await state.deleteLorebook(id);
    }
    if (mounted) _exitSelection();
  }

  Future<void> _exportSelected(AppState state) async {
    final chosen =
        state.lorebooks.where((b) => _selection.contains(b.id)).toList();
    if (chosen.isEmpty) return;
    // One file for the whole selection: the importer reads an array back as a
    // bundle, so a multi-selection round-trips as a single document.
    await _offerExport(
      context,
      json: LorebookCodec.exportManyNative(chosen),
      fileName: 'lorebooks-${chosen.length}.json',
      subtitle: '${chosen.length} lorebooks, MaiChat format',
    );
  }

  // --- create / import -----------------------------------------------------

  Future<void> _createNew() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const LorebookEditScreen()),
    );
  }

  Future<void> _open(Lorebook book) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LorebookEditScreen(book: book)),
    );
  }

  /// The add sheet: create from scratch, or bring a book in from a file or the
  /// clipboard. Both import paths land in [_ingest], which works out which of
  /// the four supported shapes the text is.
  void _showImportSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ListTile(
              leading: const Icon(Icons.add),
              title: const Text('Create new lorebook'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _createNew();
              },
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
              child: Text(
                'IMPORT FROM',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.insert_drive_file_outlined),
              title: const Text('A .json file'),
              subtitle: const Text('SillyTavern world info, an Agnai memory '
                  'book, a character card, or a MaiChat export'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _importFile();
              },
            ),
            ListTile(
              leading: const Icon(Icons.content_paste_outlined),
              title: const Text('Paste JSON'),
              subtitle: const Text('Straight from the clipboard'),
              onTap: () {
                Navigator.of(sheetContext).pop();
                _pasteJson();
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  /// Picks one or more `.json` files and imports every book in them. A world
  /// file carries no name of its own, so the file name is handed to the parser
  /// to use as one.
  Future<void> _importFile() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(
        dialogTitle: 'Import lorebook',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: true,
        withData: true,
      );
    } catch (_) {
      result = null;
    }
    final files = result?.files ?? const [];
    if (files.isEmpty) return;
    final books = <Lorebook>[];
    String? firstError;
    for (final file in files) {
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) continue;
      try {
        books.addAll(LorebookCodec.parse(
          utf8.decode(bytes),
          fileName: _baseName(file.name),
        ));
      } on FormatException catch (e) {
        firstError ??= e.message;
      } catch (_) {
        firstError ??= 'Could not read ${file.name} as a lorebook.';
      }
    }
    await _store(books, firstError);
  }

  /// The clipboard path, for a book copied out of a browser or another app.
  Future<void> _pasteJson() async {
    final controller = TextEditingController();
    // Pre-fill from the clipboard: nine times out of ten that is exactly what
    // the user meant to paste, and it saves a long-press in a text field.
    final clip = await Clipboard.getData(Clipboard.kTextPlain);
    controller.text = clip?.text ?? '';
    if (!mounted) {
      controller.dispose();
      return;
    }
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste lorebook JSON'),
        content: TextField(
          controller: controller,
          minLines: 5,
          maxLines: 10,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            hintText: '{ "entries": … }',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Import'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.trim().isEmpty) return;
    await _ingest(text, null);
  }

  /// Parses [text] as one book or a bundle, then stores whatever came out.
  Future<void> _ingest(String text, String? fileName) async {
    try {
      await _store(LorebookCodec.parse(text, fileName: fileName), null);
    } on FormatException catch (e) {
      _say(e.message);
    } catch (_) {
      _say('Could not read that as a lorebook.');
    }
  }

  /// Adds [books] to the library and reports what happened. [error] is the first
  /// parse failure, shown only when nothing at all could be read.
  Future<void> _store(List<Lorebook> books, String? error) async {
    if (books.isEmpty) {
      _say(error ?? 'Could not read that as a lorebook.');
      return;
    }
    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    await state.addLorebooks(books);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text(books.length == 1
          ? 'Imported "${books.single.displayName}" '
              '(${books.single.entries.length} entries).'
          : 'Imported ${books.length} lorebooks.'),
    ));
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  // --- per-book actions ----------------------------------------------------

  Future<void> _runAction(
      AppState state, Lorebook book, _LoreAction action) async {
    switch (action) {
      case _LoreAction.edit:
        await _open(book);
      case _LoreAction.download:
        await _exportOne(book);
      case _LoreAction.duplicate:
        await state.duplicateLorebook(book);
        _say('Lorebook duplicated.');
      case _LoreAction.delete:
        await _confirmDelete(state, book);
    }
  }

  /// Offers the three export shapes, then hands the text to the file / clipboard
  /// chooser. The default is this app's own format, which is the only lossless
  /// one; the other two exist for moving a book to where it came from.
  Future<void> _exportOne(Lorebook book) async {
    final format = await showModalBottomSheet<LoreExportFormat>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in LoreExportFormat.values)
              ListTile(
                leading: Icon(switch (f) {
                  LoreExportFormat.native => Icons.data_object_outlined,
                  LoreExportFormat.sillyTavern => Icons.public_outlined,
                  LoreExportFormat.agnai => Icons.smart_toy_outlined,
                }),
                title: Text(f.label),
                subtitle: Text(f.blurb),
                onTap: () => Navigator.of(context).pop(f),
              ),
          ],
        ),
      ),
    );
    if (format == null || !mounted) return;
    final safe = _safeName(book.displayName);
    await _offerExport(
      context,
      json: format.write(book),
      fileName: '${safe.isEmpty ? 'lorebook' : safe}.json',
      subtitle: format.label,
    );
  }

  Future<void> _confirmDelete(AppState state, Lorebook book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete lorebook?'),
        content: Text('"${book.displayName}" will be removed, and switched off '
            'in any chat using it.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) await state.deleteLorebook(book.id);
  }

  // --- tag filter / sort ---------------------------------------------------

  void _showTagFilter(List<String> tags) {
    if (tags.isEmpty) {
      _say('No tags on any lorebook yet.');
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Filter by tag',
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                    if (_tagFilter.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          setSheetState(() => _tagFilter.clear());
                          setState(() {});
                        },
                        child: const Text('Clear'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final tag in tags)
                      FilterChip(
                        label: Text(tag),
                        selected: _tagFilter.contains(tag),
                        onSelected: (on) {
                          setSheetState(() {
                            if (on) {
                              _tagFilter.add(tag);
                            } else {
                              _tagFilter.remove(tag);
                            }
                          });
                          setState(() {});
                        },
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

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<LorebookSort>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in LorebookSort.values)
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

  // --- build ---------------------------------------------------------------

  void _onItemTap(Lorebook book) {
    if (_selecting) {
      _toggleSelect(book.id);
    } else {
      _open(book);
    }
  }

  void _onItemLongPress(Lorebook book) {
    setState(() {
      _selecting = true;
      _selection.add(book.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final all = state.lorebooks;
    final tags = _allTags(all);
    final visible = _visible(all);
    final starred = visible.where((b) => b.starred).toList();
    final others = visible.where((b) => !b.starred).toList();
    final hasStar = starred.isNotEmpty;
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      drawer: _selecting
          ? null
          : const LibraryDrawer(selected: LibrarySection.lorebooks),
      appBar: _selecting ? _selectionAppBar(state) : _mainAppBar(),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _createNew,
              icon: const Icon(Icons.add),
              label: const Text('New lorebook'),
            ),
      // The search bar and controls ride at the top of the scroll view (not a
      // fixed header), so they scroll away as the shelf is browsed.
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _searchAndControls(tags)),
          if (all.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyShelf(onCreate: _createNew),
            )
          else if (visible.isEmpty)
            const SliverFillRemaining(hasScrollBody: false, child: _NoMatches())
          else ...[
            if (hasStar) ...[
              _header('Starred'),
              _shelf(state, starred),
            ],
            if (others.isNotEmpty) ...[
              if (hasStar) _header('All lorebooks'),
              _shelf(state, others),
            ],
            SliverToBoxAdapter(child: SizedBox(height: 96 + bottom)),
          ],
        ],
      ),
    );
  }

  AppBar _mainAppBar() => AppBar(
        title: const Text('Lorebooks'),
        actions: [
          IconButton(
            tooltip: 'Import',
            icon: const Icon(Icons.upload_file_outlined),
            onPressed: _showImportSheet,
          ),
          IconButton(
            tooltip: 'New lorebook',
            icon: const Icon(Icons.add),
            onPressed: _createNew,
          ),
          IconButton(
            tooltip: 'Select multiple',
            icon: const Icon(Icons.checklist),
            onPressed: () => setState(() => _selecting = true),
          ),
        ],
      );

  AppBar _selectionAppBar(AppState state) => AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: _exitSelection,
        ),
        title: Text('${_selection.length} selected'),
        actions: [
          IconButton(
            tooltip: 'Export selected',
            icon: const Icon(Icons.download_outlined),
            onPressed: _selection.isEmpty ? null : () => _exportSelected(state),
          ),
          IconButton(
            tooltip: 'Delete selected',
            icon: const Icon(Icons.delete_outline),
            onPressed: _selection.isEmpty ? null : () => _deleteSelected(state),
          ),
        ],
      );

  Widget _searchAndControls(List<String> tags) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      child: Column(
        children: [
          SearchBar(
            controller: _search,
            hintText: 'Search lorebooks',
            padding: const WidgetStatePropertyAll(
              EdgeInsets.symmetric(horizontal: 14),
            ),
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
                icon: Icons.sort,
                label: _sort.label,
                onTap: _pickSort,
              ),
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
              IconButton(
                tooltip: _cardView ? 'Show as list' : 'Show as grid',
                icon: Icon(_cardView
                    ? Icons.view_list_outlined
                    : Icons.grid_view_outlined),
                onPressed: () => setState(() => _cardView = !_cardView),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _header(String text) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      );

  /// One section of books, as cards or as rows.
  Widget _shelf(AppState state, List<Lorebook> list) {
    if (_cardView) {
      return SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        sliver: SliverGrid.builder(
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 200,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.74,
          ),
          itemCount: list.length,
          itemBuilder: (context, i) => _LorebookCard(
            book: list[i],
            selecting: _selecting,
            selected: _selection.contains(list[i].id),
            onTap: () => _onItemTap(list[i]),
            onLongPress: () => _onItemLongPress(list[i]),
            onToggleStar: () => state.toggleLorebookStar(list[i].id),
            onAction: (a) => _runAction(state, list[i], a),
          ),
        ),
      );
    }
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      sliver: SliverList.builder(
        itemCount: list.length,
        itemBuilder: (context, i) => _LorebookTile(
          book: list[i],
          selecting: _selecting,
          selected: _selection.contains(list[i].id),
          onTap: () => _onItemTap(list[i]),
          onLongPress: () => _onItemLongPress(list[i]),
          onToggleStar: () => state.toggleLorebookStar(list[i].id),
          onAction: (a) => _runAction(state, list[i], a),
        ),
      ),
    );
  }
}

/// The per-book actions, shared by the card's and the row's 3-dot menu so both
/// entry points behave identically.
enum _LoreAction {
  edit('Edit', Icons.edit_outlined),
  download('Download', Icons.download_outlined),
  duplicate('Duplicate', Icons.copy_all_outlined),
  delete('Delete', Icons.delete_outline);

  const _LoreAction(this.label, this.icon);
  final String label;
  final IconData icon;
}

List<PopupMenuEntry<_LoreAction>> _loreMenuItems() => [
      for (final action in _LoreAction.values)
        PopupMenuItem<_LoreAction>(
          value: action,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(action.icon),
            title: Text(action.label),
          ),
        ),
    ];

/// A small pill button used for the sort and tag controls under the search bar.
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
      avatar: Icon(
        icon,
        size: 18,
        color: selected ? scheme.onSecondaryContainer : scheme.onSurfaceVariant,
      ),
      label: Text(label),
      backgroundColor: selected ? scheme.secondaryContainer : null,
      side: selected ? BorderSide.none : null,
      onPressed: onTap,
    );
  }
}

/// How many entries a book holds, phrased for a label.
String _entryCount(Lorebook book) {
  final n = book.entries.length;
  return n == 1 ? '1 entry' : '$n entries';
}

/// The book's own accent colour, falling back to the app's primary.
Color _accentOf(Lorebook book, ColorScheme scheme) =>
    book.color == null ? scheme.primary : Color(book.color!);

/// A book in the card grid: the picture (or a tinted book glyph) up top, and a
/// label slot beneath carrying the name, the entry count and the actions menu.
class _LorebookCard extends StatelessWidget {
  const _LorebookCard({
    required this.book,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleStar,
    required this.onAction,
  });

  final Lorebook book;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleStar;
  final ValueChanged<_LoreAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _CardImage(book: book),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: _GlassIcon(
                      icon: book.starred ? Icons.star : Icons.star_border,
                      color: book.starred ? Colors.amber : null,
                      onTap: onToggleStar,
                    ),
                  ),
                  if (selecting)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Icon(
                        selected
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: selected ? scheme.primary : scheme.onSurface,
                      ),
                    ),
                ],
              ),
            ),
            // The name / count slot sits on a slightly stronger surface so it
            // reads as a label attached under the picture.
            Container(
              width: double.infinity,
              color: scheme.surfaceContainerHighest,
              padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _entryCount(book),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  if (!selecting)
                    SizedBox(
                      width: 32,
                      child: PopupMenuButton<_LoreAction>(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: 'Actions',
                        onSelected: onAction,
                        itemBuilder: (context) => _loreMenuItems(),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The picture area of a [_LorebookCard]: the book's thumbnail cropped to fill,
/// or a panel tinted with the book's own colour carrying a book glyph.
class _CardImage extends StatelessWidget {
  const _CardImage({required this.book});

  final Lorebook book;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _accentOf(book, scheme);
    Widget fallback() => Container(
          // A gentle blend of the accent over the surface, so a book with a
          // vivid colour is recognisable without shouting.
          color: Color.alphaBlend(
              accent.withValues(alpha: 0.18), scheme.surfaceContainerHigh),
          alignment: Alignment.center,
          child: Icon(Icons.auto_stories, size: 44, color: accent),
        );

    // Shared provider: decoded once, at card size, however many cards show it.
    final provider = avatarImage(
      book.thumbnail,
      displaySize: 320,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) return fallback();
    return Image(
      image: provider,
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback(),
    );
  }
}

/// A translucent, tappable circular icon that floats over the card image
/// (used for the star toggle).
class _GlassIcon extends StatelessWidget {
  const _GlassIcon({required this.icon, required this.onTap, this.color});

  final IconData icon;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface.withValues(alpha: 0.72),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Icon(icon, size: 18, color: color ?? scheme.onSurface),
        ),
      ),
    );
  }
}

/// A book in the names list: a small thumbnail, the name, its blurb, the entry
/// count, and the star / actions affordances.
class _LorebookTile extends StatelessWidget {
  const _LorebookTile({
    required this.book,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onToggleStar,
    required this.onAction,
  });

  final Lorebook book;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onToggleStar;
  final ValueChanged<_LoreAction> onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: selected
            ? BorderSide(color: scheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        leading: selecting
            ? Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                color: selected ? scheme.primary : scheme.onSurfaceVariant,
              )
            : _Thumb(book: book),
        title: Text(
          book.displayName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(book.blurb, maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text(
              _entryCount(book),
              style: Theme.of(context)
                  .textTheme
                  .labelSmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
        trailing: selecting
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: book.starred ? 'Unstar' : 'Star',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      book.starred ? Icons.star : Icons.star_border,
                      color: book.starred ? Colors.amber : null,
                    ),
                    onPressed: onToggleStar,
                  ),
                  PopupMenuButton<_LoreAction>(
                    tooltip: 'Actions',
                    icon: const Icon(Icons.more_vert),
                    onSelected: onAction,
                    itemBuilder: (context) => _loreMenuItems(),
                  ),
                ],
              ),
      ),
    );
  }
}

/// The small rounded thumbnail that leads a [_LorebookTile] — a square rather
/// than a circle, because a book is an object, not a face.
class _Thumb extends StatelessWidget {
  const _Thumb({required this.book});

  final Lorebook book;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = _accentOf(book, scheme);
    final provider = avatarImage(
      book.thumbnail,
      displaySize: 44,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    Widget glyph() => Icon(Icons.auto_stories, size: 22, color: accent);
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Color.alphaBlend(
            accent.withValues(alpha: 0.18), scheme.surfaceContainerHigh),
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      child: provider == null
          ? glyph()
          : Image(
              image: provider,
              fit: BoxFit.cover,
              width: 44,
              height: 44,
              errorBuilder: (_, _, _) => glyph(),
            ),
    );
  }
}

/// Shown when there are no lorebooks at all — a friendly nudge to make one.
class _EmptyShelf extends StatelessWidget {
  const _EmptyShelf({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.auto_stories_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text('No lorebooks yet',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'A lorebook feeds facts about your world into a chat when the '
              'conversation mentions them. Create one, or import a SillyTavern '
              'world or an Agnai memory book.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onCreate,
              icon: const Icon(Icons.add),
              label: const Text('Create lorebook'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown when a search / tag filter matches nothing.
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
            Text(
              'No lorebooks match your search.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The shared save-to-file / copy-to-clipboard chooser for exports — the same
/// two permission-free routes character export offers, so a download behaves
/// the same wherever it is started from.
Future<void> _offerExport(
  BuildContext context, {
  required String json,
  required String fileName,
  required String subtitle,
}) async {
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
            subtitle: Text(subtitle),
            onTap: () => Navigator.of(context).pop('file'),
          ),
          ListTile(
            leading: const Icon(Icons.copy_all_outlined),
            title: const Text('Copy JSON to clipboard'),
            onTap: () => Navigator.of(context).pop('clipboard'),
          ),
        ],
      ),
    ),
  );
  if (choice == null || !context.mounted) return;

  if (choice == 'clipboard') {
    await Clipboard.setData(ClipboardData(text: json));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard.')),
      );
    }
    return;
  }

  String? path;
  try {
    path = await FilePicker.saveFile(
      dialogTitle: 'Save lorebook',
      fileName: fileName,
      bytes: Uint8List.fromList(utf8.encode(json)),
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
  } catch (_) {
    path = null;
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(path == null ? 'Export cancelled.' : 'Saved to $path'),
    ),
  );
}

String _safeName(String s) => s
    .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
    .trim()
    .replaceAll(RegExp(r'\s+'), '_');

/// A picked file's name without its extension — what a SillyTavern world file
/// means by its own name.
String _baseName(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot <= 0 ? fileName : fileName.substring(0, dot);
}
