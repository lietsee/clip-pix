import 'dart:collection';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../data/models/content_item.dart';
import '../grid_layout_layout_engine.dart' as layout;

/// 永続層に対してカードレイアウトを読み書きするためのゲートウェイ。
abstract class GridLayoutPersistence {
  GridLayoutPreferenceRecord read(String id);

  Future<void> saveBatch(List<GridLayoutPreferenceRecord> mutations);
}

class GridLayoutPreferenceRecord {
  GridLayoutPreferenceRecord({
    required this.id,
    required this.width,
    required this.height,
    required this.scale,
    required this.columnSpan,
    required this.customHeight,
  });

  final String id;
  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;

  static const double defaultWidth = 200;
  static const double defaultHeight = 200;
  static const double defaultScale = 1.0;
  static const int defaultColumnSpan = 1;
}

abstract class GridIntrinsicRatioResolver {
  Future<double?> resolve(String id, ContentItem? item);
}

abstract class GridLayoutCommandTarget {
  GridLayoutSnapshot captureSnapshot();
  Future<void> applyBulkSpan({required int span});
  Future<void> restoreSnapshot(GridLayoutSnapshot snapshot);
}

abstract class GridLayoutSurfaceStore extends Listenable
    implements GridLayoutCommandTarget {
  List<GridCardViewState> get viewStates;
  void updateGeometry(GridLayoutGeometry geometry, {bool notify = true});
  layout.LayoutSnapshot? get latestSnapshot;
}

class GridLayoutGeometry {
  const GridLayoutGeometry({
    required this.columnCount,
    required this.columnWidth,
    required this.gap,
  });

  final int columnCount;
  final double columnWidth;
  final double gap;
}

class GridCardViewState {
  GridCardViewState({
    required this.id,
    required this.width,
    required this.height,
    required this.scale,
    required this.columnSpan,
    required this.customHeight,
  });

  final String id;
  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;
}

class GridLayoutSnapshot {
  GridLayoutSnapshot({
    required this.directoryPath,
    required this.values,
  });

  final String? directoryPath;
  final Map<String, GridCardSnapshot> values;
}

class GridCardSnapshot {
  GridCardSnapshot({
    required this.width,
    required this.height,
    required this.scale,
    required this.columnSpan,
    required this.customHeight,
  });

  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;
}

class GridLayoutStore extends ChangeNotifier implements GridLayoutSurfaceStore {
  GridLayoutStore({
    required GridLayoutPersistence persistence,
    required GridIntrinsicRatioResolver ratioResolver,
    layout.GridLayoutLayoutEngine? layoutEngine,
  })  : _persistence = persistence,
        _ratioResolver = ratioResolver,
        _layoutEngine = layoutEngine ?? layout.GridLayoutLayoutEngine();

  static const double _epsilon = 0.0001;

  final GridLayoutPersistence _persistence;
  final GridIntrinsicRatioResolver _ratioResolver;
  final layout.GridLayoutLayoutEngine _layoutEngine;

  final Map<String, GridCardViewState> _viewStates = {};
  final List<String> _orderedIds = [];
  String? _directoryPath;
  GridLayoutGeometry? _geometry;
  final Map<String, ContentItem> _items = {};
  layout.LayoutSnapshot? _latestSnapshot;
  layout.LayoutSnapshot? _previousSnapshot;

  @override
  List<GridCardViewState> get viewStates => UnmodifiableListView(
        _orderedIds
            .where((id) => _viewStates.containsKey(id))
            .map((id) => _viewStates[id]!)
            .toList(growable: false),
      );

  @override
  layout.LayoutSnapshot? get latestSnapshot =>
      _latestSnapshot ?? _previousSnapshot;

  void syncLibrary(
    List<ContentItem> items, {
    String? directoryPath,
    bool notify = true,
  }) {
    _directoryPath = directoryPath;
    _items
      ..clear()
      ..addEntries(items.map((item) => MapEntry(item.id, item)));
    final Map<String, GridCardViewState> nextStates = {};
    final List<String> nextOrder = [];

    for (final item in items) {
      final record = _persistence.read(item.id);
      final state = GridCardViewState(
        id: item.id,
        width: record.width,
        height: record.height,
        scale: record.scale,
        columnSpan: record.columnSpan,
        customHeight: record.customHeight,
      );
      nextStates[item.id] = state;
      nextOrder.add(item.id);
    }

    final bool orderChanged = !listEquals(_orderedIds, nextOrder);
    final bool contentChanged = !_statesEqual(_viewStates, nextStates);

    _viewStates
      ..clear()
      ..addAll(nextStates);
    _orderedIds
      ..clear()
      ..addAll(nextOrder);

    if (notify && (orderChanged || contentChanged)) {
      notifyListeners();
    }
    _invalidateSnapshot();
  }

