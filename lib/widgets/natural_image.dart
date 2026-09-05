import 'package:flutter/material.dart';

import 'avatar_image.dart';

/// Identifies the box a [NaturalImage] lays out at the picture's proportions.
/// Tests measure this rather than the [Image] inside it, so the assertion is
/// about the frame the page gives the picture and not about whether a decode
/// happened to complete.
const Key naturalImageFrameKey = ValueKey('natural-image-frame');

/// Draws inside a [NaturalFrame]: [size] is the frame's own box, and [image] is
/// the frame's picture already resolved at the width it is drawn at — null when
/// there is nothing drawable, which is when a fallback belongs.
typedef NaturalFrameBuilder = Widget Function(
  BuildContext context,
  Size size,
  ImageProvider? image,
);

/// A box laid out at **[imageRef]'s own** proportions across the full width it is
/// given: a 1:1 avatar is a square, a 16:9 one is a band, a 3:4 one is a portrait.
/// No crop, no letterbox, no circle.
///
/// The height cannot be known until the picture has been decoded, and asking for
/// it costs a frame. Two things keep that from being visible:
///
/// * the ratio is remembered globally ([avatarRatio]), so only the very first
///   time a picture is seen anywhere in the app does anything have to settle;
/// * until it is known the frame holds [placeholderRatio] rather than collapsing
///   to nothing, so the page below does not jump by a screenful.
///
/// [maxHeightFactor] bounds a very tall picture (a 9:16 phone screenshot as a
/// character avatar) to a fraction of the viewport *height*, so the name and the
/// notes under it are still reachable without a long scroll. The picture keeps its
/// ratio when capped — it just gets narrower and centres. A portrait avatar at
/// ordinary proportions (2:3, 3:4) still runs the full width; only the extremes
/// are trimmed.
///
/// What goes *in* the frame is the caller's business, which is what separates this
/// from [NaturalImage]: the character sheet puts a whole swipeable run of pictures
/// in a frame sized by the one the card is wearing, so the frame does not resize
/// under the finger as the run is swiped.
class NaturalFrame extends StatefulWidget {
  const NaturalFrame({
    super.key,
    required this.imageRef,
    required this.builder,
    this.placeholderRatio = 1,
    this.maxHeightFactor = 0.72,
  });

  /// A picture reference: `local:<file>`, an `http(s)` URL, or legacy base64 —
  /// whatever [avatarImage] accepts.
  final String imageRef;

  final NaturalFrameBuilder builder;

  /// The width/height to reserve until the real ratio is known.
  final double placeholderRatio;

  /// Cap on the drawn height, as a fraction of the viewport height.
  final double maxHeightFactor;

  @override
  State<NaturalFrame> createState() => _NaturalFrameState();
}

class _NaturalFrameState extends State<NaturalFrame> {
  ImageProvider? _provider;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  double? _ratio;

  /// The width the picture is drawn at, so the decode is capped near it rather
  /// than at source resolution. Read once per layout pass.
  double _width = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(NaturalFrame old) {
    super.didUpdateWidget(old);
    if (old.imageRef != widget.imageRef) {
      _ratio = null;
      _sync();
    }
  }

  void _sync() {
    _ratio ??= avatarRatio(widget.imageRef);
    final provider = avatarImage(
      widget.imageRef,
      // A header picture is the largest thing on the page, so it is asked for at
      // the full width it will occupy — but still through the shared, bucketed,
      // deduplicated cache, so it is decoded once for the whole app.
      displaySize: _width > 0 ? _width : MediaQuery.sizeOf(context).width,
      devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
    );
    if (provider == null) {
      _detach();
      if (_provider != null) _provider = null;
      return;
    }
    if (provider == _provider && _stream != null) return;
    _detach();
    _provider = provider;
    // Already known: no listener needed at all, so nothing settles.
    if (_ratio != null) return;
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener((info, _) {
      final w = info.image.width.toDouble();
      final h = info.image.height.toDouble();
      if (w <= 0 || h <= 0) return;
      final ratio = w / h;
      noteAvatarRatio(widget.imageRef, ratio);
      if (mounted && ratio != _ratio) setState(() => _ratio = ratio);
    }, onError: (_, _) {
      if (mounted && _provider != null) setState(() => _provider = null);
    });
    _stream = stream;
    _listener = listener;
    stream.addListener(listener);
  }

  void _detach() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    _stream = null;
    _listener = null;
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    if (provider == null) {
      return AspectRatio(
        aspectRatio: widget.placeholderRatio,
        child: KeyedSubtree(
          key: naturalImageFrameKey,
          child: LayoutBuilder(
            builder: (context, constraints) => widget.builder(
              context,
              Size(constraints.maxWidth, constraints.maxHeight),
              null,
            ),
          ),
        ),
      );
    }
    final ratio = _ratio ?? widget.placeholderRatio;
    final maxHeight =
        MediaQuery.sizeOf(context).height * widget.maxHeightFactor;

    return LayoutBuilder(
      builder: (context, constraints) {
        var width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        if (_width != width) {
          _width = width;
        }
        var height = width / ratio;
        if (height > maxHeight) {
          height = maxHeight;
          width = height * ratio;
        }
        return SizedBox(
          height: height,
          width: constraints.maxWidth,
          child: Center(
            // The frame, not the picture, is what the page's layout is: a
            // picture that fails to load is replaced inside this box and the
            // page does not move. Keyed so a test can measure the frame without
            // depending on what ended up drawn in it.
            child: SizedBox(
              key: naturalImageFrameKey,
              width: width,
              height: height,
              child: widget.builder(context, Size(width, height), provider),
            ),
          ),
        );
      },
    );
  }
}

/// One picture drawn at its own proportions — a [NaturalFrame] with the picture
/// in it, which is what almost every caller wants.
class NaturalImage extends StatelessWidget {
  const NaturalImage({
    super.key,
    required this.imageRef,
    this.placeholderRatio = 1,
    this.maxHeightFactor = 0.72,
    this.fallback,
    this.overlay,
  });

  /// A picture reference: `local:<file>`, an `http(s)` URL, or legacy base64 —
  /// whatever [avatarImage] accepts.
  final String imageRef;

  /// The width/height to reserve until the real ratio is known.
  final double placeholderRatio;

  /// Cap on the drawn height, as a fraction of the viewport height.
  final double maxHeightFactor;

  /// Drawn instead when there is no usable picture.
  final Widget? fallback;

  /// Drawn over the picture, filling exactly the picture's own frame — so a
  /// caption anchored to the bottom-right lands on the artwork, not in the empty
  /// margin beside a capped one.
  final Widget? overlay;

  @override
  Widget build(BuildContext context) => NaturalFrame(
        imageRef: imageRef,
        placeholderRatio: placeholderRatio,
        maxHeightFactor: maxHeightFactor,
        builder: (context, size, image) => Stack(
          fit: StackFit.expand,
          children: [
            if (image == null)
              fallback ?? const SizedBox.shrink()
            else
              Image(
                image: image,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) =>
                    fallback ?? const SizedBox.shrink(),
              ),
            if (overlay != null) ?overlay,
          ],
        ),
      );
}
