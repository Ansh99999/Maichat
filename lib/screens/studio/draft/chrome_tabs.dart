import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../shell/studio_chrome.dart';

/// One tab of a [ChromeTabbedPages].
class ChromeTab {
  const ChromeTab({
    required this.label,
    required this.icon,
    required this.page,
  });

  final String label;
  final IconData icon;
  final Widget page;
}

/// Pages under a strip of browser-style tabs: each tab a rectangle rounded at
/// its top corners, the selected one the same colour as the page beneath and
/// joined to it — no seam, with the small inverted curves at its feet that make
/// it read as one piece of material with the page. Unselected tabs sit flat on
/// the strip with thin separators between them, as Chrome draws them.
///
/// The selected shape is not a per-tab state that flips: it is painted from the
/// page view's continuous position, so a swipe drags it between tabs under the
/// finger and a tap sends it there on a spring. Nothing fades.
class ChromeTabbedPages extends StatefulWidget {
  const ChromeTabbedPages({
    super.key,
    required this.tabs,
    this.initialIndex = 0,
    this.onChanged,
  });

  final List<ChromeTab> tabs;
  final int initialIndex;
  final ValueChanged<int>? onChanged;

  @override
  State<ChromeTabbedPages> createState() => ChromeTabbedPagesState();
}

class ChromeTabbedPagesState extends State<ChromeTabbedPages> {
  late final PageController _pages = PageController(
    initialPage: widget.initialIndex,
  );
  final ScrollController _strip = ScrollController();
  late int _index = widget.initialIndex;

  /// The tab showing now.
  int get index => _index;

  @override
  void dispose() {
    _pages.dispose();
    _strip.dispose();
    super.dispose();
  }

  /// Moves to tab [i] on a spring.
  void select(int i) {
    if (i == _index && (_pages.page ?? i.toDouble()) == i) return;
    _pages.animateToPage(
      i,
      duration: const Duration(milliseconds: 520),
      curve: const SpringCurve(),
    );
  }

  void _onPageChanged(int i, List<double> widths) {
    setState(() => _index = i);
    widget.onChanged?.call(i);
    _revealTab(i, widths);
  }