  bool hasViewState(String id) {
    return _viewStates.containsKey(id);
  }

  GridCardViewState viewStateFor(String id) {
    final state = _viewStates[id];
    if (state == null) {
      throw StateError('ViewState for $id is not loaded');
    }
    return state;
  }

  @override
  void updateGeometry(
    GridLayoutGeometry geometry, {
    bool notify = true,
  }) {
    final current = _geometry;
    final deltaColumns =
        current != null ? geometry.columnCount - current.columnCount : null;
    final deltaWidth =
        current != null ? geometry.columnWidth - current.columnWidth : null;
    debugPrint(
      '[GridLayoutStore] updateGeometry geometry=$geometry notify=$notify '
      'deltaColumns=$deltaColumns deltaWidth=${deltaWidth?.toStringAsFixed(3)}',
    );
    final previousGeometry = _geometry;
    _geometry = geometry;
    final orderedStates = _orderedIds
        .map((id) => _viewStates[id])
        .whereType<GridCardViewState>()
        .toList(growable: false);
    final result = _layoutEngine.compute(
      geometry: geometry,
      states: orderedStates,
    );
    var changed = result.changed;
    final geometryChanged = previousGeometry == null ||
        previousGeometry.columnCount != geometry.columnCount ||
        (previousGeometry.columnWidth - geometry.columnWidth).abs() >
            _epsilon ||
        (previousGeometry.gap - geometry.gap).abs() > _epsilon;
    changed = changed || geometryChanged;
    for (final state in result.viewStates) {
      final existing = _viewStates[state.id];
      if (!changed && existing != null && !_viewStateEquals(existing, state)) {
        changed = true;
      }
      _viewStates[state.id] = state;
    }
    // Preserve previous snapshot before updating to new one
    if (_latestSnapshot != null) {
      _previousSnapshot = _latestSnapshot;
    }
    _latestSnapshot = result.snapshot;
    if (changed && notify) {
      notifyListeners();
    }
  }

  @override
  Future<void> applyBulkSpan({required int span}) async {
    if (_orderedIds.isEmpty) {
      return;
    }
    final geometry = _geometry;
    if (geometry == null) {
      throw StateError('Grid layout geometry is not set');
    }
    if (geometry.columnCount <= 0 || geometry.columnWidth <= 0) {
      return;
    }
    final int clampedSpan = span.clamp(1, geometry.columnCount);
    final double gapTotal = geometry.gap * (clampedSpan - 1);
    final double targetWidth = geometry.columnWidth * clampedSpan + gapTotal;

    bool changed = false;
    final List<GridLayoutPreferenceRecord> batch = [];

    for (final id in _orderedIds) {
      final current = _viewStates[id];
      if (current == null) {
        continue;
      }
      final double ratio = await _resolveAspectRatio(id, current);
      final double nextHeight =
          ratio.isFinite && ratio > 0 ? targetWidth * ratio : current.height;

      final gridState = GridCardViewState(
        id: id,
        width: targetWidth,
        height: nextHeight,
        scale: current.scale,
        columnSpan: clampedSpan,
        customHeight: nextHeight,
      );
      if (!_viewStateEquals(current, gridState)) {
        changed = true;
        _viewStates[id] = gridState;
      }
      batch.add(_recordFromState(gridState));
    }

    if (batch.isEmpty) {
      return;
    }
    await _persistence.saveBatch(batch);
    if (changed) {
      notifyListeners();
    }
    _invalidateSnapshot();
  }

  @override
  GridLayoutSnapshot captureSnapshot() {
    final Map<String, GridCardSnapshot> values = {};
    for (final id in _orderedIds) {
      final state = _viewStates[id];
      if (state == null) {
        continue;
      }
      values[id] = GridCardSnapshot(
        width: state.width,
        height: state.height,
        scale: state.scale,
        columnSpan: state.columnSpan,
        customHeight: state.customHeight,
      );
    }
    return GridLayoutSnapshot(
      directoryPath: _directoryPath,
      values: values,
    );
  }

