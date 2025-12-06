import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

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
        // Defer markNeedsLayout() to next frame using endOfFrame pattern
        // This ensures it runs after current frame completes, avoiding parentDataDirty assertion
        SchedulerBinding.instance.endOfFrame.then((_) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (targetParent.attached) {
              targetParent.markNeedsLayout();
            }
          });
        });
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
    this.onLayoutComplete,
  }) : super(delegate: delegate);

  final PinterestGridDelegate gridDelegate;

  /// レイアウト完了時に呼ばれるコールバック（ミニマップ用）
  final OnLayoutComplete? onLayoutComplete;

  @override
  RenderSliverPinterestGrid createRenderObject(BuildContext context) {
    return RenderSliverPinterestGrid(
      childManager: context as SliverMultiBoxAdaptorElement,
      columnCount: gridDelegate.columnCount,
      gap: gridDelegate.gap,
      onLayoutComplete: onLayoutComplete,
    );
  }

  @override
  void updateRenderObject(
    BuildContext context,
    RenderSliverPinterestGrid renderObject,
  ) {
    renderObject
      ..columnCount = gridDelegate.columnCount
      ..gap = gridDelegate.gap
      ..onLayoutComplete = onLayoutComplete;
  }
}

/// カードのレイアウト情報を報告するコールバック
typedef OnLayoutComplete = void Function(Map<int, Rect> childRects);

/// Render object powering [PinterestSliverGrid].
class RenderSliverPinterestGrid extends RenderSliverMultiBoxAdaptor {
  RenderSliverPinterestGrid({
    required RenderSliverBoxChildManager childManager,
    required int columnCount,
    required double gap,
    this.onLayoutComplete,
  })  : _columnCount = columnCount,
        _gap = gap,
        super(childManager: childManager);

  /// レイアウト完了時に呼ばれるコールバック（ミニマップ用）
  OnLayoutComplete? onLayoutComplete;

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

    // debugPrint(
    //   '[ScrollDebug] sliver layout start: '
    //   'scrollOffset=${constraints.scrollOffset.toStringAsFixed(1)} '
    //   'cacheOrigin=${constraints.cacheOrigin.toStringAsFixed(1)} '
    //   'remainingExtent=${constraints.remainingPaintExtent.toStringAsFixed(1)} '
    //   'crossAxisExtent=${crossAxisExtent.toStringAsFixed(1)} '
    //   'columnWidth=${columnWidth.toStringAsFixed(1)} '
    //   'columns=$columnCount',
    // );

    if (columnWidth <= 0 || columnCount <= 0) {
      geometry = SliverGeometry.zero;
      childManager.didFinishLayout();
      // debugPrint(
      //     '[ScrollDebug] sliver layout abort: columnWidth<=0 or columnCount<=0');
      return;
    }

    final scrollOffset = constraints.scrollOffset + constraints.cacheOrigin;
    final remainingExtent = constraints.remainingCacheExtent;
    final targetEndScrollOffset = scrollOffset + remainingExtent;

    final columnHeights = List<double>.filled(columnCount, 0);
    final double childCrossAxisStride = columnWidth + gap;

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

