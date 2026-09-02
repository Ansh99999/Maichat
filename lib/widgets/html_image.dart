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

  /// What a picture that could not be drawn leaves behind.
  ///
  /// Never nothing. `![](…)` — the usual way a model writes a picture, and
  /// perfectly good markdown — carries no alt text, so falling back to an empty
  /// box made a failed fetch indistinguishable from the app having ignored the
  /// line altogether. That is what made this look like a parsing bug: the same
  /// URL with a word in the brackets showed *something*, so the brackets got the
  /// blame. A marker says what is true — a picture belongs here and it did not
  /// arrive — which is what a browser shows too.
  Widget _altText() {
    final faded = color.withValues(alpha: 0.7);
    final label = alt.trim();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.broken_image_outlined, size: 18, color: faded),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(child: Text(label, style: TextStyle(color: faded))),
        ],
      ],
    );
  }
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
