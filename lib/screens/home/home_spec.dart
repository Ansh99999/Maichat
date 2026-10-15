import 'package:flutter/material.dart';

import '../../models/home_layout.dart';

/// What a widget on the Home grid is told about where it is drawn.
///
/// Handed to [HomeWidgetSpec.build]: the tile itself (its span and settings),
/// the pixel size it has been given, the layout's look, and whether the screen
/// is being edited — in which case the widget is drawn but not touchable, and
/// should show a sensible placeholder rather than an empty box when it has
/// nothing to show yet.
class HomeTileContext {
  const HomeTileContext({
    required this.tile,
    required this.size,
    required this.layout,
    required this.editing,
  });

  final HomeTile tile;

  /// The tile's drawn size in logical pixels, gutters already taken off.
  final Size size;

  final HomeLayout layout;

  /// True in edit mode: the widget must not navigate, start timers that
  /// matter, or open anything — taps go to the editor.
  final bool editing;

  /// Short for `tile.w` / `tile.h`.
  int get w => tile.w;
  int get h => tile.h;

  /// Whether the tile is small enough that only a glance fits (one cell high
  /// or one cell wide).
  bool get compact => tile.w == 1 || tile.h == 1;
}

/// One setting a widget offers in its settings sheet. The sheet draws these
/// generically and writes each answer into [HomeTile.config] under [key].
sealed class HomeOption {
  const HomeOption({required this.key, required this.label, this.help});

  /// The config key the answer is stored under.
  final String key;

  final String label;

  /// One line under the label, when the setting needs explaining.
  final String? help;
}

/// One of a few fixed values, drawn as chips (or a segmented button when they
/// are short). [choices] maps the stored value to its label; the first entry
/// is the default.
class HomeChoiceOption extends HomeOption {
  const HomeChoiceOption({
    required super.key,
    required super.label,
    required this.choices,
    super.help,
  });

  final Map<String, String> choices;
}

/// An on/off switch. [fallback] is its value when the key is unset.
class HomeToggleOption extends HomeOption {
  const HomeToggleOption({
    required super.key,
    required super.label,
    this.fallback = false,
    super.help,
  });

  final bool fallback;
}

/// A whole number in a range, drawn as a slider with its value beside it.
class HomeStepperOption extends HomeOption {
  const HomeStepperOption({
    required super.key,
    required super.label,
    required this.min,
    required this.max,
    required this.fallback,
    this.unit = '',
    super.help,
  });

  final int min;
  final int max;
  final int fallback;

  /// Shown after the number ("s", " pictures").
  final String unit;
}

/// Something the user picks from a list the app holds: a chat, a provider, a
/// character, a gallery picture or a quick-open destination. The stored value
/// is its id — except a picture, stored as its ref (`local:…` or a URL, what
/// the picture sweep keeps), and a target, stored as the [QuickTarget] name.
/// [allowNone] adds a "none" row whose meaning [noneLabel] spells out (e.g.
/// "The active provider").
class HomePickOption extends HomeOption {
  const HomePickOption({
    required super.key,
    required super.label,
    required this.pick,
    this.allowNone = true,
    this.noneLabel = 'None',
    super.help,
  });

  final HomePickKind pick;
  final bool allowNone;
  final String noneLabel;
}

enum HomePickKind { chat, provider, character, picture, target }

/// A free line of text (a custom label).
class HomeTextOption extends HomeOption {
  const HomeTextOption({
    required super.key,
    required super.label,
    this.hint = '',
    super.help,
  });

  final String hint;
}

/// Everything the Home screen needs to know about one kind of widget: how it
/// introduces itself in the picker, the smallest span it can be drawn at, what
/// it can be set to, and how to draw it.
///
/// Specs are stateless and const; a widget that needs state builds a
/// `StatefulWidget` from [build].
abstract class HomeWidgetSpec {
  const HomeWidgetSpec();

  HomeWidgetKind get kind;

  /// Its name in the picker and the editor ("Recent chat").
  String get title;

  /// One sentence for the picker.
  String get description;

  IconData get icon;

  /// The smallest span it is still readable at. Resizing never goes below it.
  ({int w, int h}) get minSpan => (w: 1, h: 1);

  /// The settings its sheet offers. Empty means the sheet says there is
  /// nothing to set.
  List<HomeOption> options(HomeTile tile) => const [];

  /// A one-line description of this particular tile, for the editor's bar
  /// ("Recent chat · 2nd latest").
  String describe(BuildContext context, HomeTile tile) => title;

