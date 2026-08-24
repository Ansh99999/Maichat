import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/gallery_image.dart';
import '../../state/app_state.dart';
import '../../services/jank_logger.dart';
import '../../widgets/avatar_image.dart';
import '../../widgets/photo_surface.dart';
import 'gallery_actions.dart';

/// What a viewer offers beyond looking, chosen by where it was opened from.
enum ViewerExtra {
  /// Nothing extra: browsing an album.
  none,

  /// Opened from inside a chat — the picture can be thrown onto it.
  sendToChat,
}

/// Opens the picture at [index] of [images] full screen.
///
/// [openedAt] is how wide the tile that was tapped is, in logical pixels. The
/// viewer draws *that* bitmap first — it is already decoded, so it paints on the
/// first frame — and lets the sharp one arrive over the top. Without it the
/// full-screen picture starts decoding from scratch and the screen is black until
/// it lands: the "black blink".
///
/// Pops with the id of the picture that was on screen when it closed, so a caller
/// can scroll to wherever the user ended up.
Future<String?> openImageViewer(
  BuildContext context, {
  required List<GalleryImage> images,
  required int index,
  ViewerExtra extra = ViewerExtra.none,
  String? conversationId,
  double? openedAt,
}) =>
    Navigator.of(context).push<String>(
      // See-through, and the black comes from the screen's own backdrop: a
      // picture flicked away has to leave the gallery visible behind it as it
      // goes, which an opaque route cannot do.
      photoRoute<String>(
        (_) => ImageViewerScreen(
          imageIds: images.map((i) => i.id).toList(),
          initialIndex: index,
          extra: extra,
          conversationId: conversationId,
          openedAt: openedAt,
        ),
      ),
    );