  /// Scrolls the strip so tab [i] sits in view — centred when there is room.
  void _revealTab(int i, List<double> widths) {
    if (!_strip.hasClients) return;
    final left = _ChromeTabMetrics.leftOf(widths, i);
    final viewport = _strip.position.viewportDimension;
    final target = (left + widths[i] / 2 - viewport / 2).clamp(
      0.0,
      _strip.position.maxScrollExtent,
    );
    _strip.animateTo(
      target,
      duration: const Duration(milliseconds: 420),
      curve: const SpringCurve(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = (theme.textTheme.labelLarge ?? const TextStyle()).copyWith(
      fontWeight: FontWeight.w600,
    );
    final scaler = MediaQuery.textScalerOf(context);
    final widths = [
      for (final t in widget.tabs)
        _ChromeTabMetrics.widthOf(
          t.label,
          style,
          scaler,
          Directionality.of(context),
        ),
    ];
    final surface = scheme.surfaceContainerLow;
    // Inside the Studio shell there is no app bar: the strip sits just under
    // the status bar, in the row the floating menu square shares, and is kept
    // clear of that square (and of the sub-agents square on the right, when
    // there is one) — so the page's top is tabs, not chrome.
    final chrome = context.dependOnInheritedWidgetOfExactType<StudioChrome>();
    final top = chrome == null
        ? 0.0
        : chrome.statusBar +
              StudioChrome.buttonTop +
              (StudioChrome.buttonSize - _ChromeTabMetrics.stripHeight);
    final left = chrome == null ? 0.0 : StudioChrome.side - 8;
    final right = chrome == null || !chrome.rightButton
        ? 0.0
        : StudioChrome.side - 8;
    return Column(
      children: [
        Container(
          height: _ChromeTabMetrics.stripHeight + top,
          padding: EdgeInsets.only(top: top, left: left, right: right),
          child: SingleChildScrollView(
            controller: _strip,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(
              horizontal: _ChromeTabMetrics.flare,
            ),
            child: AnimatedBuilder(
              animation: _pages,
              builder: (context, _) {
                final position =
                    _pages.hasClients && _pages.position.hasContentDimensions
                    ? (_pages.page ?? _index.toDouble())
                    : _index.toDouble();
                return CustomPaint(
                  painter: _ChromeTabPainter(
                    widths: widths,
                    position: position,
                    selectedColor: surface,
                    separatorColor: scheme.outlineVariant,
                  ),
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.tabs.length; i++)
                        _TabLabel(
                          tab: widget.tabs[i],
                          width: widths[i],
                          style: style,
                          // How selected this tab is right now, 0–1, from the
                          // page's position — so its colour follows a swipe.
                          selectedness: (1 - (position - i).abs()).clamp(
                            0.0,
                            1.0,
                          ),
                          onTap: () => select(i),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
        Expanded(
          child: ColoredBox(
            color: surface,
            child: PageView(
              controller: _pages,
              onPageChanged: (i) => _onPageChanged(i, widths),
              children: [for (final t in widget.tabs) t.page],
            ),
          ),
        ),
      ],
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({
    required this.tab,
    required this.width,
    required this.style,
    required this.selectedness,
    required this.onTap,
  });

  final ChromeTab tab;
  final double width;
  final TextStyle style;
  final double selectedness;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = Color.lerp(
      scheme.onSurfaceVariant,
      scheme.primary,
      selectedness,
    )!;
    return Semantics(
      selected: selectedness > 0.5,
      button: true,
      label: tab.label,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(_ChromeTabMetrics.radius),
        ),
        child: SizedBox(
          width: width,
          height: _ChromeTabMetrics.stripHeight,
          child: Padding(
            padding: const EdgeInsets.only(top: _ChromeTabMetrics.topGap),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(tab.icon, size: _ChromeTabMetrics.iconSize, color: color),
                const SizedBox(width: _ChromeTabMetrics.gap),
                Text(
                  tab.label,
                  style: style.copyWith(color: color),
                  maxLines: 1,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip's measurements, shared by the labels (which lay out at them) and
/// the painter (which draws the selected shape around them). Widths come from
/// the text itself, so the shape fits its label exactly without a layout pass
/// to measure it.
abstract final class _ChromeTabMetrics {
  static const double stripHeight = 46;

  /// Space above a tab, so its rounded top stands clear of the strip's edge.
  static const double topGap = 6;
  static const double radius = 14;

  /// The inverted curve at each foot of the selected tab.
  static const double flare = 10;
  static const double padding = 18;
  static const double iconSize = 18;
  static const double gap = 8;

  static double widthOf(
    String label,
    TextStyle style,
    TextScaler scaler,
    TextDirection direction,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return (padding * 2 + iconSize + gap + w).ceilToDouble();
  }

  static double leftOf(List<double> widths, int i) {
    var left = 0.0;
    for (var k = 0; k < i; k++) {
      left += widths[k];
    }
    return left;
  }
}

class _ChromeTabPainter extends CustomPainter {
  _ChromeTabPainter({
    required this.widths,
    required this.position,
    required this.selectedColor,
    required this.separatorColor,
  });

  final List<double> widths;

  /// The page view's position: 2.4 is four tenths of the way from tab 2 to 3.
  final double position;
  final Color selectedColor;
  final Color separatorColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (widths.isEmpty) return;
    final p = position.clamp(0.0, widths.length - 1.0);
    final lower = p.floor();
    final upper = math.min(lower + 1, widths.length - 1);
    final t = p - lower;
    // The shape slides and stretches between the two tabs it is between.
    final left = _lerp(
      _ChromeTabMetrics.leftOf(widths, lower),
      _ChromeTabMetrics.leftOf(widths, upper),
      t,
    );
    final width = _lerp(widths[lower], widths[upper], t);

    // Separators between unselected neighbours; one fades as the shape nears.
    final line = Paint()
      ..color = separatorColor
      ..strokeWidth = 1;
    var x = 0.0;
    for (var k = 0; k < widths.length - 1; k++) {
      x += widths[k];
      final near = math.min((p - k).abs(), (p - (k + 1)).abs());
      final opacity = near.clamp(0.0, 1.0);
      if (opacity <= 0) continue;
      line.color = separatorColor.withValues(alpha: separatorColor.a * opacity);
      final top = _ChromeTabMetrics.topGap + 12;
      canvas.drawLine(Offset(x, top), Offset(x, size.height - 10), line);
    }

    canvas.drawPath(
      chromeTabPath(
        left: left,
        right: left + width,
        top: _ChromeTabMetrics.topGap,
        bottom: size.height,
      ),
      Paint()..color = selectedColor,
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  bool shouldRepaint(_ChromeTabPainter old) =>
      old.position != position ||
      old.selectedColor != selectedColor ||
      old.separatorColor != separatorColor ||
      old.widths.length != widths.length ||
      !_sameWidths(old.widths);

  bool _sameWidths(List<double> other) {
    for (var i = 0; i < widths.length; i++) {
      if (widths[i] != other[i]) return false;
    }
    return true;
  }
}

/// The selected tab's outline: rounded shoulders on top, straight sides, and at
/// the bottom a concave flare out to each side, so the tab runs into the page.
Path chromeTabPath({
  required double left,
  required double right,
  required double top,
  required double bottom,
  double radius = _ChromeTabMetrics.radius,
  double flare = _ChromeTabMetrics.flare,
}) => Path()
  ..moveTo(left - flare, bottom)
  ..quadraticBezierTo(left, bottom, left, bottom - flare)
  ..lineTo(left, top + radius)
  ..quadraticBezierTo(left, top, left + radius, top)
  ..lineTo(right - radius, top)
  ..quadraticBezierTo(right, top, right, top + radius)
  ..lineTo(right, bottom - flare)
  ..quadraticBezierTo(right, bottom, right + flare, bottom)
  ..close();

/// A critically-damped-to-lightly-bouncy spring as a [Curve], for motion the
/// Material 3 Expressive way: fast off the mark, settling with a hint of give
/// rather than easing out on a fixed polynomial.
class SpringCurve extends Curve {
  const SpringCurve({this.dampingRatio = 0.82, this.stiffness = 380});

  final double dampingRatio;
  final double stiffness;

  /// How long the simulation is sampled over; the curve's duration maps onto it.
  static const double _span = 0.52;

  @override
  double transformInternal(double t) {
    final spring = SpringSimulation(
      SpringDescription.withDampingRatio(
        mass: 1,
        stiffness: stiffness,
        ratio: dampingRatio,
      ),
      0,
      1,
      0,
    );
    return spring.x(t * _span);
  }
}
