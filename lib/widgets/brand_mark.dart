import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Where the brand mark lives on disk.
///
/// The traced line art is hairline thin, so the asset carries a small stroke
/// widening (`stroke-width` on the path group). Without it the lines fall under
/// a device pixel at the 18–24 dp the mark is mostly drawn at and grey out into
/// mush; with it one file reads correctly from an inline glyph up to the 64 dp
/// empty-state illustration, which is why there is no second "small" variant.
const String kMaiChatMarkAsset = 'assets/brand/maichat_mark.svg';

/// The app's own name, in the one spelling the UI uses.
const String kMaiChatName = 'MaiChat';

/// MaiChat's logo, drawn as a monochrome glyph in the current colour.
///
/// It behaves like an icon: with nothing passed it takes its size from the
/// ambient [IconTheme] and its colour from whichever component published one —
/// a [ListTile]'s leading slot does, so a picker row's mark turns `primary`
/// when the row is selected and dims when it is disabled. With no component
/// speaking up it falls back to the scheme's `onSurfaceVariant` rather than
/// [ThemeData]'s flat black/white icon default, so it lands on Material You's
/// palette and follows light/dark/AMOLED and a custom seed with no second asset.
///
/// That is also why the asset is a vector. A PNG would freeze one colour, and
/// the mark is line art that has to stay crisp from an 18 dp inline glyph up to
/// a 64 dp empty-state illustration. The `fill="currentColor"` in the SVG is
/// not what tints it (a [ColorFilter] is), but it keeps the file honest about
/// being monochrome.
class MaiChatMark extends StatelessWidget {
  const MaiChatMark({super.key, this.size, this.color, this.semanticLabel});

  /// Side of the square the mark is drawn in. Defaults to the ambient
  /// [IconTheme]'s size, then to 24 — Material's own icon size.
  final double? size;

  /// Tint. Defaults to the enclosing component's icon colour, then to the
  /// scheme's `onSurfaceVariant` — see [_ambientTint].
  final Color? color;

  /// Read out by a screen reader. Null keeps the mark decorative, which is
  /// right whenever the word "MaiChat" is beside it anyway.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final icons = IconTheme.of(context);
    final side = size ?? icons.size ?? 24;
    return SvgPicture.asset(
      kMaiChatMarkAsset,
      width: side,
      height: side,
      colorFilter: ColorFilter.mode(
        color ?? _ambientTint(theme, icons),
        BlendMode.srcIn,
      ),
      semanticsLabel: semanticLabel,
      // The mark is square; letting it letterbox stops a non-square slot from
      // stretching the face.
      fit: BoxFit.contain,
    );
  }

  /// The colour to draw in when the caller named none.
  ///
  /// A component that publishes its own icon colour wins — [ListTile] does
  /// exactly that, which is how a picker row's mark dims when disabled and
  /// turns `primary` when selected. Otherwise we deliberately ignore what the
  /// ambient [IconTheme] says, because [ThemeData] seeds it with flat black or
  /// white: an [Icon] can live with that, but a brand mark that is supposed to
  /// follow the wallpaper palette cannot. `onSurfaceVariant` is the scheme's
  /// own answer for a quiet foreground.
  Color _ambientTint(ThemeData theme, IconThemeData icons) {
    final ambient = icons.color;
    final themeDefault = theme.iconTheme.color;
    if (ambient == null || ambient == themeDefault) {
      return theme.colorScheme.onSurfaceVariant;
    }
    return ambient.withValues(alpha: icons.opacity ?? ambient.a);
  }
}

/// [text] with the mark drawn in front of every mention of "MaiChat".
///
/// A drop-in for [Text] at the places the app names itself — most of them a
/// row in an export or import picker, where MaiChat is one option among
/// SillyTavern, Agnai and the rest. Text with no mention renders exactly as
/// [Text] would, so a caller that passes a format label through (say
/// `offerExport`'s subtitle) needs no branching.
///
/// The mark is an inline [WidgetSpan], not a [ListTile.leading]: the sibling
/// options have no logo to show, and hanging an icon off our row alone would
/// leave the list ragged. Inline it belongs to the word — it sits on the text's
/// baseline box, inherits the text's colour so it dims and highlights with the
/// label, and grows with the platform's font-size setting.
class BrandedText extends StatelessWidget {
  const BrandedText(
    this.text, {
    super.key,
    this.style,
    this.markScale = 1.35,
    this.markColor,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });

  /// The label. Every occurrence of "MaiChat" gets a mark in front of it.
  final String text;

  /// Merged over the ambient [DefaultTextStyle] (a [ListTile] title's
  /// `bodyLarge`, the drawer header's `headlineSmall`, …).
  final TextStyle? style;

  /// Mark side as a multiple of the resolved font size. Over 1 because a face
  /// drawn inside a square box reads smaller than a capital of the same height,
  /// and the mark has to carry the weight of the word beside it.
  final double markScale;

  /// Tint for the mark alone. Defaults to the text's own colour.
  final Color? markColor;

  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) {
    final resolved = DefaultTextStyle.of(context).style.merge(style);
    // The platform's font scale grows the text, so the mark grows with it.
    final fontSize = MediaQuery.textScalerOf(context)
        .scale(resolved.fontSize ?? kDefaultFontSize);
    final mark = WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Padding(
        padding: EdgeInsets.only(right: fontSize * 0.24),
        child: MaiChatMark(
          size: fontSize * markScale,
          color: markColor ?? resolved.color,
        ),
      ),
    );

    final spans = <InlineSpan>[];
    var start = 0;
    for (var at = text.indexOf(kMaiChatName);
        at >= 0;
        at = text.indexOf(kMaiChatName, start)) {
      if (at > start) spans.add(TextSpan(text: text.substring(start, at)));
      spans.add(mark);
      spans.add(const TextSpan(text: kMaiChatName));
      start = at + kMaiChatName.length;
    }
    if (spans.isEmpty) {
      // Nothing to brand — behave as a plain Text so every call site can use
      // this unconditionally.
      return Text(
        text,
        style: style,
        textAlign: textAlign,
        maxLines: maxLines,
        overflow: overflow,
      );
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));

    return Text.rich(
      TextSpan(children: spans),
      style: resolved,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      // The mark is decorative; a reader should hear the sentence, not "image".
      semanticsLabel: text,
    );
  }
}
