import 'package:flutter/material.dart';

/// Identifies the collapsed button, so a test can reach it without depending on
/// its glyph — a page's app bar very often carries the same three dots.
const Key fabMenuButtonKey = ValueKey('fab-menu-button');

/// One entry in a [FabMenu].
class FabMenuAction {
  const FabMenuAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;
}

/// A bottom-right bubble that opens into a stack of labelled bubbles — the
/// Material expanding-FAB pattern.
///
/// Collapsed it is one button, so a page keeps a single obvious action point;
/// expanded, each choice is its own bubble with its label beside it, and a tap
/// anywhere else closes it.
///
/// Place it as a `Positioned.fill` child of the page's own [Stack] rather than in
/// `Scaffold.floatingActionButton`: it needs the whole area to catch the
/// tap-away, and the bubbles have to be able to grow up the page. It is
/// hit-transparent while closed, so the content underneath behaves normally.
///
/// Everything animates from a single [AnimationController], the bubbles are only
/// in the tree while the menu is open or closing, and the scrim is a plain colour
/// rather than a [BackdropFilter] — a blur here would repaint the whole page on
/// every frame of the open.
class FabMenu extends StatefulWidget {
  const FabMenu({
    super.key,
    required this.actions,
    this.icon = Icons.more_vert,
    this.closeIcon = Icons.close,
    this.tooltip = 'More',
    this.padding = const EdgeInsets.all(16),
  });

  final List<FabMenuAction> actions;
  final IconData icon;
  final IconData closeIcon;
  final String tooltip;

  /// Inset of the collapsed button from the bottom-right corner.
  final EdgeInsets padding;

  @override
  State<FabMenu> createState() => _FabMenuState();
}

class _FabMenuState extends State<FabMenu> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 160),
    vsync: this,
  );

  bool _open = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() => _open = !_open);
    if (_open) {
      _controller.forward();
    } else {
      _controller.reverse();
    }
  }

  void _close() {
    if (!_open) return;
    setState(() => _open = false);
    _controller.reverse();
  }

  void _run(FabMenuAction action) {
    _close();
    action.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // A closed menu must not intercept anything: the page scrolls and its
        // links work exactly as if this widget were not here.
        final absorbing = _open || t > 0;
        return Stack(
          alignment: Alignment.bottomRight,
          children: [
            if (absorbing)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !_open,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _close,
                    child: ColoredBox(
                      color: scheme.scrim.withValues(alpha: 0.32 * t),
                    ),
                  ),
                ),
              ),
            Padding(
              padding: widget.padding,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (absorbing)
                    for (var i = 0; i < widget.actions.length; i++)
                      _Bubble(
                        action: widget.actions[i],
                        // The bubble nearest the button leads, so the group reads
                        // as unfolding out of it rather than arriving at once.
                        progress: _staggered(
                          t,
                          widget.actions.length - 1 - i,
                          widget.actions.length,
                        ),
                        onPressed: () => _run(widget.actions[i]),
                      ),
                  FloatingActionButton(
                    key: fabMenuButtonKey,
                    onPressed: _toggle,
                    tooltip: _open ? 'Close' : widget.tooltip,
                    child: Transform.rotate(
                      angle: t * 1.5708, // a quarter turn
                      child: Icon(_open ? widget.closeIcon : widget.icon),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  /// [t] remapped so bubble [index] of [count] starts a little after the one
  /// below it and all of them finish together.
  static double _staggered(double t, int index, int count) {
    if (count <= 1) return t;
    const step = 0.12;
    final start = index * step;
    final span = 1 - start;
    if (span <= 0) return t;
    return Curves.easeOutCubic.transform(
      ((t - start) / span).clamp(0.0, 1.0),
    );
  }
}

/// One labelled bubble: the label sits outside the circle on its own tinted
/// pill, so it stays readable over whatever the page is showing.
class _Bubble extends StatelessWidget {
  const _Bubble({
    required this.action,
    required this.progress,
    required this.onPressed,
  });

  final FabMenuAction action;

  /// 0 hidden, 1 fully out.
  final double progress;

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    if (progress <= 0) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: progress,
      child: Transform.translate(
        offset: Offset(0, (1 - progress) * 16),
        child: Transform.scale(
          scale: 0.85 + 0.15 * progress,
          alignment: Alignment.bottomRight,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Material(
                  color: scheme.surfaceContainerHighest,
                  elevation: 2,
                  borderRadius: BorderRadius.circular(8),
                  child: InkWell(
                    onTap: onPressed,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      child: Text(
                        action.label,
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: scheme.onSurface,
                            ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FloatingActionButton.small(
                  heroTag: null,
                  onPressed: onPressed,
                  tooltip: action.label,
                  child: Icon(action.icon),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
