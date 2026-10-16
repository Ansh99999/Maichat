import 'package:flutter/material.dart';

import 'package:provider/provider.dart' hide Provider;

import '../../models/home_layout.dart';
import '../../state/app_state.dart';

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
    this.multiple = false,
    super.help,
  });

  final HomePickKind pick;
  final bool allowNone;
  final String noneLabel;

  /// Pick several, stored comma-joined (config values are scalars only) —
  /// the time zones of a clock, the shortcuts in an app folder.
  final bool multiple;
}

enum HomePickKind {
  chat,
  provider,
  character,
  picture,
  target,
  folder,
  note,
  timezone,
}

/// A Google Fonts family (or none, for the app's own font), picked from the
/// same searchable list the rest of the app uses.
class HomeFontOption extends HomeOption {
  const HomeFontOption({required super.key, required super.label, super.help});
}

/// A choice that only matters when another option has a given value: the
/// sheet hides [option] unless `tile.config[whenKey]` is one of [whenValues]
/// (or, with [whenValues] empty, is set at all).
class HomeDependentOption extends HomeOption {
  HomeDependentOption({
    required this.option,
    required this.whenKey,
    this.whenValues = const [],
    this.whenDefault,
  }) : super(key: option.key, label: option.label, help: option.help);

  final HomeOption option;
  final String whenKey;
  final List<String> whenValues;

  /// What `whenKey` counts as when it is unset.
  final String? whenDefault;

  bool shows(HomeTile tile) {
    final v = tile.config[whenKey]?.toString() ?? whenDefault;
    if (whenValues.isEmpty) return v != null && v.isNotEmpty;
    return whenValues.contains(v);
  }
}

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

/// How the tile a widget is drawn in stands right now, for the widget's own
/// surface to show: picked (the menu or the resize handles are on it), lifted
/// (being carried), or the home screen is in edit mode.
///
/// The highlight is drawn by the widget's **visible surface** — a card, an icon,
/// a pill — on its own shape, never as a box around the cell: an outline
/// around the cell stood off the edges of anything smaller than its cell (an
/// icon, a search bar), which looked careless. [HomeCard] does this itself;
/// anything else wraps its surface in [HomeOutlined].
class HomeTileStatus extends InheritedWidget {
  const HomeTileStatus({
    super.key,
    required this.selected,
    required this.lifted,
    required this.editing,
    required super.child,
  });

  final bool selected;
  final bool lifted;
  final bool editing;

  static HomeTileStatus? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeTileStatus>();

  @override
  bool updateShouldNotify(HomeTileStatus old) =>
      old.selected != selected ||
      old.lifted != lifted ||
      old.editing != editing;
}

/// The selection ring a surface shows on its own [shape], edge to edge.
BorderSide homeOutlineSide(BuildContext context) {
  final status = HomeTileStatus.maybeOf(context);
  final scheme = Theme.of(context).colorScheme;
  if (status == null) return BorderSide.none;
  if (status.selected || status.lifted) {
    return BorderSide(
      color: scheme.primary,
      width: 3,
      strokeAlign: BorderSide.strokeAlignInside,
    );
  }
  return BorderSide.none;
}

/// Paints [homeOutlineSide] over [child] on exactly [shape] — for a widget
/// whose visible surface is not a [HomeCard] (an app icon, a pill). While the
/// tile is carried it also casts the lifted shadow.
class HomeOutlined extends StatelessWidget {
  const HomeOutlined({super.key, required this.shape, required this.child});

  final OutlinedBorder shape;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final side = homeOutlineSide(context);
    final lifted = HomeTileStatus.maybeOf(context)?.lifted ?? false;
    final scheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: lifted
            ? [
                BoxShadow(
                  color: scheme.shadow.withValues(alpha: 0.28),
                  blurRadius: 18,
                  offset: const Offset(0, 8),
                ),
              ]
            : null,
      ),
      position: DecorationPosition.background,
      // Keep the same element structure when selection changes: inserting a
      // wrapper here used to remount avatar/image and folder content.
      child: DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: ShapeDecoration(shape: shape.copyWith(side: side)),
        child: child,
      ),
    );
  }
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
    final base =
        shape ??
        RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(radius));
    final body = LayoutBuilder(
      builder: (context, c) {
        final pad = _paddingFor(c);
        final inner = Size(
          c.hasBoundedWidth
              ? (c.maxWidth - pad.horizontal).clamp(0, double.infinity)
              : 0,
          c.hasBoundedHeight
              ? (c.maxHeight - pad.vertical).clamp(0, double.infinity)
              : 0,
        );
        var content = builder?.call(context, inner) ?? child!;
        if (fit && c.hasBoundedWidth && c.hasBoundedHeight) {
          content = HomeShrink(
            size: inner,
            alignment: alignment,
            child: content,
          );
        }
        return Padding(padding: pad, child: content);
      },
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      button: onTap != null,
      child: _HomeCardSurface(
        shape: base,
        color: color ?? scheme.surfaceContainerHigh,
        clip: clip,
        onTap: onTap,
        child: body,
      ),
    );
  }
}

/// Only the lightweight surface listens to selection. Its content is retained
/// as a child, so changing the ring cannot rerun measured widget layouts.
class _HomeCardSurface extends StatelessWidget {
  const _HomeCardSurface({
    required this.shape,
    required this.color,
    required this.clip,
    required this.onTap,
    required this.child,
  });

  final ShapeBorder shape;
  final Color color;
  final bool clip;
  final VoidCallback? onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final side = homeOutlineSide(context);
    final status = HomeTileStatus.maybeOf(context);
    final outline = shape is OutlinedBorder
        ? (shape as OutlinedBorder).copyWith(side: side)
        : shape;
    return Material(
      color: color,
      shape: outline,
      elevation: status?.lifted == true ? 8 : 0,
      shadowColor: Theme.of(context).colorScheme.shadow,
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      child: onTap == null
          ? child
          : InkWell(customBorder: outline, onTap: onTap, child: child),
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

/// Rebuilds the calling widget only when [signature] changes, then hands back
/// the state to read from.
///
/// `context.watch<AppState>()` rebuilt every tile on every notify — a reply
/// streaming into a chat notifies many times a second, and a home screen of
/// widgets all rebuilding under a page swipe is a stutter. A widget names the
/// few values it actually draws (a record, a string, a number: something that
/// compares by value), and only a change to those rebuilds it.
AppState homeWatch(
  BuildContext context,
  Object? Function(AppState state) signature,
) {
  context.select<AppState, Object?>(signature);
  return context.read<AppState>();
}
