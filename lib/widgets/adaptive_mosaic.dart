import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// An item's card, given its allocated width and a callback for a ratio learned
/// after the first image decode.
typedef AdaptiveMosaicItemBuilder<T> =
    Widget Function(
      BuildContext context,
      T item,
      double width,
      ValueChanged<double> onRatioResolved,
    );

/// A source-ordered, lazy masonry. Ordinary and portrait art occupies one
/// logical slot; sufficiently wide art occupies two, becoming full-width on a
/// phone's usual two-slot layout.
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

  bool _isWide(double? ratio) => ratio != null && ratio >= widget.wideRatio;

  int _spanOf(T item) => _isWide(_ratioOf(item)) ? 2 : 1;

  void _onRatio(T item, double ratio) {
    if (!ratio.isFinite || ratio <= 0) return;
    final key = widget.itemKey(item);
    final wasWide = _isWide(_ratioOf(item));
    _resolvedRatios[key] = _ResolvedRatio(widget.imageKey(item), ratio);
    if (wasWide == _isWide(ratio) || _rebuildQueued) return;
    _rebuildQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildQueued = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final indexByKey = <Key, int>{};
    final entries = <_MasonryEntry>[];
    for (var index = 0; index < widget.items.length; index++) {
      final item = widget.items[index];
      final key = widget.itemKey(item);
      indexByKey[ValueKey(key)] = index;
      entries.add(_MasonryEntry(key, widget.imageKey(item), _spanOf(item)));
    }
    return _MasonrySliver(
      delegate: SliverChildBuilderDelegate(
        (context, index) {
          final item = widget.items[index];
          return KeyedSubtree(
            key: ValueKey(widget.itemKey(item)),
            child: LayoutBuilder(
              builder: (context, constraints) => widget.itemBuilder(
                context,
                item,
                constraints.maxWidth,
                (ratio) => _onRatio(item, ratio),
              ),
            ),
          );
        },
        childCount: widget.items.length,
        findChildIndexCallback: (key) => indexByKey[key],
      ),
      entries: entries,
      columns: widget.columns,
      maxCrossAxisExtent: widget.maxCrossAxisExtent,
      mainAxisSpacing: widget.mainAxisSpacing,
      crossAxisSpacing: widget.crossAxisSpacing,
    );
  }
}

class _MasonryEntry {
  const _MasonryEntry(this.itemKey, this.imageKey, this.span);

  final Object itemKey;
  final Object imageKey;
  final int span;

  @override
  bool operator ==(Object other) =>
      other is _MasonryEntry &&
      other.itemKey == itemKey &&
      other.imageKey == imageKey &&
      other.span == span;

  @override
  int get hashCode => Object.hash(itemKey, imageKey, span);
}

class _MasonrySliver extends SliverMultiBoxAdaptorWidget {
  const _MasonrySliver({
    required super.delegate,
    required this.entries,
    required this.columns,
    required this.maxCrossAxisExtent,
    required this.mainAxisSpacing,
    required this.crossAxisSpacing,
  });

  final List<_MasonryEntry> entries;
  final int? columns;
  final double? maxCrossAxisExtent;
  final double mainAxisSpacing;
  final double crossAxisSpacing;

  @override
  RenderSliverMultiBoxAdaptor createRenderObject(BuildContext context) {
    final element = context as SliverMultiBoxAdaptorElement;
    return _RenderMasonrySliver(
      childManager: element,
      entries: entries,
      requestedColumns: columns,
      maxCrossAxisExtent: maxCrossAxisExtent,
      mainAxisSpacing: mainAxisSpacing,
      crossAxisSpacing: crossAxisSpacing,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderMasonrySliver renderObject,
  ) {
    renderObject
      ..entries = entries
      ..requestedColumns = columns
      ..maxCrossAxisExtent = maxCrossAxisExtent
      ..mainAxisSpacing = mainAxisSpacing
      ..crossAxisSpacing = crossAxisSpacing;
  }
}

class _MasonryParentData extends SliverMultiBoxAdaptorParentData {
  double crossAxisOffset = 0;
}

class _MasonryGeometry {
  const _MasonryGeometry({
    required this.mainAxisOffset,
    required this.crossAxisOffset,
    required this.width,
    required this.height,
    required this.frontiers,
    required this.coveredExtent,
    required this.maxTrailingExtent,
    required this.maxMeasuredHeight,
  });

