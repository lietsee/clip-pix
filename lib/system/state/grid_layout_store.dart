import 'dart:collection';
import 'dart:math' as math;
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
    this.offsetDx = 0.0,
    this.offsetDy = 0.0,
  });

  final String id;
  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;
  final double offsetDx;
  final double offsetDy;

  static const double defaultWidth = 200;
  static const double defaultHeight = 200;
  static const double defaultScale = 1.0;
  static const int defaultColumnSpan = 1;
}

abstract class GridIntrinsicRatioResolver {
  Future<double?> resolve(String id, ContentItem? item);

  /// キャッシュをクリアして次回の解決で実ファイルから再読み込みさせる
  void clearCache() {}
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
    this.offsetDx = 0.0,
    this.offsetDy = 0.0,
  });

  final String id;
  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;
  final double offsetDx;
  final double offsetDy;

  Offset get offset => Offset(offsetDx, offsetDy);
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
    this.offsetDx = 0.0,
    this.offsetDy = 0.0,
  });

  final double width;
  final double height;
  final double scale;
  final int columnSpan;
  final double? customHeight;
  final double offsetDx;
  final double offsetDy;
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

  /// syncLibraryで順序が変更されたがgeometryがnullのためスナップショットを
  /// 再生成できなかった場合にtrueになる。updateGeometryで処理される。
  bool _pendingSnapshotRegeneration = false;

  /// syncLibraryで新規カードが追加されたがgeometryがnullのため
  /// アスペクト比を解決できなかったカードIDのリスト。updateGeometryで処理される。
  final List<String> _pendingAspectRatioCardIds = [];

  /// 高さが変更されてImageCardのリビルドが必要なカードIDのセット。
  /// GridViewModuleがconsumePendingResizeNotifications()で消費する。
  final Set<String> _pendingResizeNotifications = {};

  /// 高さが変更されたカードをマーク（ImageCardリビルド用）
  void _notifyCardResized(String id) {
    _pendingResizeNotifications.add(id);
  }

  /// 保留中のリサイズ通知を消費して返す
  Set<String> consumePendingResizeNotifications() {
    final result = Set<String>.from(_pendingResizeNotifications);
    _pendingResizeNotifications.clear();
    return result;
  }

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

  /// 現在の順序付きIDリストを取得（ミニマップとの同期用）
  List<String> get orderedIds => List.unmodifiable(_orderedIds);

  void syncLibrary(
    List<ContentItem> items, {
    String? directoryPath,
    bool notify = true,
  }) {
    // [DIAGNOSTIC] Track syncLibrary call
    debugPrint('[GridLayoutStore] syncLibrary_start: '
        'notify=$notify, itemCount=${items.length}, '
        'currentViewStateCount=${_viewStates.length}, '
        'directoryPath=$directoryPath');

    _directoryPath = directoryPath;
    _items
      ..clear()
      ..addEntries(items.map((item) => MapEntry(item.id, item)));
    final Map<String, GridCardViewState> nextStates = {};
    final List<String> nextOrder = [];

    // Collect new cards that need aspect ratio resolution
    final List<String> newCardIds = [];

    for (final item in items) {
      final record = _persistence.read(item.id);
      final isNewCard = !_viewStates.containsKey(item.id);
      final state = GridCardViewState(
        id: item.id,
        width: record.width,
        height: record.height,
        scale: record.scale,
        columnSpan: record.columnSpan,
        customHeight: record.customHeight,
        offsetDx: record.offsetDx,
        offsetDy: record.offsetDy,
      );
      nextStates[item.id] = state;
      nextOrder.add(item.id);

      // 新規カード、またはデフォルト高さのままのカードはアスペクト比を再解決
      // (過去に間違った高さで保存されたカードを修正するため)
      final needsAspectRatioResolution = isNewCard ||
          (record.customHeight == null &&
           (record.height - GridLayoutPreferenceRecord.defaultHeight).abs() < 1.0);

      if (needsAspectRatioResolution) {
        newCardIds.add(item.id);
      }
    }

    final bool orderChanged = !listEquals(_orderedIds, nextOrder);
    final bool contentChanged = !_statesEqual(_viewStates, nextStates);

    // [DIAGNOSTIC] If contentChanged, log which states differ
    if (contentChanged) {
      debugPrint(
          '[GridLayoutStore] contentChanged=true, checking differences...');
      int diffCount = 0;
      for (final entry in nextStates.entries) {
        final oldState = _viewStates[entry.key];
        if (oldState == null) {
          debugPrint('  [NEW] ${entry.key.split('/').last}');
          diffCount++;
        } else if (!_viewStateEquals(oldState, entry.value)) {
          final old = oldState;
          final next = entry.value;
          debugPrint('  [DIFF] ${entry.key.split('/').last}: '
              'width=${old.width.toStringAsFixed(2)}→${next.width.toStringAsFixed(2)}, '
              'height=${old.height.toStringAsFixed(2)}→${next.height.toStringAsFixed(2)}, '
              'span=${old.columnSpan}→${next.columnSpan}, '
              'customH=${old.customHeight?.toStringAsFixed(2)}→${next.customHeight?.toStringAsFixed(2)}');
          diffCount++;
        }
      }
      for (final oldKey in _viewStates.keys) {
        if (!nextStates.containsKey(oldKey)) {
          debugPrint('  [REMOVED] ${oldKey.split('/').last}');
          diffCount++;
        }
      }
      debugPrint('[GridLayoutStore] Total differences: $diffCount');
    }

    _viewStates
      ..clear()
      ..addAll(nextStates);
    _orderedIds
      ..clear()
      ..addAll(nextOrder);

    // [DEBUG] 順序確認ログ
    debugPrint('[GridLayoutStore] syncLibrary: orderedIds (first 15) = '
        '${_orderedIds.take(15).map((id) => id.split('/').last).toList()}');

    // Regenerate snapshot if order or content changed
    // This ensures PinterestGrid gets a new snapshot ID and can detect layout changes
    if (orderChanged || contentChanged) {
      final geometry = _geometry;
      if (geometry != null) {
        // Generate new snapshot with updated viewStates
        final orderedStates = _orderedIds
            .map((id) => _viewStates[id])
            .whereType<GridCardViewState>()
            .toList(growable: false);
        final result = _layoutEngine.compute(
          geometry: geometry,
          states: orderedStates,
        );

        // Preserve previous snapshot before updating
        final prevSnapshotId = _latestSnapshot?.id;
        if (_latestSnapshot != null) {
          _previousSnapshot = _latestSnapshot;
        }
        _latestSnapshot = result.snapshot;

        // [DIAGNOSTIC] Track snapshot regeneration
        debugPrint('[GridLayoutStore] snapshot_regenerated: '
            'prevId=$prevSnapshotId, newId=${_latestSnapshot?.id}');
        // [DEBUG] スナップショット順序確認ログ
        debugPrint('[GridLayoutStore] snapshot: entries order (first 15) = '
            '${result.snapshot.entries.take(15).map((e) => e.id.split('/').last).toList()}');
      } else {
        // No geometry available yet
        // Try to use previous snapshot's geometry if available
        final prevGeometry = _previousSnapshot?.geometry ?? _latestSnapshot?.geometry;
        if (prevGeometry != null) {
          // Regenerate snapshot with new order using previous geometry
          final orderedStates = _orderedIds
              .map((id) => _viewStates[id])
              .whereType<GridCardViewState>()
              .toList(growable: false);
          final tempGeometry = GridLayoutGeometry(
            columnCount: prevGeometry.columnCount,
            columnWidth: prevGeometry.columnWidth,
            gap: prevGeometry.gap,
          );
          final result = _layoutEngine.compute(
            geometry: tempGeometry,
            states: orderedStates,
          );

          final prevSnapshotId = _latestSnapshot?.id;
          if (_latestSnapshot != null) {
            _previousSnapshot = _latestSnapshot;
          }
          _latestSnapshot = result.snapshot;

          debugPrint('[GridLayoutStore] syncLibrary: geometry null but prevGeometry available, '
              'regenerated snapshot: prevId=$prevSnapshotId, newId=${_latestSnapshot?.id}');
          // [DEBUG] スナップショット順序確認ログ
          debugPrint('[GridLayoutStore] snapshot: entries order (first 15) = '
              '${result.snapshot.entries.take(15).map((e) => e.id.split('/').last).toList()}');
        } else {
          // No previous geometry, mark for later regeneration
          _pendingSnapshotRegeneration = true;
          debugPrint('[GridLayoutStore] syncLibrary: geometry null and no prevGeometry, '
              'setting pendingSnapshotRegeneration=true');
          _invalidateSnapshot();
        }
      }
    } else {
      // No changes, just invalidate (keeps previous behavior)
      _invalidateSnapshot();
    }

    if (notify && (orderChanged || contentChanged)) {
      notifyListeners();
    }

    // [DIAGNOSTIC] Track syncLibrary completion
    debugPrint('[GridLayoutStore] syncLibrary_complete: '
        'orderChanged=$orderChanged, contentChanged=$contentChanged, '
        'willNotify=${notify && (orderChanged || contentChanged)}, '
        'newViewStateCount=${_viewStates.length}, '
        'newCardIds=${newCardIds.length}, '
        'first3Ids=${_orderedIds.take(3).map((id) => id.split('/').last).join(", ")}');

    // Resolve aspect ratios for new cards asynchronously
    if (newCardIds.isNotEmpty) {
      if (_geometry != null) {
        _resolveNewCardAspectRatios(newCardIds);
      } else {
        // Store for later resolution in updateGeometry
        _pendingAspectRatioCardIds.addAll(newCardIds);
        debugPrint('[GridLayoutStore] syncLibrary: geometry null, '
            'storing ${newCardIds.length} pending aspect ratio card IDs');
      }
    }
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
    // Check if we have a pending regeneration from syncLibrary
    final hadPendingRegeneration = _pendingSnapshotRegeneration;
    _pendingSnapshotRegeneration = false;

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
    changed = changed || geometryChanged || hadPendingRegeneration;

    // Collect mutations for persistence
    final List<GridLayoutPreferenceRecord> mutations = [];
    for (final state in result.viewStates) {
      final existing = _viewStates[state.id];
      if (!changed && existing != null && !_viewStateEquals(existing, state)) {
        changed = true;
      }
      // [FIX] Preserve pan offset from existing state (layout engine doesn't track offset)
      final preservedState = existing != null
          ? GridCardViewState(
              id: state.id,
              width: state.width,
              height: state.height,
              scale: state.scale,
              columnSpan: state.columnSpan,
              customHeight: state.customHeight,
              offsetDx: existing.offsetDx,
              offsetDy: existing.offsetDy,
            )
          : state;
      _viewStates[state.id] = preservedState;
      mutations.add(_recordFromState(preservedState));
    }

    // [FIX] Persist updated geometry to Hive to prevent stale reads in syncLibrary
    if (mutations.isNotEmpty) {
      debugPrint('[GridLayoutStore] updateGeometry_persist: '
          'mutationCount=${mutations.length}, geometryChanged=$geometryChanged');
      _persistence.saveBatch(mutations);
    }

    // Preserve previous snapshot before updating to new one
    final prevSnapshotId = _latestSnapshot?.id;
    if (_latestSnapshot != null) {
      _previousSnapshot = _latestSnapshot;
    }
    _latestSnapshot = result.snapshot;

    // Force notification if we had pending regeneration
    // This ensures the front buffer gets the new snapshot even when notify=false
    final shouldNotify = (changed && notify) || hadPendingRegeneration;

    // [DIAGNOSTIC] Track snapshot regeneration in updateGeometry
    debugPrint('[GridLayoutStore] updateGeometry: '
        'prevSnapshotId=$prevSnapshotId, newSnapshotId=${_latestSnapshot?.id}, '
        'hadPendingRegeneration=$hadPendingRegeneration, '
        'changed=$changed, notify=$notify, shouldNotify=$shouldNotify, '
        'geometryChanged=$geometryChanged, '
        'orderedIdsFirst3=${_orderedIds.take(3).map((e) => e.split('/').last).join(', ')}');
    // [DEBUG] スナップショット順序確認ログ
    debugPrint('[GridLayoutStore] updateGeometry snapshot: entries order (first 15) = '
        '${result.snapshot.entries.take(15).map((e) => e.id.split('/').last).toList()}');

    if (shouldNotify) {
      notifyListeners();
    }

    // Resolve pending aspect ratios from syncLibrary that ran when geometry was null
    if (_pendingAspectRatioCardIds.isNotEmpty) {
      final cardsToResolve = List<String>.from(_pendingAspectRatioCardIds);
      _pendingAspectRatioCardIds.clear();
      debugPrint('[GridLayoutStore] updateGeometry: resolving '
          '${cardsToResolve.length} pending aspect ratio cards');
      _resolveNewCardAspectRatios(cardsToResolve);
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
        offsetDx: current.offsetDx,
        offsetDy: current.offsetDy,
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

    // [FIX] Regenerate snapshot after bulk span to ensure minimap updates
    final orderedStates = _orderedIds
        .map((id) => _viewStates[id])
        .whereType<GridCardViewState>()
        .toList(growable: false);
    final result = _layoutEngine.compute(
      geometry: geometry,
      states: orderedStates,
    );
    if (_latestSnapshot != null) {
      _previousSnapshot = _latestSnapshot;
    }
    _latestSnapshot = result.snapshot;

    if (changed) {
      notifyListeners();
    }
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
        offsetDx: state.offsetDx,
        offsetDy: state.offsetDy,
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
        offsetDx: value.offsetDx,
        offsetDy: value.offsetDy,
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
    Offset? offset,
  }) async {
    print('[GridLayoutStore] updateCard ENTRY: id=${id.split('/').last}, offset=$offset');
    final current = _viewStates[id];
    if (current == null) {
      throw StateError('ViewState for $id is not loaded');
    }
    double nextWidth = current.width;
    double nextHeight = current.height;
    double? nextCustomHeight = current.customHeight;
    double nextScale = current.scale;
    int nextSpan = current.columnSpan;
    double nextOffsetDx = current.offsetDx;
    double nextOffsetDy = current.offsetDy;

    if (customSize != null) {
      nextWidth = customSize.width;
      nextHeight = customSize.height;
      nextCustomHeight = customSize.height;
    }
    if (scale != null) {
      nextScale = scale;
    }
    if (offset != null) {
      nextOffsetDx = offset.dx;
      nextOffsetDy = offset.dy;
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
      offsetDx: nextOffsetDx,
      offsetDy: nextOffsetDy,
    );

    if (_viewStateEquals(current, nextState)) {
      print('[GridLayoutStore] updateCard_skip: id=${id.split('/').last}, '
          'no change detected');
      return;
    }

    print('[GridLayoutStore] updateCard_save: id=${id.split('/').last}, '
        'offsetDx=${nextState.offsetDx.toStringAsFixed(2)}, '
        'offsetDy=${nextState.offsetDy.toStringAsFixed(2)}, '
        'scale=${nextState.scale.toStringAsFixed(2)}');
    _viewStates[id] = nextState;
    await _persistence.saveBatch([_recordFromState(nextState)]);

    // [FIX] Regenerate snapshot after card update to ensure minimap updates
    final geometry = _geometry;
    if (geometry != null) {
      final orderedStates = _orderedIds
          .map((id) => _viewStates[id])
          .whereType<GridCardViewState>()
          .toList(growable: false);
      final result = _layoutEngine.compute(
        geometry: geometry,
        states: orderedStates,
      );
      if (_latestSnapshot != null) {
        _previousSnapshot = _latestSnapshot;
      }
      _latestSnapshot = result.snapshot;
    }

    notifyListeners();
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
        (a.height - b.height).abs() < _epsilon &&
        (a.offsetDx - b.offsetDx).abs() < _epsilon &&
        (a.offsetDy - b.offsetDy).abs() < _epsilon;
  }

  GridLayoutPreferenceRecord _recordFromState(GridCardViewState state) {
    return GridLayoutPreferenceRecord(
      id: state.id,
      width: state.width,
      height: state.height,
      scale: state.scale,
      columnSpan: state.columnSpan,
      customHeight: state.customHeight,
      offsetDx: state.offsetDx,
      offsetDy: state.offsetDy,
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
    // Preserve latestSnapshot as previousSnapshot before invalidating
    if (_latestSnapshot != null) {
      _previousSnapshot = _latestSnapshot;
    }
    _latestSnapshot = null;
  }

  /// Resolve aspect ratios for newly added cards and update their heights.
  /// This is called asynchronously after syncLibrary() to avoid blocking.
  Future<void> _resolveNewCardAspectRatios(List<String> newCardIds) async {
    final geometry = _geometry;
    if (geometry == null) {
      debugPrint('[GridLayoutStore] _resolveNewCardAspectRatios: '
          'skipped - no geometry available');
      return;
    }

    debugPrint('[GridLayoutStore] _resolveNewCardAspectRatios: '
        'resolving ${newCardIds.length} new cards');

    bool anyChanged = false;
    int processed = 0;
    int skipped = 0;
    int ratioFailed = 0;
    int alreadyCorrect = 0;
    int updated = 0;

    try {
      for (final id in newCardIds) {
        processed++;
        final current = _viewStates[id];
        if (current == null) {
          skipped++;
          continue;
        }

        // Resolve aspect ratio from image file
        final ratio = await _resolveAspectRatio(id, current);
        if (!ratio.isFinite || ratio <= 0) {
          ratioFailed++;
          continue;
        }

        // Calculate actual width based on geometry (same logic as GridLayoutLayoutEngine._computeWidth)
        final span = current.columnSpan;
        final gapCount = math.max(0, span - 1);
        final gapWidth = geometry.gap * gapCount;
        final actualWidth = geometry.columnWidth * span + gapWidth;

        // Calculate new height based on actual width and aspect ratio (ratio = height/width)
        final newHeight = actualWidth * ratio;

        // Skip if size is already correct (within tolerance)
        if ((current.width - actualWidth).abs() < 1.0 &&
            (current.height - newHeight).abs() < 1.0) {
          alreadyCorrect++;
          continue;
        }

        debugPrint('[GridLayoutStore] new_card_height_adjusted: '
            'id=${id.split('/').last}, '
            'oldSize=${current.width.toStringAsFixed(1)}x${current.height.toStringAsFixed(1)}, '
            'newSize=${actualWidth.toStringAsFixed(1)}x${newHeight.toStringAsFixed(1)}, '
            'ratio=${ratio.toStringAsFixed(3)}');

        // Update viewState with actual width and calculated height
        final newState = GridCardViewState(
          id: current.id,
          width: actualWidth,
          height: newHeight,
          scale: current.scale,
          columnSpan: current.columnSpan,
          customHeight: newHeight,
          offsetDx: current.offsetDx,
          offsetDy: current.offsetDy,
        );
        _viewStates[id] = newState;

        // Notify that this card needs rebuild in ImageCard
        _notifyCardResized(id);

        // Persist the calculated size
        await _persistence.saveBatch([
          GridLayoutPreferenceRecord(
            id: id,
            width: actualWidth,
            height: newHeight,
            scale: current.scale,
            columnSpan: current.columnSpan,
            customHeight: newHeight,
            offsetDx: current.offsetDx,
            offsetDy: current.offsetDy,
          ),
        ]);

        updated++;
        anyChanged = true;
      }
    } catch (e, stackTrace) {
      debugPrint('[GridLayoutStore] _resolveNewCardAspectRatios ERROR: $e');
      debugPrint('[GridLayoutStore] stackTrace: $stackTrace');
    }

    debugPrint('[GridLayoutStore] _resolveNewCardAspectRatios_stats: '
        'processed=$processed, skipped=$skipped, ratioFailed=$ratioFailed, '
        'alreadyCorrect=$alreadyCorrect, updated=$updated');

    if (anyChanged) {
      // Regenerate snapshot with updated heights
      final currentGeometry = _geometry;
      if (currentGeometry != null) {
        final orderedStates = _orderedIds
            .map((id) => _viewStates[id])
            .whereType<GridCardViewState>()
            .toList(growable: false);
        final result = _layoutEngine.compute(
          geometry: currentGeometry,
          states: orderedStates,
        );
        _latestSnapshot = result.snapshot;

        debugPrint('[GridLayoutStore] snapshot_regenerated_after_aspect_ratio: '
            'newId=${_latestSnapshot?.id}');
      }

      // Notify listeners to update UI
      notifyListeners();
    }

    debugPrint('[GridLayoutStore] _resolveNewCardAspectRatios_complete: '
        'anyChanged=$anyChanged');
  }

  /// 全カードのアスペクト比を強制的に再解決し、Hiveとスナップショットを再同期。
  /// 再読み込みボタンから呼び出される。
  Future<void> forceFullResync() async {
    debugPrint('[GridLayoutStore] forceFullResync: starting, '
        'cardCount=${_orderedIds.length}');

    final geometry = _geometry;
    if (geometry == null) {
      debugPrint('[GridLayoutStore] forceFullResync: skipped - no geometry');
      return;
    }

    // キャッシュをクリアして実ファイルから再読み込みを強制
    _ratioResolver.clearCache();
    debugPrint('[GridLayoutStore] forceFullResync: cleared ratio cache');

    bool anyChanged = false;

    // 全カードのアスペクト比を再解決（customHeight関係なく）
    for (final id in _orderedIds) {
      final current = _viewStates[id];
      if (current == null) continue;

      // _items[id]がnullの場合のデバッグログ
      final item = _items[id];
      if (item == null) {
        debugPrint('[GridLayoutStore] forceFullResync: item is null for '
            'id=${id.split('/').last}');
      }

      // アスペクト比を解決
      final ratio = await _resolveAspectRatio(id, current);

      // 解決された比率のデバッグログ
      final currentRatio = current.width > 0
          ? current.height / current.width
          : 1.0;
      debugPrint('[GridLayoutStore] forceFullResync_ratio: '
          'id=${id.split('/').last}, '
          'ratio=${ratio.toStringAsFixed(4)}, '
          'currentRatio=${currentRatio.toStringAsFixed(4)}');
      if (!ratio.isFinite || ratio <= 0) continue;

      // 実際の幅を計算
      final span = current.columnSpan;
      final gapCount = math.max(0, span - 1);
      final gapWidth = geometry.gap * gapCount;
      final actualWidth = geometry.columnWidth * span + gapWidth;

      // 新しい高さを計算
      final newHeight = actualWidth * ratio;

      // 変更があるかチェック
      if ((current.width - actualWidth).abs() < 1.0 &&
          (current.height - newHeight).abs() < 1.0) {
        continue;
      }

      debugPrint('[GridLayoutStore] forceFullResync: updating '
          'id=${id.split('/').last}, '
          'oldSize=${current.width.toStringAsFixed(1)}x${current.height.toStringAsFixed(1)}, '
          'newSize=${actualWidth.toStringAsFixed(1)}x${newHeight.toStringAsFixed(1)}');

      // viewStateを更新
      final updated = GridCardViewState(
        id: id,
        width: actualWidth,
        height: newHeight,
        scale: current.scale,
        columnSpan: current.columnSpan,
        customHeight: newHeight,
        offsetDx: current.offsetDx,
        offsetDy: current.offsetDy,
      );
      _viewStates[id] = updated;
      anyChanged = true;

      // Notify that this card needs rebuild in ImageCard
      _notifyCardResized(id);
    }

    // Hiveに全カードを保存
    final mutations = _viewStates.values
        .map((s) => _recordFromState(s))
        .toList();
    if (mutations.isNotEmpty) {
      await _persistence.saveBatch(mutations);
      debugPrint('[GridLayoutStore] forceFullResync: saved ${mutations.length} records to Hive');
    }

    // スナップショットを再生成
    final orderedStates = _orderedIds
        .map((id) => _viewStates[id])
        .whereType<GridCardViewState>()
        .toList(growable: false);
    final result = _layoutEngine.compute(
      geometry: geometry,
      states: orderedStates,
    );

    if (_latestSnapshot != null) {
      _previousSnapshot = _latestSnapshot;
    }
    _latestSnapshot = result.snapshot;

    debugPrint('[GridLayoutStore] forceFullResync: complete, '
        'anyChanged=$anyChanged, snapshotId=${_latestSnapshot?.id}');

    notifyListeners();
  }
}
