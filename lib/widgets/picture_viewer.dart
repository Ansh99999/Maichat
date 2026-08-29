import 'package:flutter/material.dart';

import 'avatar_image.dart';
import 'photo_surface.dart';

/// Opens one picture full screen — pinchable, and flickable away — for the
/// places that hold a bare picture *reference* rather than a gallery record: a
/// photograph attached to a message, the picture the image studio has just made.
///
/// The gallery has its own viewer ([ImageViewerScreen]) because it can also
/// rename, star, delete and set an avatar; none of that applies to a picture that
/// is part of a transcript, so this stays a viewer and nothing else.
Future<void> showPictureViewer(
  BuildContext context, {
  required List<String> refs,
  int index = 0,
  String title = '',
}) {
  final pictures = refs.where((r) => r.trim().isNotEmpty).toList();
  if (pictures.isEmpty) return Future<void>.value();
  return Navigator.of(context).push(
    // See-through, so a picture flicked away leaves the chat visible behind it.
    photoRoute<void>(
      (_) => PictureViewerScreen(
        refs: pictures,
        initialIndex: index.clamp(0, pictures.length - 1),
        title: title,
      ),
    ),
  );
}

class PictureViewerScreen extends StatefulWidget {
  const PictureViewerScreen({
    super.key,
    required this.refs,
    this.initialIndex = 0,
    this.title = '',
  });

  final List<String> refs;
  final int initialIndex;
  final String title;

  @override
  State<PictureViewerScreen> createState() => _PictureViewerScreenState();
}

class _PictureViewerScreenState extends State<PictureViewerScreen> {
  late final PageController _pages =
      PageController(initialPage: widget.initialIndex);
  late final PhotoPager _pager =
      PhotoPager(controller: _pages, pageCount: widget.refs.length);
  late int _index = widget.initialIndex;

  /// How near the picture is to being flicked away, 0 → 1.
  final ValueNotifier<double> _leaving = ValueNotifier<double>(0);

  @override
  void dispose() {
    _pages.dispose();
    _leaving.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final many = widget.refs.length > 1;
    return Scaffold(
      // Painted by [PhotoBackdrop] instead, so it thins out as the picture goes.
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(kToolbarHeight),
        child: PhotoFade(
          leaving: _leaving,
          child: AppBar(
            backgroundColor: Colors.black.withValues(alpha: 0.35),
            foregroundColor: Colors.white,
            elevation: 0,
            title: Text(widget.title),
            actions: [
              if (many)
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Center(
                    child: Text(
                      '${_index + 1} / ${widget.refs.length}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      body: Stack(
        children: [
          Positioned.fill(child: PhotoBackdrop(leaving: _leaving)),
          PageView.builder(
            controller: _pages,
            // Switched off and driven by hand, so each picture's own surface owns
            // every touch on it — see [PhotoSurface].
            physics: const NeverScrollableScrollPhysics(),
            itemCount: widget.refs.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) => _Page(
              key: ValueKey('picture-page-${widget.refs[i]}'),
              ref: widget.refs[i],
              leaving: _leaving,
              onDismiss: () => Navigator.of(context).maybePop(),
              onPageDrag: many ? _pager.drag : null,
              onPageSettle: many ? _pager.settle : null,
            ),
          ),
        ],
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({
    super.key,
    required this.ref,
    required this.leaving,
    required this.onDismiss,
    this.onPageDrag,
    this.onPageSettle,
  });

  final String ref;
  final ValueNotifier<double> leaving;
  final VoidCallback onDismiss;
  final ValueChanged<double>? onPageDrag;
  final ValueChanged<double>? onPageSettle;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final provider = avatarImage(
      ref,
      displaySize: media.size.longestSide,
      devicePixelRatio: media.devicePixelRatio,
    );
    return PhotoSurface(
      dismissProgress: leaving,
      onDismiss: onDismiss,
      onPageDrag: onPageDrag,
      onPageSettle: onPageSettle,
      child: Center(
        child: provider == null
            ? const Icon(Icons.broken_image_outlined,
                color: Colors.white38, size: 64)
            : Image(
                image: provider,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white38,
                  size: 64,
                ),
              ),
      ),
    );
  }
}
