import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../models/lorebook.dart';
import '../../state/app_state.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/color_picker.dart';
import 'lorebook_info.dart';

/// How the entry list is ordered while editing.
enum _EntrySort {
  created('Creation order', 'Order'),
  alphabetical('Alphabetically', 'A–Z');

  const _EntrySort(this.label, this.short);

  /// The wording in the picker sheet.
  final String label;

  /// The wording on the chip, where there is no room for a sentence.
  final String short;
}

/// Create or edit a lorebook. Passed a [book] it edits a copy of it and writes
/// it back on Save; with no book it builds a fresh one.
///
/// The layout follows Agnai's memory-book editor, in Android clothes: the book's
/// own identity at the top (picture, colour, name, description), then the
/// entries, which is where all the work happens — so the Entries header stays
/// pinned while the list scrolls under it, and a search + sort pair sits above
/// the cards for books that have grown to dozens of facts. The documentation is
/// folded away at the very bottom, near the fields it explains.
///
/// Entry text lives in [TextEditingController]s keyed by the entry's `uid`, not
/// by its position: searching and sorting reorder the visible list constantly,
/// and keying by index would hand one entry's controller to another. Nothing is
/// written into the model until Save.
class LorebookEditScreen extends StatefulWidget {
  const LorebookEditScreen({super.key, this.book});

  final Lorebook? book;

  @override
  State<LorebookEditScreen> createState() => _LorebookEditScreenState();
}

class _LorebookEditScreenState extends State<LorebookEditScreen> {
  final _formKey = GlobalKey<FormState>();

  /// The book being edited: a copy, so backing out really does discard.
  late final Lorebook _book;

  late final TextEditingController _name;
  late final TextEditingController _description;

  /// Comma-separated in, a list out — the same shape the character editor uses,
  /// and what the shelf's tag filter reads.
  late final TextEditingController _tags;
  final TextEditingController _entrySearch = TextEditingController();

  /// One set of controllers per entry, keyed by the entry's `uid`.
  final Map<int, _EntryFields> _fields = <int, _EntryFields>{};

  /// Which entry cards are open, again by `uid`.
  final Set<int> _expanded = <int>{};

  _EntrySort _entrySort = _EntrySort.created;

  /// The picture as it will be saved: a `local:` reference kept from the stored
  /// book, base64 for one just picked off the device, or empty for none.
  late String _thumbnail;

  /// The book's accent colour (ARGB), or null to follow the app theme.
  int? _color;

  /// Whether anything has been typed or toggled — drives the back-out warning.
  bool _dirty = false;

  bool get _isNew => widget.book == null;

  @override
  void initState() {
    super.initState();
    _book = widget.book?.copyWith() ?? Lorebook.empty();
    _name = TextEditingController(text: _book.name);
    _description = TextEditingController(text: _book.description);
    _tags = TextEditingController(text: _book.tags.join(', '));
    _thumbnail = _book.thumbnail;
    _color = _book.color;
    for (final entry in _book.entries) {
      _fields[entry.uid] = _EntryFields(entry)..attach(_markDirty);
      // A half-finished entry opens itself rather than hiding an empty form
      // behind a chevron.
      if (entry.missingFields.isNotEmpty) _expanded.add(entry.uid);
    }
    _name.addListener(_markDirty);
    _description.addListener(_markDirty);
    _tags.addListener(_markDirty);
    _entrySearch.addListener(_onEntrySearchChanged);
  }

  @override
  void dispose() {
    for (final controller in [_name, _description, _tags, _entrySearch]) {
      controller.dispose();
    }
    for (final fields in _fields.values) {
      fields.dispose();
    }
    super.dispose();
  }

  /// Marks the form dirty. Only the first edit rebuilds — every field listener
  /// lands here, and rebuilding on each keystroke would re-sort the entry list
  /// under the cursor.
  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  void _onEntrySearchChanged() => setState(() {});

  // --- picture / colour ----------------------------------------------------