/// A picture, full screen, with a strip of things to do to it.
///
/// Holds **ids**, not records: a title edited or a star flipped here has to be
/// visible immediately, and the live record is read from [AppState] on every
/// build. A picture deleted from under the viewer simply drops out of the list.
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    super.key,
    required this.imageIds,
    required this.initialIndex,
    this.extra = ViewerExtra.none,
    this.conversationId,
    this.openedAt,
  });

  final List<String> imageIds;
  final int initialIndex;
  final ViewerExtra extra;
  final String? conversationId;

  /// The width of the tile this was opened from, for the already-decoded bitmap
  /// to draw under the sharp one. See [openImageViewer].
  final double? openedAt;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);

  /// Turns the pages, because the `PageView` itself is switched off: every touch
  /// belongs to the picture's own surface, which reports sideways drags here. See
  /// [PhotoSurface] for why sharing the touch with a scrollable cannot work.
  late final PhotoPager _pager =
      PhotoPager(controller: _pages, pageCount: _ids.length);

  /// The ids still being shown. Local so a delete can take one out without the
  /// page view losing its place or the route closing under the user.
  late final List<String> _ids = List<String>.from(widget.imageIds);

  late int _index = widget.initialIndex.clamp(0, _ids.length - 1);

  /// Whether the chrome is showing. A tap on the picture hides it, because the
  /// point of opening a photo is the photo.
  bool _chrome = true;

  /// How near the picture is to being let go of, 0 → 1. Drives the backdrop and
  /// the chrome only; a notifier rather than state so a drag does not rebuild the
  /// picture, the page view or the action strip on every frame.
  final ValueNotifier<double> _leaving = ValueNotifier<double>(0);

  /// This screen's own messenger.
  ///
  /// The route is see-through, so the gallery underneath stays on screen and its
  /// `Scaffold` is still registered with the app's messenger — a snack bar shown
  /// through that one is drawn twice, once per scaffold, stacked exactly on top of
  /// itself. Its own messenger keeps a confirmation to the screen that raised it.
  final GlobalKey<ScaffoldMessengerState> _messenger =
      GlobalKey<ScaffoldMessengerState>();

  @override
  void dispose() {
    _pages.dispose();
    _leaving.dispose();
    super.dispose();
  }

  GalleryImage? _imageAt(AppState state, int index) {
    if (index < 0 || index >= _ids.length) return null;
    return state.galleryImageById(_ids[index]);
  }

  Future<void> _delete(AppState state, GalleryImage image) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this picture?'),
        content: Text(
          '"${image.displayTitle}" will be removed from the gallery, and from '
          'any character wearing it.',
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
    await state.deleteGalleryImage(image.id);
    if (!mounted) return;
    setState(() {
      _ids.remove(image.id);
      if (_ids.isEmpty) return;
      _index = _index.clamp(0, _ids.length - 1);
      _pager.pageCount = _ids.length;
    });
    if (_ids.isEmpty) {
      Navigator.of(context).pop(null);
      return;
    }
    // The page view is keyed by index, so it needs telling where to land.
    _pages.jumpToPage(_index);
  }

  /// Adds the picture to its owner's avatars, or takes it back out.
  ///
  /// Says what happened, every time. The control flipping label was the only
  /// feedback before, which read as nothing happening at all — and when the
  /// character had no picture yet, the pool ended up holding exactly one, so
  /// there was nothing to swipe between either. Both of those are now stated
  /// outright.
  Future<void> _toggleAvatar(AppState state, GalleryImage image) async {
    final characterId = image.characterId;
    if (characterId == null) {
      _say('This picture belongs to nobody yet. Use Edit to say who, then it '
          'can be their avatar.');
      return;
    }
    final character = state.characterById(characterId);
    if (character == null) {
      _say('That character has been deleted, so this cannot be their avatar.');
      return;
    }

    if (state.isAvatarOf(character, image.image)) {
      await state.removeAvatarFromPool(characterId, image.image);
      _say('Removed from ${character.displayName}\'s avatars.');
      return;
    }

    await state.addAvatarToPool(characterId, image.image);
    if (!mounted) return;
    final pool = state.avatarPoolFor(state.characterById(characterId)!);
    _say(pool.length > 1
        ? 'Added to ${character.displayName}\'s avatars — tap their picture in a '
            'chat to swipe between ${pool.length}.'
        : '${character.displayName} now wears this. Add another to swipe '
            'between them in a chat.');
  }

  Future<void> _sendToChat(AppState state, GalleryImage image) async {
    final conversationId = widget.conversationId;
    if (conversationId == null) return;
    JankLogger.instance.breadcrumb('float added from gallery viewer');
    await state.floatImage(conversationId, image.id);
    if (!mounted) return;
    // Straight back to the chat, where the picture now is — staying here would
    // hide the thing the action just did.
    Navigator.of(context).pop(image.id);
  }

  void _say(String message) {
    if (!mounted) return;
    final messenger = _messenger.currentState;
    if (messenger == null) return;
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        // Clear of the action strip, so the confirmation does not cover the
        // control that produced it.
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 96),
        duration: const Duration(seconds: 3),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final current = _imageAt(state, _index);

    return ScaffoldMessenger(
      key: _messenger,
      child: Scaffold(
        // The black is painted inside, by [PhotoBackdrop], so it can fade as the
        // picture is dragged away and let the gallery show through.
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: _chrome
            ? PreferredSize(
                preferredSize: const Size.fromHeight(kToolbarHeight),
                child: PhotoFade(
                  leaving: _leaving,
                  child: _ViewerBar(
                    title: current?.displayTitle ?? 'Picture',
                    counter: _ids.length > 1
                        ? '${_index + 1} / ${_ids.length}'
                        : null,
                  ),
                ),
              )
            : null,
        body: Stack(
          children: [
            Positioned.fill(child: PhotoBackdrop(leaving: _leaving)),
            PageView.builder(
              controller: _pages,
              // No recognisers at all: the picture's own surface owns every touch
              // on it and turns the pages through [_pager]. Sharing the touch with
              // a scrollable is what made pinching impossible — see [PhotoSurface].
              physics: const NeverScrollableScrollPhysics(),
              itemCount: _ids.length,
              onPageChanged: (i) => setState(() => _index = i),
              itemBuilder: (context, i) {
                final image = _imageAt(state, i);
                if (image == null) {
                  return const Center(
                    child: Icon(Icons.broken_image_outlined,
                        color: Colors.white38, size: 48),
                  );
                }
                return _ZoomablePicture(
                  // Per picture, so zooming one and paging away leaves the next
                  // at rest rather than inheriting a transform.
                  key: ValueKey('zoom-${image.id}'),
                  image: image,
                  leaving: _leaving,
                  openedAt: widget.openedAt,
                  // Only the page on screen flies, so the tag is unique: it is
                  // the one that grew out of its tile on the way in, and the one
                  // that shrinks back into a tile on the way out — even after
                  // swiping to a different picture.
                  flies: i == _index,
                  onTap: () => setState(() => _chrome = !_chrome),
                  onDismiss: () => Navigator.of(context).maybePop(image.id),
                  onPageDrag: _ids.length > 1 ? _pager.drag : null,
                  onPageSettle: _pager.settle,
                );
              },
            ),
            if (_chrome && current != null)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                // Fades with the picture as it is dragged away: controls left
                // hanging over a photo that is leaving look like a stuck screen.
                child: PhotoFade(
                  leaving: _leaving,
                  child: _ActionBar(
                    image: current,
                    isAvatar: _isAvatar(state, current),
                    canBeAvatar: current.characterId != null,
                    extra: widget.extra,
                    onExport: () => exportGalleryImage(context, current),
                    onEdit: () async {
                      await showGalleryEditSheet(context, current);
                    },
                    onStar: () => state.toggleGalleryStar(current.id),
                    onAvatar: () => _toggleAvatar(state, current),
                    onSend: () => _sendToChat(state, current),
                    onDelete: () => _delete(state, current),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  bool _isAvatar(AppState state, GalleryImage image) {
    final character = state.characterById(image.characterId);
    return character != null && state.isAvatarOf(character, image.image);
  }
}

/// The black a photo is judged against — which thins out as the picture is
/// dragged away, so the gallery it came from shows through behind it.

/// The bar over a picture: its title, and where in the run it is.
class _ViewerBar extends StatelessWidget {
  const _ViewerBar({required this.title, this.counter});

  final String title;
  final String? counter;

  @override
  Widget build(BuildContext context) => AppBar(
        backgroundColor: Colors.black.withValues(alpha: 0.35),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          if (counter != null)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Center(
                child: Text(
                  counter!,
                  style: const TextStyle(color: Colors.white70),
                ),
              ),
            ),
        ],
      );
}

/// One page: the picture, pinch-zoomable and flick-dismissable, on black.
class _ZoomablePicture extends StatelessWidget {
  const _ZoomablePicture({
    super.key,
    required this.image,
    required this.leaving,
    required this.flies,
    required this.onTap,
    required this.onDismiss,
    this.openedAt,
    this.onPageDrag,
    this.onPageSettle,
  });

  final GalleryImage image;

  /// Shared with the screen, so the backdrop and chrome fade with this picture.
  final ValueNotifier<double> leaving;

  /// Whether this page is the one that flew in from the grid. Only the picture
  /// that was tapped may carry the hero tag — two of them under one tag is an
  /// error, and the pages either side are built before a swipe reaches them.
  final bool flies;

  final VoidCallback onTap;
  final VoidCallback onDismiss;

  /// The width of the tile this was opened from, for the bitmap that is already
  /// decoded. See [openImageViewer].
  final double? openedAt;

  final ValueChanged<double>? onPageDrag;
  final ValueChanged<double>? onPageSettle;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Decoded for the screen, through the shared cache — a full-resolution photo
    // held per page is what makes a viewer stutter and then run out of memory.
    final provider = avatarImage(
      image.image,
      displaySize: media.size.longestSide,
      devicePixelRatio: media.devicePixelRatio,
    );
    // The grid's bitmap: a different, smaller decode of the same file, and one
    // that is already in memory because the tile is on screen.
    final decoded = openedAt == null
        ? null
        : avatarImage(
            image.image,
            displaySize: openedAt,
            devicePixelRatio: media.devicePixelRatio,
          );

    return PhotoSurface(
      onTap: onTap,
      onDismiss: onDismiss,
      dismissProgress: leaving,
      onPageDrag: onPageDrag,
      onPageSettle: onPageSettle,
      child: provider == null
          ? const Center(
              child: Icon(Icons.broken_image_outlined,
                  color: Colors.white38, size: 48),
            )
          : PhotoHero(
              tag: flies ? photoHeroTag(image.id) : null,
              // Fills the surface rather than shrink-wrapping the bitmap: a
              // `Hero` measures where it is flying *to*, and an `Image` that has
              // not decoded yet has no size at all under loose constraints — so
              // wrapping the bare image made the picture fly into a point at the
              // middle of the screen and vanish. The box is known before the
              // first byte is read; `contain` still letterboxes inside it.
              child: SizedBox.expand(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Underneath: the tile's own decode, which needs no work to
                    // paint. Without it the screen is black until the full-size
                    // bitmap has decoded — the blink. Soft for a frame or two
                    // beats absent for a frame or two.
                    if (decoded != null)
                      Image(
                        image: decoded,
                        fit: BoxFit.contain,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    Image(
                      image: provider,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                      // Only the sharp one fades, and only over the blurry one
                      // already in place — never over black.
                      frameBuilder: (_, child, frame, wasSynchronous) =>
                          wasSynchronous || decoded == null
                              ? child
                              : AnimatedOpacity(
                                  opacity: frame == null ? 0 : 1,
                                  duration: const Duration(milliseconds: 120),
                                  child: child,
                                ),
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined,
                            color: Colors.white38, size: 48),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}
/// The strip along the bottom: everything that can be done to the picture on
/// screen, where a thumb can reach it.
class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.image,
    required this.isAvatar,
    required this.canBeAvatar,
    required this.extra,
    required this.onExport,
    required this.onEdit,
    required this.onStar,
    required this.onAvatar,
    required this.onSend,
    required this.onDelete,
  });

  final GalleryImage image;
  final bool isAvatar;

  /// Whether this picture has an owner to be an avatar *for*.
  final bool canBeAvatar;

  final ViewerExtra extra;
  final VoidCallback onExport;
  final VoidCallback onEdit;
  final VoidCallback onStar;
  final VoidCallback onAvatar;
  final VoidCallback onSend;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Container(
      // A gradient, not a bar: the picture keeps going behind the controls
      // instead of being cut off by a slab.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0.8),
          ],
        ),
      ),
      padding: EdgeInsets.fromLTRB(8, 24, 8, 8 + bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (image.tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in image.tags)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        tag,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          // One row that always fits: an action off the right edge of a phone is
          // an action nobody can reach, and a scrolling strip hides that it is
          // there at all. Each slot takes an equal share and its label
          // ellipsizes.
          Row(
            children: [
              if (extra == ViewerExtra.sendToChat)
                _ViewerAction(
                  icon: Icons.send_outlined,
                  label: 'Send',
                  onTap: onSend,
                ),
              _ViewerAction(
                icon: Icons.download_outlined,
                label: 'Export',
                onTap: onExport,
              ),
              _ViewerAction(
                icon: Icons.edit_outlined,
                label: 'Edit',
                onTap: onEdit,
              ),
              _ViewerAction(
                icon: image.starred ? Icons.star : Icons.star_border,
                label: image.starred ? 'Starred' : 'Star',
                tint: image.starred ? Colors.amber : null,
                onTap: onStar,
              ),
              // Reads as a state, not a command: "Avatar" with a filled glyph
              // means it already is one. Still tappable when the picture has no
              // owner — it then says what to do about that, rather than the
              // control quietly doing nothing.
              _ViewerAction(
                icon: isAvatar ? Icons.account_circle : Icons.face_outlined,
                label: isAvatar ? 'Avatar' : 'Not avatar',
                tint: isAvatar ? Colors.lightBlueAccent : null,
                dim: !canBeAvatar,
                onTap: onAvatar,
              ),
              _ViewerAction(
                icon: Icons.delete_outline,
                label: 'Delete',
                onTap: onDelete,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ViewerAction extends StatelessWidget {
  const _ViewerAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.tint,
    this.dim = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? tint;

  /// Drawn faded, for an action that will explain itself rather than act.
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final colour = tint ??
        (dim ? Colors.white.withValues(alpha: 0.45) : Colors.white);
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: colour, size: 22),
              const SizedBox(height: 4),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: colour, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
