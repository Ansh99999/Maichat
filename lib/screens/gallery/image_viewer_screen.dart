import 'package:flutter/material.dart';
import 'package:provider/provider.dart' hide Provider;

import '../../models/gallery_image.dart';
import '../../state/app_state.dart';
import '../../services/jank_logger.dart';
import '../../widgets/avatar_image.dart';
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
/// Pops with the id of the picture that was on screen when it closed, so a caller
/// can scroll to wherever the user ended up.
Future<String?> openImageViewer(
  BuildContext context, {
  required List<GalleryImage> images,
  required int index,
  ViewerExtra extra = ViewerExtra.none,
  String? conversationId,
}) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        // Opaque black rather than a translucent scrim: a photo is judged
        // against nothing, not against a dimmed list.
        builder: (_) => ImageViewerScreen(
          imageIds: images.map((i) => i.id).toList(),
          initialIndex: index,
          extra: extra,
          conversationId: conversationId,
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
  });

  final List<String> imageIds;
  final int initialIndex;
  final ViewerExtra extra;
  final String? conversationId;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);

  /// The ids still being shown. Local so a delete can take one out without the
  /// page view losing its place or the route closing under the user.
  late final List<String> _ids = List<String>.from(widget.imageIds);

  late int _index = widget.initialIndex.clamp(0, _ids.length - 1);

  /// Whether the chrome is showing. A tap on the picture hides it, because the
  /// point of opening a photo is the photo.
  bool _chrome = true;

  /// Whether the picture on screen is zoomed in.
  ///
  /// This is what stops the pinch feeling "funky": at rest, paging owns
  /// horizontal drags and the picture ignores them; once zoomed, the picture owns
  /// them so it can be panned around, and paging is switched off. Without that
  /// split the two fight over every drag, and a pinch that starts with the
  /// slightest sideways movement gets stolen by the page view.
  bool _zoomed = false;

  @override
  void dispose() {
    _pages.dispose();
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
    final messenger = ScaffoldMessenger.of(context)..clearSnackBars();
    messenger.showSnackBar(SnackBar(
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

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: _chrome
          ? AppBar(
              backgroundColor: Colors.black.withValues(alpha: 0.35),
              foregroundColor: Colors.white,
              elevation: 0,
              title: Text(
                current?.displayTitle ?? 'Picture',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              actions: [
                if (_ids.length > 1)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Center(
                      child: Text(
                        '${_index + 1} / ${_ids.length}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ),
                  ),
              ],
            )
          : null,
      body: Stack(
        children: [
          PageView.builder(
            controller: _pages,
            // Paging is off while a picture is zoomed in, so dragging moves the
            // picture instead of half-turning the page.
            physics: _zoomed
                ? const NeverScrollableScrollPhysics()
                : const PageScrollPhysics(),
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
                // Per picture, so zooming one and paging away leaves the next at
                // rest rather than inheriting a transform.
                key: ValueKey('zoom-${image.id}'),
                image: image,
                onTap: () => setState(() => _chrome = !_chrome),
                onZoomChanged: (zoomed) {
                  if (_zoomed != zoomed) setState(() => _zoomed = zoomed);
                },
              );
            },
          ),
          if (_chrome && current != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
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
        ],
      ),
    );
  }

  bool _isAvatar(AppState state, GalleryImage image) {
    final character = state.characterById(image.characterId);
    return character != null && state.isAvatarOf(character, image.image);
  }
}

/// One page: the picture, pinch-zoomable, centred on black.
class _ZoomablePicture extends StatefulWidget {
  const _ZoomablePicture({
    super.key,
    required this.image,
    required this.onTap,
    required this.onZoomChanged,
  });

  final GalleryImage image;
  final VoidCallback onTap;

  /// Reports whether this picture is zoomed in, so the pager can get out of the
  /// way.
  final ValueChanged<bool> onZoomChanged;

  @override
  State<_ZoomablePicture> createState() => _ZoomablePictureState();
}

class _ZoomablePictureState extends State<_ZoomablePicture>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();

  /// Drives the double-tap zoom, so it eases in and out rather than snapping.
  AnimationController? _animation;

  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
  }

  @override
  void dispose() {
    _transform.removeListener(_onTransform);
    _animation?.dispose();
    _transform.dispose();
    super.dispose();
  }

  void _onTransform() {
    final zoomed = _transform.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed == _zoomed) return;
    _zoomed = zoomed;
    widget.onZoomChanged(zoomed);
  }

  /// Animates the transform to [target].
  void _animateTo(Matrix4 target) {
    _animation?.dispose();
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    );
    final tween = Matrix4Tween(begin: _transform.value, end: target).animate(
      CurvedAnimation(parent: controller, curve: Curves.easeOutCubic),
    );
    tween.addListener(() => _transform.value = tween.value);
    _animation = controller;
    controller.forward();
  }

  /// A double tap zooms to 2.5× on the spot touched, and back out again — the
  /// gesture every photo viewer has.
  void _doubleTap(TapDownDetails details) {
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      _animateTo(Matrix4.identity());
      return;
    }
    const scale = 2.5;
    final point = details.localPosition;
    _animateTo(Matrix4.identity()
      ..translateByDouble(
        -point.dx * (scale - 1),
        -point.dy * (scale - 1),
        0,
        1,
      )
      ..scaleByDouble(scale, scale, scale, 1));
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    // Decoded for the screen, through the shared cache — a full-resolution photo
    // held per page is what makes a viewer stutter and then run out of memory.
    final provider = avatarImage(
      widget.image.image,
      displaySize: media.size.longestSide,
      devicePixelRatio: media.devicePixelRatio,
    );

    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: _doubleTap,
      // Without this the double tap has nothing to fire on once the first tap
      // has been claimed.
      onDoubleTap: () {},
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 6,
        // Panning only once zoomed in. At rest the page view owns horizontal
        // drags, so a swipe pages cleanly instead of being fought over — that
        // fight is what made pinching feel jumpy.
        panEnabled: _zoomed,
        // Keeps a zoomed picture from being dragged off into empty space, which
        // is the other half of "funky": you could lose the photo entirely.
        boundaryMargin: EdgeInsets.zero,
        clipBehavior: Clip.none,
        child: Center(
          child: provider == null
              ? const Icon(Icons.broken_image_outlined,
                  color: Colors.white38, size: 48)
              : Image(
                  image: provider,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white38,
                      size: 48),
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