  Future<void> _pickImage() async {
    FilePickerResult? result;
    try {
      result = await FilePicker.pickFiles(type: FileType.image, withData: true);
    } catch (_) {
      result = null;
    }
    final bytes = result?.files.firstOrNull?.bytes;
    if (bytes == null || bytes.isEmpty) return;
    // Base64 now; the state layer moves it into the shared picture store when
    // the book is saved, exactly as it does for a character avatar.
    setState(() {
      _thumbnail = base64Encode(bytes);
      _dirty = true;
    });
  }

  void _clearImage() => setState(() {
        _thumbnail = '';
        _dirty = true;
      });

  /// The colour sheet: the shared theme swatches (including the custom HSV
  /// picker) plus a way back to no colour at all.
  void _pickColour() {
    final scheme = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Lorebook colour',
                  style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(
                'Tints this book\'s card and its rows.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              ThemeColorPicker(
                value: _color == null ? scheme.primary : Color(_color!),
                onChanged: (colour) {
                  Navigator.of(sheetContext).pop();
                  setState(() {
                    _color = colour.toARGB32();
                    _dirty = true;
                  });
                },
              ),
              const SizedBox(height: 12),
              if (_color != null)
                TextButton.icon(
                  onPressed: () {
                    Navigator.of(sheetContext).pop();
                    setState(() {
                      _color = null;
                      _dirty = true;
                    });
                  },
                  icon: const Icon(Icons.format_color_reset_outlined),
                  label: const Text('Use theme colour'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  // --- entries -------------------------------------------------------------

  void _addEntry() {
    final entry = _book.addEntry();
    setState(() {
      _fields[entry.uid] = _EntryFields(entry)..attach(_markDirty);
      _expanded.add(entry.uid); // A brand-new entry starts open.
      _dirty = true;
    });
  }

  Future<void> _deleteEntry(LorebookEntry entry) async {
    // The name as typed, not as last saved — the card may never have been saved.
    final typed = _fields[entry.uid]?.name.text.trim() ?? '';
    final label = typed.isEmpty ? entry.displayName : typed;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: Text('"$label" will be removed from this lorebook.'),
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
    if (!mounted) return;
    setState(() {
      _book.entries.removeWhere((e) => e.uid == entry.uid);
      _fields.remove(entry.uid)?.dispose();
      _expanded.remove(entry.uid);
      _dirty = true;
    });
  }

  void _toggleExpanded(int uid) => setState(() {
        if (!_expanded.remove(uid)) _expanded.add(uid);
      });

  /// The entries to show: filtered by the entry search, then ordered. Names are
  /// read from the controllers rather than the model, so ordering and searching
  /// follow what is on screen rather than what was last saved.
  List<LorebookEntry> _visibleEntries() {
    final q = _entrySearch.text.trim().toLowerCase();
    final list = _book.entries.where((entry) {
      if (q.isEmpty) return true;
      final fields = _fields[entry.uid];
      if (fields == null) return false;
      return fields.name.text.toLowerCase().contains(q) ||
          fields.keys.text.toLowerCase().contains(q) ||
          fields.content.text.toLowerCase().contains(q);
    }).toList();

    if (_entrySort == _EntrySort.alphabetical) {
      // Creation order is the tie-break, so equal (or absent) names never
      // shuffle between rebuilds. An entry with no name yet sinks to the
      // bottom instead of heading an A–Z list.
      final order = <int, int>{
        for (var i = 0; i < _book.entries.length; i++) _book.entries[i].uid: i,
      };
      list.sort((a, b) {
        final an = _fields[a.uid]?.name.text.trim().toLowerCase() ?? '';
        final bn = _fields[b.uid]?.name.text.trim().toLowerCase() ?? '';
        if (an.isEmpty != bn.isEmpty) return an.isEmpty ? 1 : -1;
        final byName = an.compareTo(bn);
        if (byName != 0) return byName;
        return (order[a.uid] ?? 0).compareTo(order[b.uid] ?? 0);
      });
    }
    return list;
  }

  Future<void> _pickEntrySort() async {
    final picked = await showModalBottomSheet<_EntrySort>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final s in _EntrySort.values)
              ListTile(
                title: Text(s.label),
                trailing: _entrySort == s ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(s),
              ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _entrySort = picked);
  }

  // --- save / discard ------------------------------------------------------

  /// Writes every controller into its entry, then stores the book. The model is
  /// only touched here, which is what makes backing out a true discard.
  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    for (final entry in _book.entries) {
      _fields[entry.uid]?.flush(entry);
    }
    _book
      ..name = _name.text.trim()
      ..description = _description.text.trim()
      ..tags = _tags.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList()
      ..thumbnail = _thumbnail
      ..color = _color;

    final state = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    await state.saveLorebook(_book);
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(
      content: Text('Saved "${_book.displayName}".'),
    ));
    Navigator.of(context).pop(_book);
  }

