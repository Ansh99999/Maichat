import 'package:flutter/widgets.dart';

/// Where the Studio shell's floating chrome sits over a page, so the page can
/// keep its own content clear of it.
///
/// The shell has no app bar. It floats a soft 48-dp menu square at the top left
/// (and, once there are sub-agents, another at the top right), and the capsule
/// and composer float over the bottom edge. A page lays its content out
/// underneath all of it — text scrolls on behind the composer and fades as it
/// goes — and uses these insets to keep what matters out from under:
///
/// - [top]: the status bar plus the row the floating squares sit in. A page
///   whose first row can share that row (the Draft's tab strip) starts at
///   [statusBar] instead and indents by [side].
/// - [side]: how far in from each edge the floating squares reach.
/// - [bottom]: the height of whatever floats at the bottom (capsule, composer),
///   plus the safe area, so the last item can be scrolled clear of it.
class StudioChrome extends InheritedWidget {
  const StudioChrome({
    super.key,
    required this.statusBar,
    required this.bottom,
    this.rightButton = false,
    required super.child,
  });

  /// Whether a floating square sits at the top right too (the sub-agents
  /// button, once there are sub-agents).
  final bool rightButton;

  /// The system status bar's height.
  final double statusBar;

  /// What floats over the page's bottom edge, safe area included.
  final double bottom;

  /// The floating squares: 48 dp, 8 dp from the edge, 6 dp below the status
  /// bar.
  static const double buttonSize = 48;
  static const double buttonMargin = 8;
  static const double buttonTop = 6;

  /// How far in from each side the floating squares reach, with a little air.
  static const double side = buttonMargin + buttonSize + 8;

  /// The status bar plus the floating squares' row.
  double get top => statusBar + buttonTop + buttonSize + 8;

  /// The shell's insets, or a no-chrome default for a page shown on its own
  /// (a test).
  static StudioChrome of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<StudioChrome>() ??
      const StudioChrome(statusBar: 0, bottom: 0, child: SizedBox.shrink());

  @override
  bool updateShouldNotify(StudioChrome old) =>
      old.statusBar != statusBar ||
      old.bottom != bottom ||
      old.rightButton != rightButton;
}