  final double mainAxisOffset;
  final double crossAxisOffset;
  final double width;
  final double height;
  final List<double> frontiers;
  final double coveredExtent;
  final double maxTrailingExtent;
  final double maxMeasuredHeight;

  double get trailingOffset => mainAxisOffset + height;
}

class _RenderMasonrySliver extends RenderSliverMultiBoxAdaptor {
  _RenderMasonrySliver({
    required RenderSliverBoxChildManager childManager,
    required List<_MasonryEntry> entries,
    required int? requestedColumns,
    required double? maxCrossAxisExtent,
    required double mainAxisSpacing,
    required double crossAxisSpacing,
  }) : this._(
         childManager: childManager,
         entries: entries,
         requestedColumns: requestedColumns,
         maxCrossAxisExtent: maxCrossAxisExtent,
         mainAxisSpacing: mainAxisSpacing,
         crossAxisSpacing: crossAxisSpacing,
       );

  _RenderMasonrySliver._({
    required super.childManager,
    required this._entries,
    required this._requestedColumns,
    required this._maxCrossAxisExtent,
    required this._mainAxisSpacing,
    required this._crossAxisSpacing,
  });

  List<_MasonryEntry> _entries;
  int? _requestedColumns;
  double? _maxCrossAxisExtent;
  double _mainAxisSpacing;
  double _crossAxisSpacing;
  int _columns = 1;
  final List<_MasonryGeometry> _cache = <_MasonryGeometry>[];
  double? _crossAxisExtent;
  AxisDirection? _crossAxisDirection;
  int? _dirtyFrom;
  double _lastEstimatedExtent = 0;

  set entries(List<_MasonryEntry> value) {
    if (identical(_entries, value)) return;
    var common = math.min(_entries.length, value.length);
    for (var index = 0; index < common; index++) {
      if (_entries[index] != value[index]) {
        common = index;
        break;
      }
    }
    final changed = common < _entries.length || common < value.length;
    final oldLength = _entries.length;
    _entries = value;
    if (!changed) return;
    if (common < oldLength) {
      // An estimate derived from removed/replaced children is no longer
      // conservative; it would leave a blank scroll range until every surviving
      // tile was measured. Pure appends can safely retain the previous floor.
      _lastEstimatedExtent = 0;
    }
    if (common < _cache.length) {
      _dirtyFrom = _dirtyFrom == null ? common : math.min(_dirtyFrom!, common);
      _truncateCache(common);
    }
    markNeedsLayout();
  }

  set requestedColumns(int? value) {
    if (_requestedColumns == value) return;
    _requestedColumns = value;
    _invalidateAll();
  }

  set maxCrossAxisExtent(double? value) {
    if (_maxCrossAxisExtent == value) return;
    _maxCrossAxisExtent = value;
    _invalidateAll();
  }

  set mainAxisSpacing(double value) {
    if (_mainAxisSpacing == value) return;
    _mainAxisSpacing = value;
    _invalidateAll();
  }

  set crossAxisSpacing(double value) {
    if (_crossAxisSpacing == value) return;
    _crossAxisSpacing = value;
    _invalidateAll();
  }

  void _invalidateAll() {
    _dirtyFrom = 0;
    _clearCache();
    _lastEstimatedExtent = 0;
    markNeedsLayout();
  }

  void _clearCache() => _cache.clear();

  void _truncateCache(int length) {
    if (_cache.length > length) {
      _cache.removeRange(length, _cache.length);
    }
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! _MasonryParentData) {
      child.parentData = _MasonryParentData();
    }
  }