  /// The config a fresh tile of this kind starts with.
  Map<String, Object?> get initialConfig => const <String, Object?>{};

  Widget build(BuildContext context, HomeTileContext tile);
}

/// The shared surface most widgets sit on: a soft, rounded container in the
/// surface-container tone, with ink for taps.
///
/// A tile can be any size the user drags it to, on any grid, under any font
/// scale, so nothing inside may assume a height. The card measures the box
/// inside its padding and hands it to [builder], which decides what fits
/// (drop a line, shrink an icon). Whatever still does not fit is scaled down
/// as a whole rather than overflowing — so content must never use `Expanded`
/// or `Spacer` vertically (set [fit] false for content that fills its box,
/// like a picture grid). Padding shrinks with very short cards too.
class HomeCard extends StatelessWidget {
  const HomeCard({
    super.key,
    this.child,
    this.builder,
    this.onTap,
    this.color,
    this.padding = const EdgeInsets.all(14),
    this.semanticLabel,
    this.clip = false,
    this.fit = true,
    this.alignment = AlignmentDirectional.centerStart,
    this.shape,
  }) : assert(child != null || builder != null);

  final Widget? child;

  /// Builds the content for the box inside the padding. Preferred over
  /// [child] whenever what is shown depends on the room there is.
  final Widget Function(BuildContext context, Size inner)? builder;

  final VoidCallback? onTap;

  /// Defaults to `surfaceContainerHigh`.
  final Color? color;

  final EdgeInsets padding;
  final String? semanticLabel;

  /// Clip the child to the rounded shape (pictures edge to edge).
  final bool clip;

  /// Lay the content out at its natural height and scale it down if that is
  /// more than there is room for. Off for content that sizes itself to the box.
  final bool fit;

  /// Where content shorter than the box sits.
  final AlignmentGeometry alignment;

  /// Defaults to a [radius] superellipse.
  final ShapeBorder? shape;

  static const double radius = 28;

  /// Below this inner height the padding is scaled down with the card.
  static const double _roomy = 96;

  EdgeInsets _paddingFor(BoxConstraints c) {
    if (!c.hasBoundedHeight || c.maxHeight >= _roomy) return padding;
    final k = (c.maxHeight / _roomy).clamp(0.35, 1.0);
    return EdgeInsets.fromLTRB(
      padding.left * (0.5 + k / 2),
      padding.top * k,
      padding.right * (0.5 + k / 2),
      padding.bottom * k,
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final outline = shape ??
        RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));
    final body = LayoutBuilder(
      builder: (context, c) {
        final pad = _paddingFor(c);
        final inner = Size(
          c.hasBoundedWidth ? (c.maxWidth - pad.horizontal).clamp(0, double.infinity) : 0,
          c.hasBoundedHeight ? (c.maxHeight - pad.vertical).clamp(0, double.infinity) : 0,
        );
        var content = builder?.call(context, inner) ?? child!;
        if (fit && c.hasBoundedWidth && c.hasBoundedHeight) {
          content = HomeShrink(size: inner, alignment: alignment, child: content);
        }
        return Padding(padding: pad, child: content);
      },
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      button: onTap != null,
      child: Material(
        color: color ?? scheme.surfaceContainerHigh,
        shape: outline,
        clipBehavior: clip ? Clip.antiAlias : Clip.none,
        child: onTap == null
            ? body
            : InkWell(customBorder: outline, onTap: onTap, child: body),
      ),
    );
  }
}

/// Lays [child] out at [size]'s width (never narrower than [minWidth]) and its
/// own natural height, then scales it down to fit [size] if it came out bigger
/// — the last line of defence against a tile too small for even its smallest
/// content (a dense grid, a big font, a widget squeezed below its minimum
/// span by a grid change).
class HomeShrink extends StatelessWidget {
  const HomeShrink({
    super.key,
    required this.size,
    required this.child,
    this.alignment = AlignmentDirectional.centerStart,
    this.minWidth = 72,
  });

  final Size size;
  final Widget child;
  final AlignmentGeometry alignment;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    if (size.width <= 0 || size.height <= 0) return const SizedBox.shrink();
    return SizedBox.fromSize(
      size: size,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: SizedBox(
          width: size.width < minWidth ? minWidth : size.width,
          child: child,
        ),
      ),
    );
  }
}

/// How tall one line of [style] is on screen, with the user's font scale.
double homeLineHeight(BuildContext context, TextStyle? style) {
  final size = style?.fontSize ?? 14;
  return MediaQuery.textScalerOf(context).scale(size) * (style?.height ?? 1.25);
}
