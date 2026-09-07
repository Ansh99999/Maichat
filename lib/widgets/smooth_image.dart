import 'package:flutter/material.dart';

/// An [Image] that softens a genuine first decode but paints cache hits at once.
///
/// Once a frame has appeared it stays visible through provider changes. That
/// preserves [Image.gaplessPlayback]: swapping an avatar cannot fade the old
/// frame to blank while the replacement is decoding.
class SmoothImage extends StatefulWidget {
  const SmoothImage({
    super.key,
    required this.image,
    this.width,
    this.height,
    this.fit,
    this.gaplessPlayback = true,
    this.errorBuilder,
    this.filterQuality = FilterQuality.medium,
    this.alignment = Alignment.center,
    this.semanticLabel,
  });

  final ImageProvider image;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final bool gaplessPlayback;
  final ImageErrorWidgetBuilder? errorBuilder;
  final FilterQuality filterQuality;
  final AlignmentGeometry alignment;
  final String? semanticLabel;

  @override
  State<SmoothImage> createState() => _SmoothImageState();
}

class _SmoothImageState extends State<SmoothImage> {
  bool _seenFrame = false;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: widget.image,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: widget.gaplessPlayback,
      errorBuilder: widget.errorBuilder,
      filterQuality: widget.filterQuality,
      alignment: widget.alignment,
      semanticLabel: widget.semanticLabel,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded) return child;
        _seenFrame = _seenFrame || frame != null;
        return AnimatedOpacity(
          opacity: _seenFrame ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: child,
        );
      },
    );
  }
}
