import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Describes how a [PinterestGrid] should layout its children.
class PinterestGridDelegate {
  const PinterestGridDelegate({
    required this.columnCount,
    required this.gap,
  })  : assert(columnCount > 0),
        assert(gap >= 0);

  final int columnCount;
  final double gap;

  PinterestGridDelegate copyWith({int? columnCount, double? gap}) {
    return PinterestGridDelegate(
      columnCount: columnCount ?? this.columnCount,
      gap: gap ?? this.gap,
    );
  }
}

/// Parent data storing the layout information for a [PinterestGrid] child.
class PinterestGridParentData extends SliverMultiBoxAdaptorParentData {
  int columnSpan = 1;
  int columnStart = 0;
  double crossAxisOffset = 0;
  double paintExtent = 0;

  @override
  String toString() {
    return 'columnSpan=$columnSpan; columnStart=$columnStart; '
        'crossAxisOffset=$crossAxisOffset; ${super.toString()}';
  }
}

/// Wraps a widget with layout metadata for [PinterestSliverGrid].
class PinterestGridTile extends ParentDataWidget<PinterestGridParentData> {
  const PinterestGridTile({
    super.key,
    required this.span,
    required Widget child,
  })  : assert(span > 0),
        super(child: child);

  final int span;

  @override
  void applyParentData(RenderObject renderObject) {
    final parentData = renderObject.parentData;
    if (parentData is! PinterestGridParentData) {
      return;
    }
    if (parentData.columnSpan != span) {
      parentData.columnSpan = span;
      final targetParent = renderObject.parent;
      if (targetParent is RenderObject) {
        targetParent.markNeedsLayout();
      }
    }
  }

  @override
  Type get debugTypicalAncestorWidgetClass => PinterestSliverGrid;
}

/// A sliver that positions children in a Pinterest-like masonry grid where
/// each tile can span multiple columns.
class PinterestSliverGrid extends SliverMultiBoxAdaptorWidget {
  const PinterestSliverGrid({
    super.key,
    required SliverChildDelegate delegate,
    required this.gridDelegate,
  }) : super(delegate: delegate);

  final PinterestGridDelegate gridDelegate;

  @override
  RenderSliverPinterestGrid createRenderObject(BuildContext context) {
    return RenderSliverPinterestGrid(
      childManager: context as SliverMultiBoxAdaptorElement,
      columnCount: gridDelegate.columnCount,
      gap: gridDelegate.gap,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverPinterestGrid renderObject,
  ) {
    renderObject
      ..columnCount = gridDelegate.columnCount
      ..gap = gridDelegate.gap;
  }
}

class _ColumnState {
  _ColumnState(this.height);
  double height;
}

/// Render object powering [PinterestSliverGrid].
class RenderSliverPinterestGrid extends RenderSliverMultiBoxAdaptor {
  RenderSliverPinterestGrid({
    required RenderSliverBoxChildManager childManager,
    required int columnCount,
    required double gap,
  })  : _columnCount = columnCount,
        _gap = gap,
        super(childManager: childManager);

  int get columnCount => _columnCount;
  int _columnCount;
  set columnCount(int value) {
    assert(value > 0);
    if (_columnCount == value) {
      return;
    }
    _columnCount = value;
    markNeedsLayout();
  }

  double get gap => _gap;
  double _gap;
  set gap(double value) {
    if (_gap == value) {
      return;
    }
    _gap = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderObject child) {
    if (child.parentData is! PinterestGridParentData) {
      child.parentData = PinterestGridParentData();
    }
  }

