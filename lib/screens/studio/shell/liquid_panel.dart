import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// A panel that pours out of a button like a drop of liquid and drains back
/// into it.
///
/// Closed, the shape is a bead sitting on the button ([anchor]). Opening, the
/// bead stretches sideways across the screen first and then sinks into the
/// panel's place ([panel]), staying joined to the button by a neck that thins
/// and snaps as it pulls away — the metaball look. The motion is a spring, so it
/// overshoots and settles: the overshoot, and the speed at each moment, bulge
/// the leading edges outward and let the bottom sag like the belly of a drop.
/// Closing runs the same shape backwards on a stiffer spring.
///
/// Performance is the point of how it is built: [child] is laid out once, at
/// its final size, and never rebuilt by the animation. Each frame only moves a
/// clip path (a [CustomClipper] listening to the controller) and repaints the
/// fill behind it, inside a [RepaintBoundary]. Nothing lays out, nothing fades,
/// and nothing under the panel repaints.
class LiquidPanel extends StatefulWidget {
  const LiquidPanel({
    super.key,
    required this.open,
    required this.anchor,
    required this.panel,
    required this.color,
    required this.child,
    this.onDismiss,
    this.anchorRadius = 20,
  });

  final bool open;

  /// The centre of the button it grows out of, in this widget's coordinates.
  final Offset anchor;

  /// Where the open panel sits, in this widget's coordinates.
  final Rect panel;

  final Color color;

  /// The panel's content, laid out in [panel].
  final Widget child;

  /// Tapping outside the open panel.
  final VoidCallback? onDismiss;

  /// The bead's radius at rest — about the button's own.
  final double anchorRadius;

  @override
  State<LiquidPanel> createState() => _LiquidPanelState();
}