  @override
  double childCrossAxisPosition(RenderBox child) =>
      (child.parentData! as _MasonryParentData).crossAxisOffset;

  double _slotWidth(SliverConstraints constraints) =>
      (constraints.crossAxisExtent - _crossAxisSpacing * (_columns - 1)) /
      _columns;

  int _spanAt(int index) =>
      math.min(math.max(_entries[index].span, 1), _columns);

  double _itemWidth(SliverConstraints constraints, int index) {
    final span = _spanAt(index);
    return _slotWidth(constraints) * span + _crossAxisSpacing * (span - 1);
  }

  List<double> _frontiersBefore(int index) => index == 0
      ? List<double>.filled(_columns, 0)
      : List<double>.of(_cache[index - 1].frontiers);

  _MasonryGeometry _place(
    SliverConstraints constraints,
    int index,
    double height,
  ) {
    final frontiers = _frontiersBefore(index);
    final span = _spanAt(index);
    var bestLane = 0;
    var bestTop = double.infinity;
    for (var lane = 0; lane <= _columns - span; lane++) {
      var top = frontiers[lane];
      for (var offset = 1; offset < span; offset++) {
        top = math.max(top, frontiers[lane + offset]);
      }
      if (top < bestTop) {
        bestTop = top;
        bestLane = lane;
      }
    }
    final slotWidth = _slotWidth(constraints);
    final width = slotWidth * span + _crossAxisSpacing * (span - 1);
    final logicalCrossOffset = bestLane * (slotWidth + _crossAxisSpacing);
    final crossOffset = constraints.crossAxisDirection == AxisDirection.left
        ? constraints.crossAxisExtent - logicalCrossOffset - width
        : logicalCrossOffset;
    final trailingOffset = bestTop + height;
    final next = trailingOffset + _mainAxisSpacing;
    for (var offset = 0; offset < span; offset++) {
      frontiers[bestLane + offset] = next;
    }
    final previous = index == 0 ? null : _cache[index - 1];
    return _MasonryGeometry(
      mainAxisOffset: bestTop,
      crossAxisOffset: crossOffset,
      width: width,
      height: height,
      frontiers: frontiers,
      coveredExtent: frontiers.reduce(math.min),
      maxTrailingExtent: math.max(
        previous?.maxTrailingExtent ?? 0,
        trailingOffset,
      ),
      maxMeasuredHeight: math.max(previous?.maxMeasuredHeight ?? 0, height),
    );
  }

  void _mirrorCache(SliverConstraints constraints) {
    for (var index = 0; index < _cache.length; index++) {
      final geometry = _cache[index];
      _cache[index] = _MasonryGeometry(
        mainAxisOffset: geometry.mainAxisOffset,
        crossAxisOffset:
            constraints.crossAxisExtent -
            geometry.crossAxisOffset -
            geometry.width,
        width: geometry.width,
        height: geometry.height,
        frontiers: geometry.frontiers,
        coveredExtent: geometry.coveredExtent,
        maxTrailingExtent: geometry.maxTrailingExtent,
        maxMeasuredHeight: geometry.maxMeasuredHeight,
      );
    }
  }

  BoxConstraints _constraintsFor(SliverConstraints constraints, int index) =>
      constraints.asBoxConstraints(
        crossAxisExtent: _itemWidth(constraints, index),
      );

  void _applyGeometry(RenderBox child, _MasonryGeometry geometry) {
    final data = child.parentData! as _MasonryParentData;
    data.layoutOffset = geometry.mainAxisOffset;
    data.crossAxisOffset = geometry.crossAxisOffset;
  }

  double _knownExtent() =>
      _cache.isEmpty ? 0 : math.max(0, _cache.last.maxTrailingExtent);

  double _coveredExtent() => _cache.isEmpty ? 0 : _cache.last.coveredExtent;

