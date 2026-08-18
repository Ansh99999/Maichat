import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/character.dart';
import '../../models/gallery_image.dart';
import '../../services/gallery_group.dart';
import '../../state/app_state.dart';
import '../../widgets/app_drawer.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/tag_filter_sheet.dart';
import 'gallery_actions.dart';
import 'gallery_upload_sheet.dart';
import 'gallery_zoom.dart';
import 'image_viewer_screen.dart';

/// Which gallery this is, which decides its title, what it holds and what a
/// picture can do once it is open.
enum GalleryMode {
  /// Everything, from the app drawer — including pictures that belong to nobody.
  /// The only mode that can filter by character.
  everything,

  /// One character's album, from their actions menu.
  character,

  /// One character's album, reached from inside a chat: a picture here can be
  /// thrown onto the conversation.
  chat,
}

/// A gallery: pictures grouped by date, pinch to change how many you see at once.
///
/// The three modes share one screen deliberately — the difference between "all my
/// pictures", "Sumire's pictures" and "Sumire's pictures, while talking to her" is
/// which records are listed and one extra action, not three screens that drift
/// apart.
class GalleryScreen extends StatefulWidget {
  const GalleryScreen({
    super.key,
    this.mode = GalleryMode.everything,
    this.characterId,
    this.conversationId,
  });

  final GalleryMode mode;

  /// Whose album, for [GalleryMode.character] and [GalleryMode.chat].
  final String? characterId;

  /// The thread a picture would be thrown onto, for [GalleryMode.chat].
  final String? conversationId;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  GallerySort _sort = GallerySort.newest;
  final Set<String> _tagFilter = <String>{};

  /// The character filter, in the whole-app gallery only.
  String? _ownerFilter;
  bool _filterUnowned = false;

  GalleryZoom _zoom = kDefaultGalleryZoom;

  bool _selecting = false;
  final Set<String> _selection = <String>{};