  /// The back-out path: ask, and leave only if the user says so. Written as a
  /// method on the state so the pop happens against `State.context` after the
  /// dialog's async gap.
  Future<void> _confirmThenPop() async {
    final leave = await _confirmDiscard();
    if (!leave || !mounted) return;
    Navigator.of(context).pop();
  }

  /// Asked only when there are unsaved edits, so the common case (open, read,
  /// back out) is never interrupted.
  Future<bool> _confirmDiscard() async {
    final leave = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: Text(_isNew
            ? 'This lorebook has not been saved yet.'
            : 'Your edits to this lorebook will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    return leave == true;
  }

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final entries = _visibleEntries();
    final bottom = MediaQuery.paddingOf(context).bottom;

    return PopScope(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmThenPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_isNew ? 'New lorebook' : 'Edit lorebook'),
          actions: [
            TextButton(onPressed: _save, child: const Text('Save')),
          ],
        ),
        body: Form(
          key: _formKey,
          child: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(child: _bookSection()),
              // The Entries header stays put while the cards scroll under it,
              // so "+ Entry" is always within reach of a long book.
              SliverPersistentHeader(
                pinned: true,
                delegate: _EntriesHeader(
                  count: _book.entries.length,
                  onAdd: _addEntry,
                  background: scheme.surface,
                  titleStyle: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600),
                  divider: scheme.outlineVariant,
                ),
              ),
              SliverToBoxAdapter(child: _entryControls()),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                sliver: SliverList.list(
                  children: [
                    if (entries.isEmpty) _noEntries(),
                    for (final entry in entries)
                      _EntryCard(
                        key: ValueKey<int>(entry.uid),
                        entry: entry,
                        fields: _fields[entry.uid]!,
                        expanded: _expanded.contains(entry.uid),
                        onToggle: () => _toggleExpanded(entry.uid),
                        onDelete: () => _deleteEntry(entry),
                        onEnabled: (on) => setState(() {
                          entry.enabled = on;
                          _dirty = true;
                        }),
                      ),
                  ],
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(12, 8, 12, 32 + bottom),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      OutlinedButton.icon(
                        onPressed: _addEntry,
                        icon: const Icon(Icons.add),
                        label: const Text('Entry'),
                      ),
                      const SizedBox(height: 20),
                      const Divider(height: 1),
                      const LorebookInfoTile(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The book's own identity: picture, colour, name, description.
  Widget _bookSection() => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _pictureAndColour(),
            const SizedBox(height: 6),
            _field(_name, 'Name', hint: 'What this book is called',
                required: true),
            _field(_description, 'Description',
                hint: 'What it covers — optional', lines: 3),
            _field(_tags, 'Tags',
                hint: 'Comma separated — how the shelf filters books'),
            const SizedBox(height: 14),
            const Divider(height: 1),
          ],
        ),
      );

  /// A tappable picture frame beside the colour swatch. The picture is optional
  /// decoration — it exists so a shelf of books is scannable — so both controls
  /// stay small and out of the way of the fields that matter.
  Widget _pictureAndColour() {
    final scheme = Theme.of(context).colorScheme;
    final accent = _color == null ? scheme.primary : Color(_color!);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _PictureFrame(
          thumbnail: _thumbnail,
          accent: accent,
          onPick: _pickImage,
          onClear: _thumbnail.isEmpty ? null : _clearImage,
        ),
        const SizedBox(width: 20),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Colour', style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickColour,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                          border: Border.all(color: scheme.outlineVariant),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _color == null ? 'Theme colour' : hexOf(accent),
                          style: Theme.of(context)
                              .textTheme
                              .bodyMedium
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Search over the entries, with the ordering control on the same line — both
  /// are only about finding a card, so they belong together.
  Widget _entryControls() {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _entrySearch,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search entries',
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _entrySearch.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _entrySearch.clear,
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: Icon(Icons.sort, size: 18, color: scheme.onSurfaceVariant),
            label: Text(_entrySort.short),
            onPressed: _pickEntrySort,
          ),
        ],
      ),
    );
  }

  /// The placeholder that stands in for the entry cards: an empty book, or a
  /// search that matched nothing.
  Widget _noEntries() {
    final scheme = Theme.of(context).colorScheme;
    final searching = _entrySearch.text.trim().isNotEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 24),
      child: Column(
        children: [
          Icon(searching ? Icons.search_off_outlined : Icons.notes_outlined,
              size: 40, color: scheme.outline),
          const SizedBox(height: 12),
          Text(
            searching
                ? 'No entries match that search.'
                : 'No entries yet. Add one, give it a keyword or two, and write '
                    'the fact you want injected when it comes up.',
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    int lines = 1,
    bool required = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: controller,
        minLines: lines,
        maxLines: lines == 1 ? 1 : lines + 4,
        textInputAction:
            lines == 1 ? TextInputAction.next : TextInputAction.newline,
        keyboardType:
            lines == 1 ? TextInputType.text : TextInputType.multiline,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          alignLabelWithHint: lines > 1,
        ),
        validator: required
            ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
            : null,
      ),
    );
  }
}

