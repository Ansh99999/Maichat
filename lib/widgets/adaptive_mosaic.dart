import 'dart:math' as math;

import 'package:flutter/material.dart';

/// An item's card, given its allocated width and a callback for a ratio learned
/// after the first image decode.
typedef AdaptiveMosaicItemBuilder<T> =
    Widget Function(
      BuildContext context,
      T item,
      double width,
      ValueChanged<double> onRatioResolved,
    );

/// A source-ordered, lazy mosaic. Ordinary and portrait art occupies one logical
/// slot; sufficiently wide art occupies two, becoming full-width on a phone's
/// usual two-slot layout.
class AdaptiveMosaicSliver<T> extends StatefulWidget {
  const AdaptiveMosaicSliver({
    super.key,
    required this.items,
    required this.itemKey,
    required this.imageKey,
    required this.ratioOf,
    required this.itemBuilder,
    this.columns,
    this.maxCrossAxisExtent,
    this.mainAxisSpacing = 0,
    this.crossAxisSpacing = 0,
    this.wideRatio = 1.25,
  }) : assert(columns != null || maxCrossAxisExtent != null),
       assert(columns == null || columns > 0),
       assert(maxCrossAxisExtent == null || maxCrossAxisExtent > 0);

  final List<T> items;
  final Object Function(T item) itemKey;

  /// Identity of the image whose ratio controls the item's span. This may differ
  /// from [itemKey] when a record keeps its id but replaces its picture.
  final Object Function(T item) imageKey;

  final double? Function(T item) ratioOf;
  final AdaptiveMosaicItemBuilder<T> itemBuilder;
  final int? columns;
  final double? maxCrossAxisExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;
  final double wideRatio;

  @override
  State<AdaptiveMosaicSliver<T>> createState() =>
      _AdaptiveMosaicSliverState<T>();
}

class _AdaptiveMosaicSliverState<T> extends State<AdaptiveMosaicSliver<T>> {
  final Map<Object, _ResolvedRatio> _resolvedRatios =
      <Object, _ResolvedRatio>{};
  bool _rebuildQueued = false;

  double? _ratioOf(T item) {
    final resolved = _resolvedRatios[widget.itemKey(item)];
    return resolved != null && resolved.imageKey == widget.imageKey(item)
        ? resolved.ratio
        : widget.ratioOf(item);
  }

  int _spanOf(T item, int columns) {
    if (columns == 1) return 1;
    final ratio = _ratioOf(item);
    return ratio != null && ratio >= widget.wideRatio ? 2 : 1;
  }

  void _onRatio(T item, int columns, double ratio) {
    if (!ratio.isFinite || ratio <= 0) return;
    final key = widget.itemKey(item);
    final oldSpan = _spanOf(item, columns);
    _resolvedRatios[key] = _ResolvedRatio(widget.imageKey(item), ratio);
    if (oldSpan == _spanOf(item, columns) || _rebuildQueued) return;
    _rebuildQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildQueued = false;
      if (mounted) setState(() {});
    });
  }

  List<List<T>> _rows(int columns) {
    final rows = <List<T>>[];
    var row = <T>[];
    var used = 0;
    for (final item in widget.items) {
      final span = math.min(_spanOf(item, columns), columns);
      if (row.isNotEmpty && used + span > columns) {
        rows.add(row);
        row = <T>[];
        used = 0;
      }
      row.add(item);
      used += span;
      if (used == columns) {
        rows.add(row);
        row = <T>[];
        used = 0;
      }
    }
    if (row.isNotEmpty) rows.add(row);
    return rows;
  }

  @override
  Widget build(BuildContext context) => SliverLayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.crossAxisExtent;
      final columns =
          widget.columns ??
          math.max(
            1,
            ((width + widget.crossAxisSpacing) /
                    (widget.maxCrossAxisExtent! + widget.crossAxisSpacing))
                .ceil(),
          );
      final slotWidth =
          (width - widget.crossAxisSpacing * (columns - 1)) / columns;
      final rows = _rows(columns);
      return SliverList.builder(
        itemCount: rows.length,
        itemBuilder: (context, rowIndex) {
          final row = rows[rowIndex];
          return Padding(
            padding: EdgeInsets.only(
              bottom: rowIndex == rows.length - 1 ? 0 : widget.mainAxisSpacing,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < row.length; i++) ...[
                  if (i > 0) SizedBox(width: widget.crossAxisSpacing),
                  Builder(
                    builder: (context) {
                      final item = row[i];
                      final span = math.min(_spanOf(item, columns), columns);
                      final itemWidth =
                          slotWidth * span +
                          widget.crossAxisSpacing * (span - 1);
                      return SizedBox(
                        key: ValueKey(widget.itemKey(item)),
                        width: itemWidth,
                        child: widget.itemBuilder(
                          context,
                          item,
                          itemWidth,
                          (ratio) => _onRatio(item, columns, ratio),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
          );
        },
      );
    },
  );
}

class _ResolvedRatio {
  const _ResolvedRatio(this.imageKey, this.ratio);

  final Object imageKey;
  final double ratio;
}
