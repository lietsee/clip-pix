import 'dart:math' as math;
import 'dart:ui';

import 'state/grid_layout_store.dart';

class GridLayoutLayoutEngine {
  GridLayoutLayoutEngine({LayoutSnapshotIdProvider? idProvider})
      : _idProvider = idProvider ?? const _IncrementalSnapshotIdProvider();

  final LayoutSnapshotIdProvider _idProvider;

  LayoutComputationResult compute({
    required GridLayoutGeometry geometry,
    required Iterable<GridCardViewState> states,
  }) {
    final effectiveColumnCount = math.max(1, geometry.columnCount);
    final columnHeights =
        List<double>.filled(effectiveColumnCount, 0, growable: false);
    final entries = <LayoutSnapshotEntry>[];
    final nextStates = <GridCardViewState>[];
    var changed = false;

    for (final state in states) {
      final span = state.columnSpan.clamp(1, effectiveColumnCount);
      final width = _computeWidth(geometry, span);
      final height = _computeHeight(state, width);
      final layoutState = GridCardViewState(
        id: state.id,
        width: width,
        height: height,
        scale: state.scale,
        columnSpan: span,
        customHeight: height,
      );
      if (!_viewStateEquals(state, layoutState)) {
        changed = true;
      }
      nextStates.add(layoutState);

      final placement = _findPlacement(
        columnHeights,
        span,
        geometry.gap,
        height,
        preferredColumnStart: state.preferredColumnStart,
      );
      final crossAxisOffset =
          placement.start * (geometry.columnWidth + geometry.gap);
      final rect = Rect.fromLTWH(
        crossAxisOffset,
        placement.offset,
        width,
        height,
      );
      entries.add(
        LayoutSnapshotEntry(
          id: state.id,
          rect: rect,
          columnSpan: span,
        ),
      );
    }

    return LayoutComputationResult(
      snapshot: LayoutSnapshot(
        id: _idProvider.nextId(),
        geometry: geometry,
        entries: entries,
      ),
      viewStates: nextStates,
      changed: changed,
    );
  }

  LayoutSnapshot buildSnapshot({
    required GridLayoutGeometry geometry,
    required Iterable<GridCardViewState> states,
  }) {
    final effectiveColumnCount = math.max(1, geometry.columnCount);
    final columnHeights =
        List<double>.filled(effectiveColumnCount, 0, growable: false);
    final entries = <LayoutSnapshotEntry>[];
    for (final state in states) {
      final span = state.columnSpan.clamp(1, effectiveColumnCount);
      final width = _computeWidth(geometry, span);
      final height = state.height > 0 ? state.height : width;
      final placement = _findPlacement(
        columnHeights,
        span,
        geometry.gap,
        height,
        preferredColumnStart: state.preferredColumnStart,
      );
      final crossAxisOffset =
          placement.start * (geometry.columnWidth + geometry.gap);
      entries.add(
        LayoutSnapshotEntry(
          id: state.id,
          rect: Rect.fromLTWH(
            crossAxisOffset,
            placement.offset,
            width,
            height,
          ),
          columnSpan: span,
        ),
      );
    }
    return LayoutSnapshot(
      id: _idProvider.nextId(),
      geometry: geometry,
      entries: entries,
    );
  }

  double _computeWidth(GridLayoutGeometry geometry, int span) {
    final gapCount = math.max(0, span - 1);
    final gapWidth = geometry.gap * gapCount;
    return geometry.columnWidth * span + gapWidth;
  }

  double _computeHeight(GridCardViewState state, double width) {
    const epsilon = 0.0001;
    if (width <= epsilon) {
      return width;
    }
    final ratio = (state.width > 0 && state.height > 0)
        ? state.height / state.width
        : 1.0;
    if (!ratio.isFinite || ratio <= 0) {
      return width;
    }
    return width * ratio;
  }