/// The book's picture: a tappable frame that picks an image, with an X to clear
/// it and a long-press doing the same for reach.
class _PictureFrame extends StatelessWidget {
  const _PictureFrame({
    required this.thumbnail,
    required this.accent,
    required this.onPick,
    required this.onClear,
  });

  final String thumbnail;
  final Color accent;
  final VoidCallback onPick;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = avatarImage(
      thumbnail,
      displaySize: 96,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    Widget empty() => Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_photo_alternate_outlined, size: 28, color: accent),
            const SizedBox(height: 4),
            Text(
              'Picture',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
            ),
          ],
        );

    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        children: [
          Positioned.fill(
            child: Material(
              color: Color.alphaBlend(
                  accent.withValues(alpha: 0.14), scheme.surfaceContainerHigh),
              clipBehavior: Clip.antiAlias,
              borderRadius: BorderRadius.circular(16),
              child: InkWell(
                onTap: onPick,
                onLongPress: onClear,
                child: provider == null
                    ? empty()
                    : Image(
                        image: provider,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => empty(),
                      ),
              ),
            ),
          ),
          if (onClear != null)
            Positioned(
              top: 2,
              right: 2,
              child: Material(
                color: scheme.surface.withValues(alpha: 0.78),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: onClear,
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close, size: 16),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The pinned "Entries (N)  + Entry" strip. It is a persistent header rather
/// than a plain row so that adding an entry never means scrolling back to the
/// top of a long book. The background is opaque, and it grows a hairline while
/// content passes beneath it.
class _EntriesHeader extends SliverPersistentHeaderDelegate {
  const _EntriesHeader({
    required this.count,
    required this.onAdd,
    required this.background,
    required this.divider,
    this.titleStyle,
  });

  final int count;
  final VoidCallback onAdd;
  final Color background;
  final Color divider;
  final TextStyle? titleStyle;

  @override
  double get minExtent => 64;

  @override
  double get maxExtent => 64;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        border: overlapsContent
            ? Border(bottom: BorderSide(color: divider))
            : null,
      ),
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          Expanded(child: Text('Entries ($count)', style: titleStyle)),
          FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Entry'),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_EntriesHeader old) =>
      old.count != count ||
      old.background != background ||
      old.divider != divider ||
      old.titleStyle != titleStyle ||
      old.onAdd != onAdd;
}

/// One entry, as a foldable card.
///
/// The collapsed header carries everything you need to triage a book you did not
/// write: the name (editable in place), the on/off switch and delete. The body
/// is the five fields that decide behaviour, in the order you fill them in —
/// what triggers it, how it competes for room, and what it says. Tapping
/// anywhere on the header opens the card, not just the chevron, because on a
/// phone the chevron is a small target.
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    super.key,
    required this.entry,
    required this.fields,
    required this.expanded,
    required this.onToggle,
    required this.onDelete,
    required this.onEnabled,
  });

  final LorebookEntry entry;
  final _EntryFields fields;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onDelete;
  final ValueChanged<bool> onEnabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      color: scheme.surfaceContainerLow,
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: fields.name,
                      textInputAction: TextInputAction.next,
                      style: Theme.of(context)
                          .textTheme
                          .titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      decoration: const InputDecoration(
                        isDense: true,
                        hintText: 'Name of entry',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 10),
                      ),
                    ),
                  ),
                  Switch(
                    value: entry.enabled,
                    onChanged: onEnabled,
                  ),
                  IconButton(
                    tooltip: 'Delete entry',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onDelete,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) _body(context),
        ],
      ),
    );
  }

  Widget _body(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: fields.keys,
              decoration: const InputDecoration(
                labelText: 'Keywords',
                helperText: 'Comma separated. e.g. circle, shape, round',
                helperMaxLines: 2,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _number(fields.priority, 'Priority')),
                const SizedBox(width: 16),
                Expanded(child: _number(fields.weight, 'Weight')),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: fields.content,
              minLines: 4,
              maxLines: 12,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                labelText: 'Entry',
                hintText: 'What to inject. e.g. {{user}} likes fruit and '
                    'vegetables',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      );

  /// A whole-number field. The keyboard is numeric and anything else is
  /// filtered out, so the value can never come back unparseable.
  Widget _number(TextEditingController controller, String label) => TextField(
        controller: controller,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label),
      );
}

