import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../system/grid_layout_layout_engine.dart' as layout;
import '../../system/state/grid_geometry_queue.dart';
import '../../system/state/grid_layout_store.dart';

typedef GridLayoutChildBuilder = Widget Function(
    BuildContext context,
    GridLayoutGeometry geometry,
    List<GridCardViewState> states,
    layout.LayoutSnapshot? snapshot,
    {bool isStaging});

typedef GridColumnCountResolver = int Function(double availableWidth);

class GridLayoutSurface extends StatefulWidget {
  const GridLayoutSurface({
    super.key,
    required this.store,
    required this.childBuilder,
    required this.columnGap,
    required this.padding,
    required this.resolveColumnCount,
    this.onMutateStart,
    this.onMutateEnd,
    this.geometryQueueEnabled = true,
  });

  final GridLayoutSurfaceStore store;
  final GridLayoutChildBuilder childBuilder;
  final double columnGap;
  final EdgeInsets padding;
  final GridColumnCountResolver resolveColumnCount;
  final void Function(bool hideGrid)? onMutateStart;
  final void Function(bool hideGrid)? onMutateEnd;
  final bool geometryQueueEnabled;

  @override
  State<GridLayoutSurface> createState() => _GridLayoutSurfaceState();
}

class _GridLayoutSurfaceState extends State<GridLayoutSurface> {
  GridLayoutGeometry? _lastReportedGeometry;
  bool _mutationInProgress = false;
  bool _mutationEndCalled = false;
  bool _gridHiddenForReset = false;
  Key _gridResetKey = UniqueKey();
  static const _throttleDuration = Duration(milliseconds: 60);
  GridLayoutGeometry? _frontGeometry;
  List<GridCardViewState>? _frontStates;
  layout.LayoutSnapshot? _frontSnapshot;
  GridLayoutGeometry? _stagingGeometry;
  List<GridCardViewState>? _stagingStates;
  layout.LayoutSnapshot? _stagingSnapshot;
  late final GeometryMutationQueue _geometryQueue;

  GridLayoutSurfaceStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_handleStoreChanged);
    if (widget.geometryQueueEnabled) {
      _geometryQueue = GeometryMutationQueue(
        worker: _processGeometryMutation,
        throttle: _throttleDuration,
      );
    } else {
      _geometryQueue = GeometryMutationQueue(
        worker: _processGeometryMutation,
        throttle: Duration.zero,
      );
    }
    _frontStates = _cloneStates(_store.viewStates);
    _frontSnapshot = _store.latestSnapshot;
    _frontGeometry = _frontSnapshot?.geometry ?? _frontGeometry;
  }

  @override
  void didUpdateWidget(covariant GridLayoutSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.store != widget.store) {
      print('[GridLayoutSurface] didUpdateWidget: store changed! '
          'Resetting listeners and _lastReportedGeometry');
      oldWidget.store.removeListener(_handleStoreChanged);
      widget.store.addListener(_handleStoreChanged);
      _lastReportedGeometry = null;
    } else {
      print('[GridLayoutSurface] didUpdateWidget: store unchanged');
    }
  }

  @override
  void dispose() {
    if (_mutationInProgress && !_mutationEndCalled) {
      widget.onMutateEnd?.call(false);
      _mutationInProgress = false;
      _mutationEndCalled = true;
    }
    _store.removeListener(_handleStoreChanged);
    _geometryQueue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        print('[GridLayoutSurface] build: '
            'mutationInProgress=$_mutationInProgress, '
            'gridHiddenForReset=$_gridHiddenForReset, '
            'hasStagingBuffer=${_stagingGeometry != null}, '
            'frontSnapshotId=${_frontSnapshot?.id}, '
            'frontStatesCount=${_frontStates?.length ?? 0}, '
            'storeViewStatesCount=${_store.viewStates.length}, '
            'constraints=$constraints');
        final double maxWidth = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.of(context).size.width;
        final double availableWidth = math.max(
          0,
          maxWidth - widget.padding.horizontal,
        );
        int columnCount = widget.resolveColumnCount(availableWidth);
        double columnWidth;
        if (columnCount <= 0) {
          columnCount = 1;
        }
        final double gapTotal = widget.columnGap * (columnCount - 1);
        if (availableWidth <= 0 || availableWidth <= gapTotal) {
          columnWidth = math.max(availableWidth, 0);
          columnCount = 1;
        } else {
          columnWidth = (availableWidth - gapTotal) / columnCount;
        }

        final geometry = GridLayoutGeometry(
          columnCount: columnCount,
          columnWidth: columnWidth,
          gap: widget.columnGap,
        );
        _maybeUpdateGeometry(geometry);

        // [FIX] Detect stale front snapshot and force sync
        // This catches cases where _handleStoreChanged wasn't called
        // (e.g., due to listener issues or job cancellation)
        final storeSnapshot = _store.latestSnapshot;
        if (storeSnapshot != null &&
            !identical(_frontSnapshot, storeSnapshot) &&
            !_mutationInProgress) {
          // Stale front buffer detected - schedule forced sync
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final currentStoreSnapshot = _store.latestSnapshot;
            if (currentStoreSnapshot != null &&
                !identical(_frontSnapshot, currentStoreSnapshot)) {
              setState(() {
                _frontSnapshot = currentStoreSnapshot;
                _frontStates = _cloneStates(_store.viewStates);
                _frontGeometry = currentStoreSnapshot.geometry;
                print('[GridLayoutSurface] forced_sync_applied: '
                    'snapshotId=${currentStoreSnapshot.id}');
              });
            }
          });
        }

        if (_gridHiddenForReset) {
          print('[GridLayoutSurface] RETURNING SizedBox.shrink due to _gridHiddenForReset=true');
          return const SizedBox.shrink();
        }

        final frontSnapshot = _frontSnapshot;
        final frontGeometry = frontSnapshot?.geometry ??
            _frontGeometry ??
            _lastReportedGeometry ??
            geometry;
        final frontStates = _frontStates ?? _cloneStates(_store.viewStates);
        final frontChild = _buildGridContent(
          context,
          frontGeometry,
          frontStates,
          snapshot: frontSnapshot,
          isStaging: false,
        );

        final List<Widget> stackChildren = [frontChild];

        if (_stagingGeometry != null && _stagingStates != null) {
          stackChildren.add(
            Offstage(
              offstage: true,
              child: _buildGridContent(
                context,
                _stagingGeometry!,
                _stagingStates!,
                snapshot: _stagingSnapshot,
                isStaging: true,
              ),
            ),
          );
        }

        print('[GridLayoutSurface] returning Stack: '
            'childrenCount=${stackChildren.length}, '
            'hasStagingChild=${stackChildren.length > 1}');

        return KeyedSubtree(
          key: _gridResetKey,
          child: Stack(
            fit: StackFit.passthrough,
            children: stackChildren,
          ),
        );
      },
    );
  }

  Widget _buildGridContent(
    BuildContext context,
    GridLayoutGeometry geometry,
    List<GridCardViewState> states, {
    layout.LayoutSnapshot? snapshot,
    required bool isStaging,
  }) {
    Widget child = widget.childBuilder(
      context,
      geometry,
      states,
      snapshot,
      isStaging: isStaging,
    );

    if (widget.padding != EdgeInsets.zero) {
      child = Padding(
        padding: widget.padding,
        child: child,
      );
    }
    return child;
  }

  void _handleStoreChanged() {
    if (!mounted) {
      return;
    }
    final latestSnapshot = _store.latestSnapshot;

    print('[GridLayoutSurface] store_changed: '
        'newSnapshot=${latestSnapshot?.id}, '
        'viewStateCount=${_store.viewStates.length}');

    // ALWAYS update front buffer when store notifies
    // This ensures order changes from syncLibrary are immediately reflected
    // regardless of mutation state. The minimap uses layoutStore.latestSnapshot
    // directly, so we must keep _frontSnapshot in sync to avoid discrepancies.
    setState(() {
      _frontStates = _cloneStates(_store.viewStates);
      _frontSnapshot = latestSnapshot;
      if (latestSnapshot != null) {
        _frontGeometry = latestSnapshot.geometry;
      }
      print('[GridLayoutSurface] front_buffer_updated: '
          'snapshotId=${latestSnapshot?.id}, statesCount=${_frontStates?.length ?? 0}');
    });
  }

  void _maybeUpdateGeometry(GridLayoutGeometry geometry) {
    final previous = _lastReportedGeometry;
    if (previous != null && _geometryEquals(previous, geometry)) {
      return;
    }
    _lastReportedGeometry = geometry;
    final shouldNotify =
        previous == null || previous.columnCount != geometry.columnCount;
    final deltaWidth =
        previous != null ? (geometry.columnWidth - previous.columnWidth) : null;
    _debugLog(
      'geometry_enqueued prev=$previous next=$geometry shouldNotify=$shouldNotify '
      'deltaWidth=${deltaWidth?.toStringAsFixed(3)}',
    );
    if (!widget.geometryQueueEnabled) {
      final geometryCopy = geometry;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        _store.updateGeometry(geometryCopy);
        setState(() {
          _frontGeometry = geometryCopy;
          _frontStates = _cloneStates(_store.viewStates);
          _frontSnapshot = _store.latestSnapshot;
        });
      });
      return;
    }
    _geometryQueue.enqueue(geometry, notify: shouldNotify);
  }

  bool _geometryEquals(GridLayoutGeometry a, GridLayoutGeometry b) {
    return a.columnCount == b.columnCount &&
        (a.columnWidth - b.columnWidth).abs() < 0.1 &&
        (a.gap - b.gap).abs() < 0.1;
  }

  Future<void> _processGeometryMutation(GeometryMutationJob job) async {
    if (!mounted || job.ticket.isCancelled) {
      return;
    }

    final geometry = job.geometry;
    final notify = job.notify;

    _mutationInProgress = true;
    _mutationEndCalled = false;
    widget.onMutateStart?.call(notify);
    bool mutationEndScheduled = false;

    try {
      final mutationCompleter = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || job.ticket.isCancelled) {
          _mutationInProgress = false;
          if (!mutationCompleter.isCompleted) {
            mutationCompleter.complete();
          }
          return;
        }
        try {
          _debugLog(
            'geometry_commit geometry=$geometry notify=$notify taskPhase=${SchedulerBinding.instance.schedulerPhase}',
          );
          _store.updateGeometry(geometry, notify: notify);
          final states = _cloneStates(_store.viewStates);
          final latestSnapshot = _store.latestSnapshot;
          setState(() {
            _stagingGeometry = geometry;
            _stagingStates = states;
            _stagingSnapshot = latestSnapshot;
            if (latestSnapshot != null) {
              _debugLog('staging_snapshot_ready id=${latestSnapshot.id}');
            }
          });
        } catch (error, stackTrace) {
          _debugLog('geometry_commit error: $error');
          debugPrintStack(stackTrace: stackTrace, label: 'geometry_commit');
        } finally {
          if (!mutationEndScheduled) {
            mutationEndScheduled = true;
            _scheduleMutationEnd(notify).whenComplete(() {
              if (mounted && !job.ticket.isCancelled) {
                try {
                  print('[GridLayoutSurface] swapping staging to front: '
                      'stagingGeometry=$_stagingGeometry, '
                      'stagingStatesCount=${_stagingStates?.length ?? 0}, '
                      'stagingSnapshotId=${_stagingSnapshot?.id}');
                  setState(() {
                    if (_stagingGeometry != null && _stagingStates != null) {
                      _frontGeometry =
                          _stagingSnapshot?.geometry ?? _stagingGeometry;
                      _frontStates = _stagingStates;
                      _frontSnapshot = _stagingSnapshot;
                      _stagingGeometry = null;
                      _stagingStates = null;
                      _stagingSnapshot = null;
                      _gridHiddenForReset = false;
                      print('[GridLayoutSurface] front_snapshot_swapped: '
                          'id=${_frontSnapshot?.id}, '
                          'frontStatesCount=${_frontStates?.length ?? 0}, '
                          '_gridHiddenForReset=$_gridHiddenForReset');
                    }
                  });
                } catch (error, stackTrace) {
                  _debugLog('front_snapshot_swap error: $error');
                  debugPrintStack(
                      stackTrace: stackTrace, label: 'front_snapshot_swap');
                }
              }
              if (!mutationCompleter.isCompleted) {
                mutationCompleter.complete();
              }
            });
          }
        }
      });

      await mutationCompleter.future;
    } catch (error, stackTrace) {
      _debugLog('_processGeometryMutation error: $error');
      debugPrintStack(
          stackTrace: stackTrace, label: '_processGeometryMutation');
    } finally {
      if (!mutationEndScheduled) {
        _debugLog(
            'FALLBACK: calling onMutateEnd because _scheduleMutationEnd was never invoked');
        widget.onMutateEnd?.call(notify);
        _mutationInProgress = false;
      }
    }
  }

  void _debugLog(String message) {
    debugPrint('[GridLayoutSurface] $message');
  }

  Future<void> _scheduleMutationEnd(bool hideGrid) {
    final completer = Completer<void>();

    void finish() {
      // 重複呼び出し防止
      if (_mutationEndCalled) {
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      _mutationEndCalled = true;

      final callback = widget.onMutateEnd;
      _mutationInProgress = false;

      print('[GridLayoutSurface] finish: '
          'hideGrid=$hideGrid, _gridHiddenForReset=$_gridHiddenForReset, mounted=$mounted');

      if (!mounted) {
        callback?.call(hideGrid);
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      callback?.call(hideGrid);
      _debugLog('mutate_end hide=$hideGrid');
      final shouldRestoreGrid = hideGrid && _gridHiddenForReset;
      if (shouldRestoreGrid) {
        print('[GridLayoutSurface] finish: restoring grid, setting _gridHiddenForReset=false');
        try {
          setState(() {
            _gridHiddenForReset = false;
          });
        } catch (error, stackTrace) {
          _debugLog('finish setState error: $error');
          debugPrintStack(stackTrace: stackTrace, label: 'finish_setState');
        }
      }
      if (!completer.isCompleted) {
        completer.complete();
      }
    }

    // endOfFrame でレイアウト完了を待ってから終了
    SchedulerBinding.instance.endOfFrame.then((_) {
      if (!mounted) {
        finish();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) => finish());
    }).catchError((error) {
      _debugLog('endOfFrame error: $error');
      finish();
    });

    return completer.future;
  }

  List<GridCardViewState> _cloneStates(List<GridCardViewState> states) {
    return states
        .map(
          (s) => GridCardViewState(
            id: s.id,
            width: s.width,
            height: s.height,
            scale: s.scale,
            columnSpan: s.columnSpan,
            customHeight: s.customHeight,
          ),
        )
        .toList(growable: false);
  }
}
