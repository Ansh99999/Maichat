import 'package:flutter/material.dart';

import '../services/storage_report.dart';

/// The segmented "what's using space" bar at the top of the Storage screen.
///
/// One rounded track with a coloured segment per non-empty category, widths in
/// proportion to bytes, a 2px surface gap between fills, and a minimum sliver so
/// a tiny-but-present category never vanishes. Colour follows the category (see
/// [storageColor]) and the segments draw in the fixed category order, so the bar
/// never repaints when the sort of the list below changes. It grows from empty
/// on first layout — the one bit of motion the Material-You brief asks for.
class StorageBar extends StatelessWidget {
  const StorageBar({
    super.key,
    required this.segments,
    required this.total,
    this.height = 16,
  });

  /// Non-empty categories, already in the fixed enum order.
  final List<StorageCategoryUsage> segments;
  final int total;
  final double height;

  static const double _gap = 2;
  static const double _minSegment = 8;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;
    final track = scheme.surfaceContainerHighest;

    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: track,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final widths =
                _segmentWidths(constraints.maxWidth, segments, total);
            return TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 650),
              curve: Curves.easeOutCubic,
              builder: (context, t, _) {
                return Row(
                  children: [
                    for (var i = 0; i < segments.length; i++) ...[
                      if (i > 0) SizedBox(width: _gap * t),
                      SizedBox(
                        width: widths[i] * t,
                        height: height,
                        child: ColoredBox(
                          color:
                              storageColor(segments[i].category, brightness),
                        ),
                      ),
                    ],
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Pixel width per segment: proportional to bytes, but never below a visible
  /// sliver. The deficit from bumping tiny segments is taken off the largest one
  /// so the row still fits.
  static List<double> _segmentWidths(
    double full,
    List<StorageCategoryUsage> segments,
    int total,
  ) {
    final n = segments.length;
    if (n == 0 || total <= 0) return List<double>.filled(n, 0);
    final avail = (full - _gap * (n - 1)).clamp(0.0, full);
    final widths = [
      for (final s in segments) avail * (s.bytes / total),
    ];
    if (avail <= _minSegment * n) return widths; // too tight to protect slivers

    var deficit = 0.0;
    for (var i = 0; i < n; i++) {
      if (widths[i] > 0 && widths[i] < _minSegment) {
        deficit += _minSegment - widths[i];
        widths[i] = _minSegment;
      }
    }
    if (deficit > 0) {
      var largest = 0;
      for (var i = 1; i < n; i++) {
        if (widths[i] > widths[largest]) largest = i;
      }
      widths[largest] = (widths[largest] - deficit).clamp(_minSegment, avail);
    }
    return widths;
  }
}

/// The coloured-dot legend under the bar: one chip per non-empty category. Text
/// carries the identity, so the segment colour never has to be told apart alone.
class StorageLegend extends StatelessWidget {
  const StorageLegend({super.key, required this.segments});

  final List<StorageCategoryUsage> segments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = theme.brightness;
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (final s in segments)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: storageColor(s.category, brightness),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                s.category.label,
                style: theme.textTheme.labelMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
      ],
    );
  }
}