      // debugPrint(
      //   '[ScrollDebug] child placed: '
      //   'span=$span start=$bestStart '
      //   'layoutOffset=${parentData.layoutOffset?.toStringAsFixed(1)} '
      //   'paintExtent=${paintedChildSize.toStringAsFixed(1)} '
      //   'scrollOffset=${constraints.scrollOffset.toStringAsFixed(1)} '
      //   'columnHeights=${columnHeights.map((h) => h.toStringAsFixed(1)).join('/')}',
      // );
    }

    // Layout visible children.
    RenderBox? trailingChildWithLayout;
    RenderBox? leadingChildWithLayout;

    while (child != null) {
      // CRITICAL: Skip children with invalid parentData
      // This can happen during directory switch when old children are being replaced
      final rawParentData = child.parentData;
      if (rawParentData is! PinterestGridParentData) {
        child = childAfter(child);
        continue;
      }
      final childParentData = rawParentData;
      placeChild(child, childParentData);

      final double layoutOffset = childParentData.layoutOffset ?? 0;
      final double paintExtent = childParentData.paintExtent;
      final double childEnd = layoutOffset + paintExtent;

      if (childEnd >= scrollOffset && leadingChildWithLayout == null) {
        leadingChildWithLayout = child;
      }
      trailingChildWithLayout = child;

      // Masonryグリッドでは次のカードは必ず最も低いカラムに配置される
      // 全カラムの最小高さがtargetを超えたら、全カラムがビューポートをカバー済み
      final double minColumnHeight = columnHeights.reduce(math.min);
      if (minColumnHeight > targetEndScrollOffset) {
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
    // CRITICAL: Check hasSize before calling paintExtentOf to avoid assertion failure
    // during directory switch when old children may not have been laid out yet
    while (leadingChildWithLayout != null &&
        leadingChildWithLayout.hasSize &&
        childScrollOffset(leadingChildWithLayout) != null &&
        childScrollOffset(leadingChildWithLayout)! +
                paintExtentOf(leadingChildWithLayout) <
            scrollOffset) {
      leadingGarbage++;
      // debugPrint(
      //   '[ScrollDebug] collect leading: '
      //   'childOffset=${childScrollOffset(leadingChildWithLayout)!.toStringAsFixed(1)} '
      //   'paintExtent=${paintExtentOf(leadingChildWithLayout).toStringAsFixed(1)} '
      //   'scrollOffset=${scrollOffset.toStringAsFixed(1)}',
      // );
      leadingChildWithLayout = childAfter(leadingChildWithLayout);
    }

    // Drop trailing offscreen children.
    // CRITICAL: Check hasSize before accessing child properties
    while (trailingChildWithLayout != null &&
        trailingChildWithLayout.hasSize &&
        childScrollOffset(trailingChildWithLayout) != null &&
        childScrollOffset(trailingChildWithLayout)! > targetEndScrollOffset) {
      trailingGarbage++;
      // debugPrint(
      //   '[ScrollDebug] collect trailing: '
      //   'childOffset=${childScrollOffset(trailingChildWithLayout)!.toStringAsFixed(1)} '
      //   'targetEnd=${targetEndScrollOffset.toStringAsFixed(1)}',
      // );
      trailingChildWithLayout = childBefore(trailingChildWithLayout);
    }

    if (leadingGarbage > 0 || trailingGarbage > 0) {
      collectGarbage(leadingGarbage, trailingGarbage);
      // debugPrint(
      //   '[ScrollDebug] collect summary: leading=$leadingGarbage trailing=$trailingGarbage '
      //   'children=${_describeChildren()}',
      // );
    }

    double maxPaintedExtent = 0;
    double maxScrollExtent = 0;
    RenderBox? paintChild = firstChild;
    RenderBox? leadingTrackedChild;
    RenderBox? trailingTrackedChild;
    while (paintChild != null) {
      // CRITICAL: Skip children without valid parentData or layoutOffset
      // This can happen during directory switch when old children are being replaced
      final parentData = paintChild.parentData;
      if (parentData is! PinterestGridParentData ||
          parentData.layoutOffset == null) {
        paintChild = childAfter(paintChild);
        continue;
      }
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

    final double viewportExtent = constraints.viewportMainAxisExtent;
    double bottomChildPaintExtent = 0;
    if (trailingTrackedChild != null) {
      final trailingData = trailingTrackedChild.parentData;
      if (trailingData is PinterestGridParentData) {
        bottomChildPaintExtent = trailingData.paintExtent;
      }
    }
    final double extraExtent =
        math.max(0, viewportExtent - (bottomChildPaintExtent * 2));
    final double extendedScrollExtent = maxScrollExtent + extraExtent;
    final double extendedPaintExtentUpperBound = maxPaintedExtent + extraExtent;

    // 最初の子のlayoutOffsetを取得（Flutter標準スリバーのパターンに準拠）
    final double leadingScrollOffset = (firstChild != null &&
            childScrollOffset(firstChild!) != null)
        ? childScrollOffset(firstChild!)!
        : 0.0;

    // toパラメータがビューポート終了以上であることを保証
    // カードサイズがバラバラの場合でもビューポート全体がペイントされる
    final double viewportEnd =
        constraints.scrollOffset + constraints.remainingPaintExtent;
    final double paintExtent = calculatePaintOffset(
      constraints,
      from: math.min(constraints.scrollOffset, leadingScrollOffset),
      to: math.max(extendedPaintExtentUpperBound, viewportEnd),
    );

    final double cacheExtent = calculateCacheOffset(
      constraints,
      from: leadingScrollOffset,
      to: maxScrollExtent,
    );

    final double targetEndScrollOffsetForPaint =
        constraints.scrollOffset + constraints.remainingPaintExtent;

    final computedGeometry = SliverGeometry(
      scrollExtent: extendedScrollExtent,
      paintExtent: paintExtent,
      cacheExtent: cacheExtent,
      maxPaintExtent: extendedPaintExtentUpperBound,
      hasVisualOverflow: maxPaintedExtent > targetEndScrollOffsetForPaint ||
          constraints.scrollOffset > 0.0,
    );
    geometry = computedGeometry;

    childManager.didFinishLayout();

    // レイアウト完了後、ミニマップ用に位置データを報告
    if (onLayoutComplete != null) {
      final childRects = <int, Rect>{};
      for (var child = firstChild; child != null; child = childAfter(child)) {
        final pd = child.parentData;
        if (pd is PinterestGridParentData && pd.index != null) {
          final int span = pd.columnSpan.clamp(1, columnCount);
          final double totalGaps = gap * (columnCount - 1);
          final double columnWidthLocal =
              columnCount == 0 ? 0 : (constraints.crossAxisExtent - totalGaps) / columnCount;
          final double childWidth = columnWidthLocal * span + gap * (span - 1);
          childRects[pd.index!] = Rect.fromLTWH(
            pd.crossAxisOffset,
            pd.layoutOffset ?? 0,
            childWidth,
            pd.paintExtent,
          );
        }
      }
      onLayoutComplete!(childRects);
    }
  }

  @override
  double childCrossAxisPosition(RenderBox child) {
    final parentData = child.parentData;
    if (parentData is! PinterestGridParentData) {
      return 0;
    }
    return parentData.crossAxisOffset;
  }

  @override
  double childMainAxisPosition(RenderBox child) {
    final parentData = child.parentData;
    if (parentData is! PinterestGridParentData) {
      return 0;
    }
    return (parentData.layoutOffset ?? 0) - constraints.scrollOffset;
  }
}