  @override
  void performLayout() {
    childManager.didStartLayout();
    childManager.setDidUnderflow(false);

    final double crossAxisExtent = constraints.crossAxisExtent;
    final double totalGaps = gap * (columnCount - 1);
    final double columnWidth =
        columnCount == 0 ? 0 : (crossAxisExtent - totalGaps) / columnCount;

    debugPrint(
      '[ScrollDebug] sliver layout start: '
      'scrollOffset=${constraints.scrollOffset.toStringAsFixed(1)} '
      'cacheOrigin=${constraints.cacheOrigin.toStringAsFixed(1)} '
      'remainingExtent=${constraints.remainingPaintExtent.toStringAsFixed(1)} '
      'crossAxisExtent=${crossAxisExtent.toStringAsFixed(1)} '
      'columnWidth=${columnWidth.toStringAsFixed(1)} '
      'columns=$columnCount',
    );

    if (columnWidth <= 0 || columnCount <= 0) {
      geometry = SliverGeometry.zero;
      childManager.didFinishLayout();
      debugPrint(
          '[ScrollDebug] sliver layout abort: columnWidth<=0 or columnCount<=0');
      return;
    }

    final scrollOffset = constraints.scrollOffset + constraints.cacheOrigin;
    final remainingExtent = constraints.remainingCacheExtent;
    final targetEndScrollOffset = scrollOffset + remainingExtent;

    final columnHeights = List<double>.filled(columnCount, 0);
    final double childCrossAxisStride = columnWidth + gap;

    bool reachedEnd = false;
    int leadingGarbage = 0;
    int trailingGarbage = 0;

    RenderBox? child = firstChild;
    if (child == null) {
      if (!addInitialChild()) {
        geometry = SliverGeometry.zero;
        childManager.didFinishLayout();
        return;
      }
      child = firstChild;
    }

    void placeChild(RenderBox child, PinterestGridParentData parentData) {
      final int span = parentData.columnSpan.clamp(1, columnCount);
      int bestStart = 0;
      double bestOffset = double.infinity;

      const double epsilon = 0.001;
      for (int start = 0; start <= columnCount - span; start++) {
        double candidate = 0;
        for (int c = 0; c < span; c++) {
          candidate = math.max(candidate, columnHeights[start + c]);
        }
        if (candidate < bestOffset - epsilon) {
          bestOffset = candidate;
          bestStart = start;
        }
      }

      parentData.columnStart = bestStart;
      parentData.layoutOffset = bestOffset;
      parentData.crossAxisOffset =
          bestStart == 0 ? 0 : childCrossAxisStride * bestStart;

      final double childCrossAxisExtent = columnWidth * span + gap * (span - 1);
      final childConstraints = constraints.asBoxConstraints(
        crossAxisExtent: childCrossAxisExtent,
      );
      child.layout(childConstraints, parentUsesSize: true);

      final double paintedChildSize = paintExtentOf(child);
      final double targetEnd = bestOffset + paintedChildSize;

      for (int c = 0; c < span; c++) {
        columnHeights[bestStart + c] =
            targetEnd + (bestStart + c == columnCount - 1 ? 0 : gap);
      }

      parentData.paintExtent = paintedChildSize;
    }

    // Layout visible children.
    RenderBox? trailingChildWithLayout;
    RenderBox? leadingChildWithLayout;

    while (child != null) {
      final childParentData = child.parentData! as PinterestGridParentData;
      placeChild(child, childParentData);

      final double layoutOffset = childParentData.layoutOffset!;
      final double paintExtent = childParentData.paintExtent ?? 0;
      final double childEnd = layoutOffset + paintExtent;

      if (childEnd >= scrollOffset && leadingChildWithLayout == null) {
        leadingChildWithLayout = child;
      }
      trailingChildWithLayout = child;

      if (childEnd > targetEndScrollOffset) {
        reachedEnd = true;
        break;
      }

      child = childAfter(child);

      if (child == null) {
        child = insertAndLayoutChild(
          constraints.asBoxConstraints(crossAxisExtent: columnWidth),
          after: trailingChildWithLayout,
        );
      }
    }

    if (leadingChildWithLayout == null) {
      leadingChildWithLayout = firstChild;
    }

    // Drop leading offscreen children.
    while (leadingChildWithLayout != null &&
        childScrollOffset(leadingChildWithLayout) != null &&
        childScrollOffset(leadingChildWithLayout)! +
                paintExtentOf(leadingChildWithLayout) <
            scrollOffset) {
      leadingGarbage++;
      leadingChildWithLayout = childAfter(leadingChildWithLayout);
    }

    // Drop trailing offscreen children.
    while (trailingChildWithLayout != null &&
        childScrollOffset(trailingChildWithLayout) != null &&
        childScrollOffset(trailingChildWithLayout)! > targetEndScrollOffset) {
      trailingGarbage++;
      trailingChildWithLayout = childBefore(trailingChildWithLayout);
    }

    if (leadingGarbage > 0 || trailingGarbage > 0) {
      collectGarbage(leadingGarbage, trailingGarbage);
    }

    double maxPaintedExtent = 0;
    double maxScrollExtent = 0;
    RenderBox? paintChild = firstChild;
    RenderBox? leadingTrackedChild;
    RenderBox? trailingTrackedChild;
    while (paintChild != null) {
      final parentData = paintChild.parentData! as PinterestGridParentData;
      final double end = parentData.layoutOffset! + parentData.paintExtent;
      if (end > maxPaintedExtent) {
        maxPaintedExtent = end;
      }
      if (end > maxScrollExtent) {
        maxScrollExtent = end;
      }
      trailingTrackedChild = paintChild;
      leadingTrackedChild ??= paintChild;
      paintChild = childAfter(paintChild);
    }

    final computedGeometry = SliverGeometry(
      scrollExtent: maxScrollExtent,
      paintExtent: calculatePaintOffset(
        constraints,
        from: scrollOffset,
        to: maxPaintedExtent,
      ),
      maxPaintExtent: maxScrollExtent,
      hasVisualOverflow: maxPaintedExtent > constraints.remainingPaintExtent,
    );
    geometry = computedGeometry;

    if (leadingTrackedChild != null && trailingTrackedChild != null) {
      final leadingData =
          leadingTrackedChild.parentData! as PinterestGridParentData;
      final trailingData =
          trailingTrackedChild.parentData! as PinterestGridParentData;
      debugPrint(
        '[ScrollDebug] sliver layout done: '
        'geometry.scrollExtent=${computedGeometry.scrollExtent.toStringAsFixed(1)} '
        'geometry.paintExtent=${computedGeometry.paintExtent.toStringAsFixed(1)} '
        'leadingOffset=${leadingData.layoutOffset?.toStringAsFixed(1)} '
        'trailingOffset=${trailingData.layoutOffset?.toStringAsFixed(1)} '
        'lastPaintExtent=${trailingData.paintExtent.toStringAsFixed(1)} '
        'underflow=${computedGeometry.scrollExtent <= constraints.scrollOffset}',
      );
    } else {
      debugPrint(
        '[ScrollDebug] sliver layout done: no children '
        'geometry.scrollExtent=${computedGeometry.scrollExtent.toStringAsFixed(1)} '
        'geometry.paintExtent=${computedGeometry.paintExtent.toStringAsFixed(1)}',
      );
    }

    childManager.didFinishLayout();
  }

  @override
  double childCrossAxisPosition(RenderBox child) {
    final parentData = child.parentData! as PinterestGridParentData;
    return parentData.crossAxisOffset;
  }

  @override
  double childMainAxisPosition(RenderBox child) {
    final parentData = child.parentData! as PinterestGridParentData;
    return parentData.layoutOffset ?? 0;
  }
}