  @override
  void initState() {
    super.initState();
    if (widget.mode != GalleryMode.everything) {
      _ownerFilter = widget.characterId;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isAlbum => widget.mode != GalleryMode.everything;

  // --- what is shown -------------------------------------------------------

  /// The pool this gallery draws from before any filtering.
  List<GalleryImage> _pool(AppState state) => _isAlbum
      ? state.gallery
          .where((image) => image.characterId == widget.characterId)
          .toList()
      : state.gallery;

  List<String> _tagsOf(List<GalleryImage> images) {
    final tags = <String>{};
    for (final image in images) {
      tags.addAll(image.tags);
    }
    return tags.toList()..sort();
  }

  /// Applies the search text, the tag filter and (in the whole-app gallery) the
  /// character filter, then the chosen order.
  List<GalleryImage> _visible(AppState state, List<GalleryImage> pool) {
    final q = _query.trim().toLowerCase();
    final filtered = pool.where((image) {
      if (!_isAlbum) {
        if (_filterUnowned && image.characterId != null) return false;
        if (!_filterUnowned &&
            _ownerFilter != null &&
            image.characterId != _ownerFilter) {
          return false;
        }
      }
      // Every chosen tag must be present — the same AND semantics the character
      // roster's filter has, so the control behaves the way it looks.
      if (_tagFilter.isNotEmpty &&
          !_tagFilter.every((t) => image.tags.contains(t))) {
        return false;
      }
      if (q.isEmpty) return true;
      if (image.displayTitle.toLowerCase().contains(q)) return true;
      if (image.tags.any((t) => t.toLowerCase().contains(q))) return true;
      final owner = state.characterById(image.characterId);
      return owner != null && owner.displayName.toLowerCase().contains(q);
    }).toList();

    return sortImages(
      filtered,
      _sort,
      nameOf: (id) => state.characterById(id)?.displayName ?? '',
    );
  }

  // --- actions -------------------------------------------------------------

  Future<void> _upload() async {
    await showGalleryUploadSheet(
      context,
      characterId: _isAlbum ? widget.characterId : _ownerFilter,
      allowChoosingOwner: !_isAlbum,
    );
  }

  Future<void> _open(List<GalleryImage> images, int index) async {
    final state = context.read<AppState>();
    await state.touchGalleryImage(images[index].id);
    if (!mounted) return;
    await openImageViewer(
      context,
      images: images,
      index: index,
      // Sending depends on there being a chat to send to, not on which mode this
      // is: "All pictures" reached from a conversation must still be able to throw
      // one onto it, or that route is a dead end the user walked into.
      extra: widget.conversationId == null
          ? ViewerExtra.none
          : ViewerExtra.sendToChat,
      conversationId: widget.conversationId,
    );
  }

  void _toggleSelect(String id) => setState(() {
        if (!_selection.remove(id)) _selection.add(id);
      });

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
        title: Text('Delete $count picture${count == 1 ? '' : 's'}?'),
        content: const Text(
          'They are removed from the gallery, and from any character wearing '
          'them.',
        ),
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
    await state.deleteGalleryImages(_selection.toList());
    if (!mounted) return;
    _exitSelection();
  }

  Future<void> _exportSelected(AppState state) async {
    final chosen =
        state.gallery.where((i) => _selection.contains(i.id)).toList();
    if (chosen.isEmpty) return;
    await exportGalleryImages(context, chosen);
  }

  Future<void> _pickSort() async {
    final picked = await showModalBottomSheet<GallerySort>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in GallerySort.values)
              // "Character" only means something where several characters'
              // pictures are mixed together.
              if (!_isAlbum || option != GallerySort.character)
                ListTile(
                  title: Text(option.label),
                  trailing: _sort == option ? const Icon(Icons.check) : null,
                  onTap: () => Navigator.of(context).pop(option),
                ),
          ],
        ),
      ),
    );
    if (picked != null) setState(() => _sort = picked);
  }

  void _showTagFilter(List<String> tags) {
    if (tags.isEmpty) {
      _say('No tags on any picture here yet.');
      return;
    }
    showTagFilterSheet(
      context,
      tags: tags,
      selected: _tagFilter,
      onChanged: () => setState(() {}),
    );
  }

  Future<void> _pickOwner(AppState state) async {
    final picked = await showModalBottomSheet<_OwnerChoice>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _OwnerFilterSheet(
        characters: state.characters,
        countOf: state.galleryCountFor,
        selected: _filterUnowned ? const _OwnerChoice.unowned() : _OwnerChoice(_ownerFilter),
      ),
    );
    if (picked == null) return;
    setState(() {
      _filterUnowned = picked.unowned;
      _ownerFilter = picked.unowned ? null : picked.characterId;
    });
  }

  void _say(String message) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );

  // --- build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (!state.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final owner = state.characterById(widget.characterId);
    final pool = _pool(state);
    final tags = _tagsOf(pool);
    final visible = _visible(state, pool);
    final sections = groupImages(
      visible,
      grouping: _zoom.grouping,
      chronological: _sort.isChronological,
    );
    final bottom = MediaQuery.paddingOf(context).bottom;

    return Scaffold(
      // The drawer belongs to the whole-app gallery; an album is a place you came
      // to from somewhere, so it keeps its back arrow.
      drawer: (_selecting || _isAlbum)
          ? null
          : const AppDrawer(selected: DrawerSection.gallery),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _upload,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add'),
            ),
      body: GalleryZoomDetector(
        zoom: _zoom,
        onChanged: (zoom) => setState(() => _zoom = zoom),
        child: CustomScrollView(
          slivers: [
            if (_selecting)
              SliverAppBar(
                pinned: true,
                leading: IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _exitSelection,
                ),
                title: Text('${_selection.length} selected'),
                actions: [
                  IconButton(
                    tooltip: 'Export selected',
                    icon: const Icon(Icons.download_outlined),
                    onPressed:
                        _selection.isEmpty ? null : () => _exportSelected(state),
                  ),
                  IconButton(
                    tooltip: 'Delete selected',
                    icon: const Icon(Icons.delete_outline),
                    onPressed:
                        _selection.isEmpty ? null : () => _deleteSelected(state),
                  ),
                ],
              )
            else
              // The large title, like the Library's: a gallery is a place to
              // browse, so it opens unhurried rather than under a dense band.
              SliverAppBar.large(
                title: Text(_titleFor(owner)),
                actions: [
                  // The pinch is the real control for this; the menu is how it is
                  // discovered, and it names what each rung groups by so the
                  // ladder is not a secret.
                  PopupMenuButton<GalleryZoom>(
                    tooltip: 'Size',
                    icon: const Icon(Icons.grid_view_outlined),
                    initialValue: _zoom,
                    onSelected: (zoom) => setState(() => _zoom = zoom),
                    itemBuilder: (context) => [
                      for (final rung in GalleryZoom.values)
                        PopupMenuItem<GalleryZoom>(
                          value: rung,
                          child: Text(_zoomLabel(rung)),
                        ),
                    ],
                  ),
                  IconButton(
                    tooltip: 'Add pictures',
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    onPressed: _upload,
                  ),
                  IconButton(
                    tooltip: 'Select multiple',
                    icon: const Icon(Icons.checklist_outlined),
                    onPressed: pool.isEmpty
                        ? null
                        : () => setState(() => _selecting = true),
                  ),
                ],
              ),
            SliverToBoxAdapter(child: _searchAndControls(state, tags)),
            if (pool.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyGallery(
                  owner: owner,
                  everything: !_isAlbum,
                  onAdd: _upload,
                ),
              )
            else if (visible.isEmpty)
              const SliverFillRemaining(
                  hasScrollBody: false, child: _NoMatches())
            else ...[
              for (final section in sections) ...[
                if (section.hasLabel) _sectionHeader(section.label),
                _grid(state, section.images, visible),
              ],
              SliverToBoxAdapter(child: SizedBox(height: 96 + bottom)),
            ],
          ],
        ),
      ),
    );
  }

  String _titleFor(Character? owner) {
    if (!_isAlbum) return 'Gallery';
    if (owner == null) return 'Gallery';
    return 'Gallery of ${owner.displayName}';
  }

  Widget _searchAndControls(AppState state, List<String> tags) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        child: Column(
          children: [
            SearchBar(
              controller: _search,
              hintText: _isAlbum ? 'Search photos' : 'Search the gallery',
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: 14),
              ),
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
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _ControlChip(
                  icon: Icons.sort,
                  label: _sort.shortLabel,
                  onTap: _pickSort,
                ),
                const SizedBox(width: 8),
                _ControlChip(
                  icon: Icons.label_outline,
                  label: _tagFilter.isEmpty
                      ? 'Tags'
                      : '${_tagFilter.length} tag'
                          '${_tagFilter.length == 1 ? '' : 's'}',
                  selected: _tagFilter.isNotEmpty,
                  onTap: () => _showTagFilter(tags),
                ),
                if (!_isAlbum) ...[
                  const SizedBox(width: 8),
                  // Flexible, not fixed: a long character name shortens rather
                  // than pushing the row off the edge of a phone screen.
                  Flexible(
                    child: _ControlChip(
                      icon: Icons.person_outline,
                      label: _ownerLabel(state),
                      selected: _filterUnowned || _ownerFilter != null,
                      onTap: () => _pickOwner(state),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      );

  String _ownerLabel(AppState state) {
    if (_filterUnowned) return 'Unassigned';
    final owner = state.characterById(_ownerFilter);
    return owner?.displayName ?? 'Everyone';
  }

  /// How a rung of the ladder reads in the size menu: what you see, and what the
  /// date bands cover there.
  String _zoomLabel(GalleryZoom zoom) {
    final grouping = switch (zoom.grouping) {
      DateGrouping.day => 'by day',
      DateGrouping.week => 'by week',
      DateGrouping.month => 'by month',
    };
    return zoom.columns == 1
        ? 'One at a time, $grouping'
        : '${zoom.columns} across, $grouping';
  }

  Widget _sectionHeader(String label) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            label,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
      );

  /// One date band's pictures. [all] is the whole visible list so the viewer can
  /// page across band boundaries rather than being trapped in one day.
  Widget _grid(
    AppState state,
    List<GalleryImage> images,
    List<GalleryImage> all,
  ) {
    // At one across a picture gets room to breathe; packed four or six up, the
    // tiles are square so the grid reads as a wall of photographs.
    final aspect = _zoom.columns == 1 ? 1.2 : 1.0;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      sliver: SliverGrid.builder(
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: _zoom.columns,
          mainAxisSpacing: 6,
          crossAxisSpacing: 6,
          childAspectRatio: aspect,
        ),
        itemCount: images.length,
        itemBuilder: (context, i) {
          final image = images[i];
          return _ImageTile(
            image: image,
            columns: _zoom.columns,
            ownerName: _isAlbum
                ? null
                : state.characterById(image.characterId)?.displayName,
            selecting: _selecting,
            selected: _selection.contains(image.id),
            onTap: () => _selecting
                ? _toggleSelect(image.id)
                : _open(all, all.indexOf(image)),
            onLongPress: () => setState(() {
              _selecting = true;
              _selection.add(image.id);
            }),
          );
        },
      ),
    );
  }
}
/// One picture in the grid.
///
/// The tile knows how many columns it is in so it can ask for a bitmap the size
/// it will actually be drawn at — the whole reason a three-hundred-photo gallery
/// scrolls at all. Titles are only worth showing when there is room for them.
class _ImageTile extends StatelessWidget {
  const _ImageTile({
    required this.image,
    required this.columns,
    required this.ownerName,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final GalleryImage image;
  final int columns;
  final String? ownerName;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final media = MediaQuery.of(context);
    // The tile's own edge, not the source picture's: a 4000 px photo drawn 90 px
    // wide is decoded at 90 px.
    final tileWidth = media.size.width / columns;
    final provider = avatarImage(
      image.image,
      displaySize: tileWidth,
      devicePixelRatio: media.devicePixelRatio,
    );
    final roomForText = columns <= 2;

    return Material(
      color: scheme.surfaceContainerHighest,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(columns >= 4 ? 8 : 14),
        side: selected
            ? BorderSide(color: scheme.primary, width: 3)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (provider == null)
              Center(
                child: Icon(Icons.broken_image_outlined,
                    color: scheme.outline, size: 20),
              )
            else
              Image(
                image: provider,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(Icons.broken_image_outlined,
                      color: scheme.outline, size: 20),
                ),
              ),
            if (image.starred)
              const Positioned(
                top: 4,
                left: 4,
                child: _TileGlyph(icon: Icons.star, tint: Colors.amber),
              ),
            if (selecting)
              Positioned(
                top: 4,
                right: 4,
                child: _TileGlyph(
                  icon: selected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                  tint: selected ? scheme.primary : Colors.white,
                ),
              ),
            if (roomForText && (image.title.trim().isNotEmpty || ownerName != null))
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  // A gradient so a caption over a bright photo is still legible
                  // without a slab hiding the bottom of the picture.
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.62),
                      ],
                    ),
                  ),
                  padding: const EdgeInsets.fromLTRB(8, 14, 8, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (image.title.trim().isNotEmpty)
                        Text(
                          image.title.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      if (ownerName != null)
                        Text(
                          ownerName!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 10,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A small icon over a picture, backed just enough to stay visible on white.
class _TileGlyph extends StatelessWidget {
  const _TileGlyph({required this.icon, required this.tint});

  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.38),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 16, color: tint),
      );
}

