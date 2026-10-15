import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../models/home_layout.dart';

/// The outline a quick-open icon is drawn in, at [side] logical pixels.
///
/// Shared by the quick-open widget and the style sheet's preview, so what is
/// picked is exactly what is drawn.
ShapeBorder homeIconBorder(HomeIconShape shape, double side) => switch (shape) {
      HomeIconShape.circle => const CircleBorder(),
      HomeIconShape.squircle => RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(side * 0.38),
        ),
      HomeIconShape.rounded => RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(side * 0.22),
        ),
      HomeIconShape.flower => const FlowerBorder(),
    };

/// A soft scalloped "cookie" — one of Material 3 Expressive's shape-library
/// outlines — as a [ShapeBorder]: [lobes] gentle bumps around a circle, each
/// [depth] (a fraction of the radius) deep.
class FlowerBorder extends OutlinedBorder {
  const FlowerBorder({super.side, this.lobes = 8, this.depth = 0.085});

  final int lobes;
  final double depth;

  Path _path(Rect rect) {
    final c = rect.center;
    final r = rect.shortestSide / 2;
    final base = r * (1 - depth);
    final amp = r * depth;
    const steps = 160;
    final path = Path();
    for (var i = 0; i <= steps; i++) {
      final a = (i / steps) * 2 * math.pi - math.pi / 2;
      final rr = base + amp * math.cos(lobes * a);
      final p = Offset(c.dx + rr * math.cos(a), c.dy + rr * math.sin(a));
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    return path..close();
  }

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => _path(rect);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      _path(rect.deflate(side.strokeInset));

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.strokeInset);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none) return;
    canvas.drawPath(_path(rect), side.toPaint());
  }

  @override
  ShapeBorder scale(double t) =>
      FlowerBorder(side: side.scale(t), lobes: lobes, depth: depth);

  @override
  FlowerBorder copyWith({BorderSide? side}) =>
      FlowerBorder(side: side ?? this.side, lobes: lobes, depth: depth);

  @override
  bool operator ==(Object other) =>
      other is FlowerBorder &&
      other.side == side &&
      other.lobes == lobes &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(side, lobes, depth);
}