  _Placement _findPlacement(
    List<double> columnHeights,
    int span,
    double gap,
    double height, {
    int? preferredColumnStart,
  }) {
    final columnCount = columnHeights.length;
    if (columnCount == 0) {
      return _Placement(0, 0);
    }
    final clampedSpan = math.max(1, math.min(span, columnCount));

    // 優先列が指定されている場合、まずそこを使用
    if (preferredColumnStart != null) {
      final preferredStart =
          preferredColumnStart.clamp(0, columnCount - clampedSpan);
      if (preferredStart + clampedSpan <= columnCount) {
        double candidateOffset = 0;
        for (int c = 0; c < clampedSpan; c++) {
          candidateOffset =
              math.max(candidateOffset, columnHeights[preferredStart + c]);
        }
        final newHeight = candidateOffset + height;
        for (int c = 0; c < clampedSpan; c++) {
          final nextIndex = preferredStart + c;
          columnHeights[nextIndex] =
              newHeight + (nextIndex == columnCount - 1 ? 0 : gap);
        }
        return _Placement(preferredStart, candidateOffset);
      }
    }

    // フォールバック: 従来の最短列アルゴリズム
    var bestStart = 0;
    double bestOffset = double.infinity;
    const epsilon = 0.001;
    for (int start = 0; start <= columnCount - clampedSpan; start++) {
      double candidate = 0;
      for (int c = 0; c < clampedSpan; c++) {
        candidate = math.max(candidate, columnHeights[start + c]);
      }
      if (candidate < bestOffset - epsilon) {
        bestOffset = candidate;
        bestStart = start;
      }
    }
    if (!bestOffset.isFinite) {
      bestOffset = 0;
    }
    final newHeight = bestOffset + height;
    for (int c = 0; c < clampedSpan; c++) {
      final nextIndex = bestStart + c;
      columnHeights[nextIndex] =
          newHeight + (nextIndex == columnCount - 1 ? 0 : gap);
    }
    return _Placement(bestStart, bestOffset);
  }

  bool _viewStateEquals(GridCardViewState a, GridCardViewState b) {
    const epsilon = 0.0001;
    return a.id == b.id &&
        a.columnSpan == b.columnSpan &&
        (a.customHeight == null && b.customHeight == null ||
            (a.customHeight != null &&
                b.customHeight != null &&
                (a.customHeight! - b.customHeight!).abs() < epsilon)) &&
        (a.scale - b.scale).abs() < epsilon &&
        (a.width - b.width).abs() < epsilon &&
        (a.height - b.height).abs() < epsilon;
  }
}

class LayoutComputationResult {
  LayoutComputationResult({
    required this.snapshot,
    required this.viewStates,
    required this.changed,
  });

  final LayoutSnapshot snapshot;
  final List<GridCardViewState> viewStates;
  final bool changed;
}

class LayoutSnapshot {
  LayoutSnapshot({
    required this.id,
    required this.geometry,
    required this.entries,
  });

  final String id;
  final GridLayoutGeometry geometry;
  final List<LayoutSnapshotEntry> entries;

  /// 全エントリの最大bottom値（グリッド全体の高さ）
  double get totalHeight {
    if (entries.isEmpty) return 0;
    return entries.map((e) => e.rect.bottom).reduce((a, b) => a > b ? a : b);
  }
}

class LayoutSnapshotEntry {
  LayoutSnapshotEntry({
    required this.id,
    required this.rect,
    required this.columnSpan,
  });

  final String id;
  final Rect rect;
  final int columnSpan;
}

abstract class LayoutSnapshotIdProvider {
  const LayoutSnapshotIdProvider();
  String nextId();
}

class _IncrementalSnapshotIdProvider implements LayoutSnapshotIdProvider {
  const _IncrementalSnapshotIdProvider();

  static int _sequence = 0;

  @override
  String nextId() {
    _sequence += 1;
    return 'layout_snapshot_${_sequence.toString().padLeft(6, '0')}';
  }
}

class _Placement {
  _Placement(this.start, this.offset);

  final int start;
  final double offset;
}