/// The pill buttons under the search bar, matching the character roster's.
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

/// Which character's pictures to show, in the whole-app gallery.
class _OwnerChoice {
  const _OwnerChoice(this.characterId) : unowned = false;
  const _OwnerChoice.unowned()
      : characterId = null,
        unowned = true;

  final String? characterId;
  final bool unowned;
}

class _OwnerFilterSheet extends StatelessWidget {
  const _OwnerFilterSheet({
    required this.characters,
    required this.countOf,
    required this.selected,
  });

  final List<Character> characters;
  final int Function(String? characterId) countOf;
  final _OwnerChoice selected;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final unassigned = countOf(null);
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: media.size.height * 0.75),
      child: ListView(
        shrinkWrap: true,
        padding: EdgeInsets.only(bottom: media.padding.bottom + 8),
        children: [
          ListTile(
            leading: const Icon(Icons.people_alt_outlined),
            title: const Text('Everyone'),
            trailing: (!selected.unowned && selected.characterId == null)
                ? const Icon(Icons.check)
                : null,
            onTap: () => Navigator.of(context).pop(const _OwnerChoice(null)),
          ),
          if (unassigned > 0)
            ListTile(
              leading: const Icon(Icons.help_outline),
              title: const Text('Unassigned'),
              subtitle: Text('$unassigned picture${unassigned == 1 ? '' : 's'} '
                  'that belong to nobody'),
              trailing: selected.unowned ? const Icon(Icons.check) : null,
              onTap: () =>
                  Navigator.of(context).pop(const _OwnerChoice.unowned()),
            ),
          const Divider(height: 1),
          for (final character in characters)
            // A character with no pictures is not worth a row in a filter.
            if (countOf(character.id) > 0)
              ListTile(
                leading: _SheetAvatar(character: character),
                title: Text(character.displayName),
                subtitle: Text('${countOf(character.id)} picture'
                    '${countOf(character.id) == 1 ? '' : 's'}'),
                trailing: selected.characterId == character.id
                    ? const Icon(Icons.check)
                    : null,
                onTap: () =>
                    Navigator.of(context).pop(_OwnerChoice(character.id)),
              ),
        ],
      ),
    );
  }
}