/// The controllers behind one entry card, kept in a bundle so the editor can
/// create, listen to, flush and dispose them as a unit — and so they can be held
/// in a map keyed by the entry's `uid` rather than by its place in the list.
class _EntryFields {
  _EntryFields(LorebookEntry entry)
      : name = TextEditingController(text: entry.name),
        keys = TextEditingController(text: entry.keys.join(', ')),
        priority = TextEditingController(text: '${entry.priority}'),
        weight = TextEditingController(text: '${entry.weight}'),
        content = TextEditingController(text: entry.content);

  final TextEditingController name;
  final TextEditingController keys;
  final TextEditingController priority;
  final TextEditingController weight;
  final TextEditingController content;

  List<TextEditingController> get _all =>
      [name, keys, priority, weight, content];

  /// Reports any edit to [listener] — how the screen knows it is dirty.
  void attach(VoidCallback listener) {
    for (final controller in _all) {
      controller.addListener(listener);
    }
  }

  /// Copies what was typed into [entry]. Called for every entry on Save, which
  /// is the only moment the model changes. An unparseable number keeps the value
  /// the entry already had rather than resetting it to a default.
  void flush(LorebookEntry entry) {
    entry.name = name.text.trim();
    entry.content = content.text.trim();
    entry.keys = keys.text
        .split(',')
        .map((k) => k.trim())
        .where((k) => k.isNotEmpty)
        .toList();
    entry.priority = int.tryParse(priority.text.trim()) ?? entry.priority;
    entry.weight = int.tryParse(weight.text.trim()) ?? entry.weight;
  }

  void dispose() {
    for (final controller in _all) {
      controller.dispose();
    }
  }
}
