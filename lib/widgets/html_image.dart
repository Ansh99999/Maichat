import 'package:flutter/material.dart';
import 'package:flutter_html/flutter_html.dart';

import 'avatar_image.dart';

/// One `<img>` from HTML the app renders — a creator's notes, a chat message —
/// drawn through the shared picture cache and bounded.
///
/// `flutter_html`'s built-in renderer uses `Image.network` at source resolution
/// with `BoxFit.fill`: a 3000px banner then decodes to ~36 MB and is squashed to
/// whatever box the CSS asked for. Here the picture goes through [avatarImage],
/// so it decodes near the width it is drawn at, the same URL anywhere in the app
/// is one cache entry, and it keeps its aspect ratio.
class HtmlInlineImage extends StatelessWidget {
  const HtmlInlineImage({
    super.key,
    required this.src,
    required this.alt,
    required this.declaredWidth,
    required this.color,
    this.maxHeight = 420,
  });

  final String src;
  final String alt;

  /// The `width=` attribute, when the source gave one.
  final double? declaredWidth;

  /// Colour for the alt text a broken picture falls back to.
  final Color color;

  /// Cap on the picture's height, so one tall photograph cannot push everything
  /// around it off the screen.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    if (src.trim().isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final available =
            constraints.maxWidth.isFinite && constraints.maxWidth > 0
                ? constraints.maxWidth
                : MediaQuery.sizeOf(context).width;
        final width = declaredWidth == null
            ? available
            : (declaredWidth! < available ? declaredWidth! : available);
        final provider = avatarImage(
          src,
          displaySize: width,
          devicePixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        );
        if (provider == null) return _altText();
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
          child: Image(
            image: provider,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _altText(),
            // A picture that never arrives must not leave a collapsed line: hold
            // a slim band until it does.
            frameBuilder: (_, child, frame, wasSync) => frame == null && !wasSync
                ? SizedBox(width: width, height: 2)
                : child,
          ),
        );
      },
    );
  }

  Widget _altText() => alt.trim().isEmpty
      ? const SizedBox.shrink()
      : Text(alt, style: TextStyle(color: color.withValues(alpha: 0.7)));
}

/// The `<img>` handler to install on an [Html] widget, so every picture in the
/// app's rendered HTML goes through [HtmlInlineImage] rather than the built-in
/// full-resolution `Image.network`.
ImageExtension inlineImageExtension({
  required Color color,
  double maxHeight = 420,
}) =>
    ImageExtension(
      builder: (context) => HtmlInlineImage(
        src: context.attributes['src'] ?? '',
        alt: context.attributes['alt'] ?? '',
        declaredWidth: double.tryParse(context.attributes['width'] ?? ''),
        color: color,
        maxHeight: maxHeight,
      ),
    );