  @override
  Future<void> restoreSnapshot(GridLayoutSnapshot snapshot) async {
    if (snapshot.values.isEmpty) {
      return;
    }
    bool changed = false;
    final List<GridLayoutPreferenceRecord> batch = [];

    for (final entry in snapshot.values.entries) {
      final existing = _viewStates[entry.key];
      final value = entry.value;
      final nextState = GridCardViewState(
        id: entry.key,
        width: value.width,
        height: value.height,
        scale: value.scale,
        columnSpan: value.columnSpan,
        customHeight: value.customHeight,
      );
      if (!_orderedIds.contains(entry.key)) {
        _orderedIds.add(entry.key);
      }
      _viewStates[entry.key] = nextState;
      if (existing == null || !_viewStateEquals(existing, nextState)) {
        changed = true;
      }
      batch.add(_recordFromState(nextState));
    }

    await _persistence.saveBatch(batch);
    if (changed) {
      notifyListeners();
    }
    _invalidateSnapshot();
  }

  Future<void> updateCard({
    required String id,
    Size? customSize,
    double? scale,
    int? columnSpan,
  }) async {
    final current = _viewStates[id];
    if (current == null) {
      throw StateError('ViewState for $id is not loaded');
    }
    double nextWidth = current.width;
    double nextHeight = current.height;
    double? nextCustomHeight = current.customHeight;
    double nextScale = current.scale;
    int nextSpan = current.columnSpan;

    if (customSize != null) {
      nextWidth = customSize.width;
      nextHeight = customSize.height;
      nextCustomHeight = customSize.height;
    }
    if (scale != null) {
      nextScale = scale;
    }
    if (columnSpan != null) {
      final geometry = _geometry;
      if (geometry != null && geometry.columnCount > 0) {
        nextSpan = columnSpan.clamp(1, geometry.columnCount);
        if (customSize == null) {
          final double gapTotal = geometry.gap * (nextSpan - 1);
          nextWidth = geometry.columnWidth * nextSpan + gapTotal;
          final ratio = await _resolveAspectRatio(id, current);
          final computedHeight =
              ratio.isFinite && ratio > 0 ? nextWidth * ratio : nextWidth;
          nextHeight = computedHeight;
          nextCustomHeight = computedHeight;
        }
      } else {
        nextSpan = columnSpan;
      }
    }

    final nextState = GridCardViewState(
      id: id,
      width: nextWidth,
      height: nextHeight,
      scale: nextScale,
      columnSpan: nextSpan,
      customHeight: nextCustomHeight,
    );

    if (_viewStateEquals(current, nextState)) {
      return;
    }

    _viewStates[id] = nextState;
    await _persistence.saveBatch([_recordFromState(nextState)]);
    notifyListeners();
    _invalidateSnapshot();
  }

  bool _statesEqual(
    Map<String, GridCardViewState> a,
    Map<String, GridCardViewState> b,
  ) {
    if (identical(a, b)) {
      return true;
    }
    if (a.length != b.length) {
      return false;
    }
    for (final entry in a.entries) {
      final other = b[entry.key];
      if (other == null || !_viewStateEquals(entry.value, other)) {
        return false;
      }
    }
    return true;
  }

  bool _viewStateEquals(GridCardViewState a, GridCardViewState b) {
    return a.id == b.id &&
        (a.columnSpan == b.columnSpan) &&
        (a.customHeight == null && b.customHeight == null ||
            (a.customHeight != null &&
                b.customHeight != null &&
                (a.customHeight! - b.customHeight!).abs() < _epsilon)) &&
        (a.scale - b.scale).abs() < _epsilon &&
        (a.width - b.width).abs() < _epsilon &&
        (a.height - b.height).abs() < _epsilon;
  }

  GridLayoutPreferenceRecord _recordFromState(GridCardViewState state) {
    return GridLayoutPreferenceRecord(
      id: state.id,
      width: state.width,
      height: state.height,
      scale: state.scale,
      columnSpan: state.columnSpan,
      customHeight: state.customHeight,
    );
  }

  Future<double> _resolveAspectRatio(
    String id,
    GridCardViewState current,
  ) async {
    final resolved = await _ratioResolver.resolve(id, _items[id]);
    if (resolved != null && resolved.isFinite && resolved > 0) {
      return resolved;
    }
    if (current.width > 0 && current.height > 0) {
      return current.height / current.width;
    }
    return 1.0;
  }

  void _invalidateSnapshot() {
    _latestSnapshot = null;
  }
}