class _LiquidPanelState extends State<LiquidPanel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t =
      AnimationController.unbounded(vsync: this, value: widget.open ? 1 : 0);

  /// Pours out: a loose spring, so it overshoots and settles like a liquid.
  static const SpringDescription _openSpring =
      SpringDescription(mass: 1, stiffness: 320, damping: 19);

  /// Drains back: stiffer and near critical, so it snaps home without bouncing
  /// past the button.
  static const SpringDescription _closeSpring =
      SpringDescription(mass: 1, stiffness: 420, damping: 38);

  /// Drawn while open or while the spring is still moving. Not while merely
  /// near zero: a spring settles *within* its tolerance of the target, and a
  /// sliver of panel left over from that would still take taps.
  bool get _visible => widget.open || _t.isAnimating;

  @override
  void initState() {
    super.initState();
    _t.addStatusListener((_) {
      // The one rebuild the animation causes: dropping the panel out of the
      // tree (and out of hit testing) once it has fully drained.
      if (!_t.isAnimating && !widget.open && mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(LiquidPanel old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    final target = widget.open ? 1.0 : 0.0;
    _t.animateWith(SpringSimulation(
      widget.open ? _openSpring : _closeSpring,
      _t.value,
      target,
      _t.velocity,
      tolerance: const Tolerance(distance: 0.001, velocity: 0.01),
    ));
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    final geometry = _BlobGeometry(
      anchor: widget.anchor,
      panel: widget.panel,
      anchorRadius: widget.anchorRadius,
    );
    return Stack(
      children: [
        // Tapping anywhere outside closes it. Invisible: the panel is the only
        // thing that moves.
        if (widget.open)
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onDismiss,
            ),
          ),
        Positioned.fill(
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _BlobPainter(
                animation: _t,
                geometry: geometry,
                color: widget.color,
                shadow: Theme.of(context).colorScheme.shadow,
              ),
              child: ClipPath(
                clipper: _BlobClipper(animation: _t, geometry: geometry),
                child: Stack(
                  children: [
                    Positioned.fromRect(rect: widget.panel, child: widget.child),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The shape at a given moment of the spring.
class _BlobGeometry {
  const _BlobGeometry({
    required this.anchor,
    required this.panel,
    required this.anchorRadius,
  });

  final Offset anchor;
  final Rect panel;
  final double anchorRadius;

  static double _interval(double t, double begin, double end, Curve curve) {
    final x = ((t - begin) / (end - begin)).clamp(0.0, 1.0);
    return curve.transform(x);
  }

  Path pathAt(double t, double velocity) {
    if (t <= 0.002) return Path();
    final r0 = anchorRadius;
    final g = t.clamp(0.0, 1.0);
    // How far past the target the spring has flung it, and how fast it is
    // moving: together they are what makes the edges bulge.
    final overshoot = math.max(0.0, t - 1.0);
    final surge = (velocity / 8).clamp(-1.0, 1.0);

    // Sideways first, then down: a drop stretching before it falls.
    final sx = _interval(g, 0.0, 0.62, Curves.easeOutCubic);
    final sy = _interval(g, 0.18, 1.0, Easing.emphasizedDecelerate);

    final left = lerpDouble(anchor.dx - r0, panel.left, sx)! -
        overshoot * panel.width * 0.08;
    final right = math.min(
      lerpDouble(anchor.dx + r0, panel.right, math.min(1.0, sx * 1.7))!,
      panel.right + overshoot * 12,
    );
    final top = lerpDouble(anchor.dy - r0, panel.top, sy)!;
    final bottom = lerpDouble(anchor.dy + r0, panel.bottom, sy)! +
        overshoot * panel.height * 0.35;
    final width = math.max(0.0, right - left);
    final height = math.max(0.0, bottom - top);
    final radius = math.min(
      lerpDouble(r0, 28, g)!,
      math.min(width, height) / 2,
    );

    // The bulges: the leading (left) edge swells outward and the bottom sags
    // while the spring is moving, and both relax as it settles.
    final belly = (surge * 26 + overshoot * 60).clamp(-18.0, 34.0) *
        math.sin(math.pi * math.max(g, 0.15));
    final swell = (surge * 22 + overshoot * 40).clamp(-14.0, 26.0);

    final body = Path()
      ..moveTo(left + radius, top)
      ..lineTo(right - radius, top)
      ..arcToPoint(Offset(right, top + radius), radius: Radius.circular(radius))
      ..lineTo(right, bottom - radius)
      ..arcToPoint(Offset(right - radius, bottom),
          radius: Radius.circular(radius))
      ..quadraticBezierTo(
        (left + right) / 2,
        bottom + belly,
        left + radius,
        bottom,
      )
      ..arcToPoint(Offset(left, bottom - radius),
          radius: Radius.circular(radius))
      ..quadraticBezierTo(
        left - swell,
        (top + bottom) / 2,
        left,
        top + radius,
      )
      ..arcToPoint(Offset(left + radius, top), radius: Radius.circular(radius))
      ..close();

    // The neck back to the button: a bead that shrinks as the body pulls away,
    // joined to the body's top by two inward-curving strands. Once the body
    // has sunk clear of the bead and the bead has shrunk enough, the neck
    // snaps and only the body is left.
    final bead = r0 * (1 - Curves.easeIn.transform(g));
    final gap = top - (anchor.dy + bead);
    if (bead < 1.5 || gap > 64) return body;
    final neck = Path()..addOval(Rect.fromCircle(center: anchor, radius: bead));
    if (gap > 0) {
      final spread = bead + 10 * (1 - g);
      final waist = bead * 0.35;
      final joinY = top + 1;
      final midY = anchor.dy + bead + gap / 2;
      neck
        ..moveTo(anchor.dx - bead * 0.9, anchor.dy + bead * 0.4)
        ..cubicTo(
          anchor.dx - waist,
          midY,
          anchor.dx - spread,
          joinY - gap * 0.2,
          anchor.dx - spread - 6,
          joinY,
        )
        ..lineTo(anchor.dx + spread + 6, joinY)
        ..cubicTo(
          anchor.dx + spread,
          joinY - gap * 0.2,
          anchor.dx + waist,
          midY,
          anchor.dx + bead * 0.9,
          anchor.dy + bead * 0.4,
        )
        ..close();
    }
    return Path.combine(PathOperation.union, body, neck);
  }
}

class _BlobClipper extends CustomClipper<Path> {
  _BlobClipper({required this.animation, required this.geometry})
      : super(reclip: animation);

  final AnimationController animation;
  final _BlobGeometry geometry;

  @override
  Path getClip(Size size) =>
      geometry.pathAt(animation.value, animation.velocity);

  @override
  bool shouldReclip(_BlobClipper old) =>
      old.geometry.anchor != geometry.anchor ||
      old.geometry.panel != geometry.panel;
}

class _BlobPainter extends CustomPainter {
  _BlobPainter({
    required this.animation,
    required this.geometry,
    required this.color,
    required this.shadow,
  }) : super(repaint: animation);

  final AnimationController animation;
  final _BlobGeometry geometry;
  final Color color;
  final Color shadow;

  @override
  void paint(Canvas canvas, Size size) {
    final path = geometry.pathAt(animation.value, animation.velocity);
    canvas.drawShadow(path, shadow.withValues(alpha: 0.5), 6, false);
    canvas.drawPath(path, Paint()..color = color);
  }

  /// The fill takes no taps of its own: without this a full-screen
  /// [CustomPaint] claims every hit, and the tap-outside-to-close underneath
  /// would never see one. The rows inside the clip still get theirs.
  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(_BlobPainter old) =>
      old.color != color ||
      old.geometry.anchor != geometry.anchor ||
      old.geometry.panel != geometry.panel;
}