class _SheetAvatar extends StatelessWidget {
  const _SheetAvatar({required this.character});

  final Character character;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final provider = avatarImage(character.avatar, displaySize: 40);
    return CircleAvatar(
      radius: 20,
      backgroundColor: scheme.secondaryContainer,
      foregroundImage: provider,
      child: provider == null
          ? Text(
              character.displayName.characters.firstOrNull?.toUpperCase() ?? '?',
              style: TextStyle(color: scheme.onSecondaryContainer),
            )
          : null,
    );
  }
}

/// Nothing here yet. Says whose gallery is empty, and what to do about it.
class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({
    required this.owner,
    required this.everything,
    required this.onAdd,
  });

  final Character? owner;
  final bool everything;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 0, 32, 64),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.photo_library_outlined, size: 56, color: scheme.outline),
            const SizedBox(height: 16),
            Text(
              everything
                  ? 'No pictures yet'
                  : '${owner?.displayName ?? 'This character'} has no photos yet',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              everything
                  ? 'Add pictures here, or from a character\'s own gallery. '
                      'They can become avatars, chat backgrounds, or float over '
                      'a conversation.'
                  : 'Add a few, and they can become avatars to swipe between or '
                      'float over the chat.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('Add pictures'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A search or filter that matched nothing.
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
              'No pictures match.',
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