  double _estimatedExtent(SliverConstraints constraints) {
    final known = _knownExtent();
    if (_cache.isEmpty || _cache.length >= _entries.length) {
      _lastEstimatedExtent = known;
      return known;
    }
    final remaining = _entries.length - _cache.length;
    final perItem = math.max(
      _cache.last.maxMeasuredHeight,
      constraints.viewportMainAxisExtent,
    );
    final estimate = known + remaining * (perItem + _mainAxisSpacing);
    _lastEstimatedExtent = math.max(_lastEstimatedExtent, estimate);
    return math.max(known, _lastEstimatedExtent);
  }

  int _firstIndexFor(double cacheStart) {
    var low = 0;
    var high = _cache.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_cache[middle].maxTrailingExtent < cacheStart) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low;
  }

  int _lastIndexFor(double cacheEnd) {
    var low = 0;
    var high = _cache.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_cache[middle].coveredExtent < cacheEnd) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return math.min(low, _cache.length - 1);
  }

  void _extendCache(SliverConstraints constraints, double cacheEnd) {
    while (_cache.length < _entries.length &&
        (_cache.isEmpty || _coveredExtent() < cacheEnd)) {
      final index = _cache.length;
      RenderBox? child;
      if (firstChild == null) {
        if (!addInitialChild(index: index)) break;
        child = firstChild;
      } else {
        final lastIndex = indexOf(lastChild!);
        if (lastIndex == index) {
          child = lastChild;
        } else if (lastIndex == index - 1) {
          child = insertAndLayoutChild(
            _constraintsFor(constraints, index),
            after: lastChild,
            parentUsesSize: true,
          );
        } else {
          collectGarbage(childCount, 0);
          if (!addInitialChild(index: index)) break;
          child = firstChild;
        }
      }
      if (child == null) break;
      child.layout(_constraintsFor(constraints, index), parentUsesSize: true);
      final placed = _place(constraints, index, paintExtentOf(child));
      _cache.add(placed);
      _applyGeometry(child, placed);
    }
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);

    final nextColumns =
        _requestedColumns ??
        math.max(
          1,
          ((constraints.crossAxisExtent + _crossAxisSpacing) /
                  (_maxCrossAxisExtent! + _crossAxisSpacing))
              .ceil(),
        );
    if (_crossAxisExtent != constraints.crossAxisExtent ||
        _columns != nextColumns) {
      _crossAxisExtent = constraints.crossAxisExtent;
      _columns = nextColumns;
      _crossAxisDirection = constraints.crossAxisDirection;
      _dirtyFrom = 0;
      _clearCache();
      _lastEstimatedExtent = 0;
    } else if (_crossAxisDirection != constraints.crossAxisDirection) {
      _crossAxisDirection = constraints.crossAxisDirection;
      _mirrorCache(constraints);
    }
    _truncateCache(_entries.length);

    final dirtyFrom = _dirtyFrom;
    if (dirtyFrom != null && firstChild != null) {
      final firstLive = indexOf(firstChild!);
      final lastLive = indexOf(lastChild!);
      if (dirtyFrom <= lastLive && dirtyFrom >= firstLive) {
        collectGarbage(0, childCount);
      }
    }
    _dirtyFrom = null;

    var invalidFrom = _cache.length;
    RenderBox? liveChild = firstChild;
    while (liveChild != null) {
      final index = indexOf(liveChild);
      if (index < invalidFrom &&
          index < _cache.length &&
          (liveChild.size.width - _itemWidth(constraints, index)).abs() >
              1e-10) {
        invalidFrom = index;
      }
      liveChild = childAfter(liveChild);
    }
    _truncateCache(invalidFrom);

    if (_entries.isEmpty) {
      collectGarbage(childCount, 0);
      geometry = SliverGeometry.zero;
      childManager.didFinishLayout();
      return;
    }

    final cacheStart = constraints.scrollOffset + constraints.cacheOrigin;
    final cacheEnd = cacheStart + constraints.remainingCacheExtent;

    if (_cache.length < _entries.length &&
        firstChild != null &&
        indexOf(lastChild!) >= _cache.length) {
      collectGarbage(0, childCount);
    }

    _extendCache(constraints, cacheEnd);

    var firstIndex = _firstIndexFor(cacheStart);
    if (firstIndex >= _cache.length) {
      firstIndex = math.max(0, _cache.length - 1);
    }
    var lastIndex = math.max(firstIndex, _lastIndexFor(cacheEnd));

    if (firstChild != null) {
      collectGarbage(
        calculateLeadingGarbage(firstIndex: firstIndex),
        calculateTrailingGarbage(lastIndex: lastIndex),
      );
    } else {
      collectGarbage(0, 0);
    }

    if (firstChild == null) {
      if (!addInitialChild(
        index: firstIndex,
        layoutOffset: _cache[firstIndex].mainAxisOffset,
      )) {
        geometry = SliverGeometry.zero;
        childManager.didFinishLayout();
        return;
      }
    }
    while (indexOf(firstChild!) > firstIndex) {
      final index = indexOf(firstChild!) - 1;
      final leading = insertAndLayoutLeadingChild(
        _constraintsFor(constraints, index),
        parentUsesSize: true,
      );
      if (leading == null) break;
      _applyGeometry(leading, _cache[index]);
    }

    RenderBox? child = firstChild;
    var heightChanged = false;
    while (child != null) {
      final index = indexOf(child);
      final oldHeight = index < _cache.length ? _cache[index].height : null;
      child.layout(_constraintsFor(constraints, index), parentUsesSize: true);
      if (oldHeight == null ||
          (paintExtentOf(child) - oldHeight).abs() > 1e-10) {
        _truncateCache(index);
        final placed = _place(constraints, index, paintExtentOf(child));
        _cache.add(placed);
        heightChanged = true;
      }
      _applyGeometry(child, _cache[index]);
      child = childAfter(child);
    }

    if (heightChanged) {
      _extendCache(constraints, cacheEnd);
      firstIndex = _firstIndexFor(cacheStart);
      if (firstIndex >= _cache.length) {
        firstIndex = math.max(0, _cache.length - 1);
      }
      lastIndex = math.max(firstIndex, _lastIndexFor(cacheEnd));
    }

    child = lastChild;
    while (child != null && indexOf(child) < lastIndex) {
      final index = indexOf(child) + 1;
      var next = childAfter(child);
      if (next == null || indexOf(next) != index) {
        next = insertAndLayoutChild(
          _constraintsFor(constraints, index),
          after: child,
          parentUsesSize: true,
        );
        if (next == null) break;
      } else {
        next.layout(_constraintsFor(constraints, index), parentUsesSize: true);
      }
      if (index >= _cache.length) {
        _cache.add(_place(constraints, index, paintExtentOf(next)));
      } else if ((paintExtentOf(next) - _cache[index].height).abs() > 1e-10) {
        _truncateCache(index);
        _cache.add(_place(constraints, index, paintExtentOf(next)));
      }
      _applyGeometry(next, _cache[index]);
      child = next;
    }

    final extent = _estimatedExtent(constraints);
    final knownExtent = _knownExtent();
    final paintExtent = calculatePaintOffset(
      constraints,
      from: 0,
      to: knownExtent,
    );
    final cacheExtent = calculateCacheOffset(
      constraints,
      from: 0,
      to: knownExtent,
    );
    geometry = SliverGeometry(
      scrollExtent: extent,
      paintExtent: paintExtent,
      cacheExtent: cacheExtent,
      maxPaintExtent: extent,
      hasVisualOverflow:
          extent > constraints.remainingPaintExtent ||
          constraints.scrollOffset > 0 ||
          constraints.overlap != 0,
    );
    if (_cache.length == _entries.length) childManager.setDidUnderflow(true);
    childManager.didFinishLayout();
  }
}

class _ResolvedRatio {
  const _ResolvedRatio(this.imageKey, this.ratio);

  final Object imageKey;
  final double ratio;
}
