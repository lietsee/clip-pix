import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/rendering.dart';

import '../../system/grid_layout_layout_engine.dart' as layout;
import '../../system/state/grid_geometry_queue.dart';
import '../../system/state/grid_layout_store.dart';
import 'grid_semantics_tree.dart';

typedef GridLayoutChildBuilder = Widget Function(
  BuildContext context,
  GridLayoutGeometry geometry,
  List<GridCardViewState> states,
  layout.LayoutSnapshot? snapshot,
  {bool isStaging}
);

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
    this.semanticsOverlayEnabled = true,
    this.geometryQueueEnabled = true,
  });

  final GridLayoutSurfaceStore store;
  final GridLayoutChildBuilder childBuilder;
  final double columnGap;
  final EdgeInsets padding;
  final GridColumnCountResolver resolveColumnCount;
  final void Function(bool hideGrid)? onMutateStart;
  final void Function(bool hideGrid)? onMutateEnd;
  final bool semanticsOverlayEnabled;
  final bool geometryQueueEnabled;

  @override
  State<GridLayoutSurface> createState() => _GridLayoutSurfaceState();
}

class _GridLayoutSurfaceState extends State<GridLayoutSurface> {
  GridLayoutGeometry? _lastReportedGeometry;
  bool _mutationInProgress = false;
  bool _waitingForSemantics = false;
  bool _semanticsExcluded = false;
  bool _gridHiddenForReset = false;
  Key _gridResetKey = UniqueKey();
  bool _waitingForPreCommitSemantics = false;
  static const _throttleDuration = Duration(milliseconds: 60);
  GridLayoutGeometry? _frontGeometry;
  List<GridCardViewState>? _frontStates;
  layout.LayoutSnapshot? _frontSnapshot;
  GridLayoutGeometry? _stagingGeometry;
  List<GridCardViewState>? _stagingStates;
  layout.LayoutSnapshot? _stagingSnapshot;
  layout.LayoutSnapshot? _semanticsSnapshot;
  bool _semanticsUpdateScheduled = false;
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
      oldWidget.store.removeListener(_handleStoreChanged);
      widget.store.addListener(_handleStoreChanged);
      _lastReportedGeometry = null;
    }
  }

  @override
  void dispose() {
    _store.removeListener(_handleStoreChanged);
    _geometryQueue.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
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

        if (_gridHiddenForReset) {
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
          excludeSemantics: _semanticsExcluded,
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
                excludeSemantics: false,
                isStaging: true,
              ),
            ),
          );
        }

        final semanticsSnapshot =
            widget.semanticsOverlayEnabled && !_semanticsExcluded
                ? _semanticsSnapshot
                : null;
        if (semanticsSnapshot != null) {
          final textDirection = Directionality.of(context);
          stackChildren.add(
            IgnorePointer(
              ignoring: true,
              child: Align(
                alignment: Alignment.topLeft,
                child: GridSemanticsTree(
                  snapshot: semanticsSnapshot,
                  textDirection: textDirection,
                ),
              ),
            ),
          );
        }

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
    required bool excludeSemantics,
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
    return ExcludeSemantics(
      excluding: excludeSemantics,
      child: child,
    );
  }

  void _handleStoreChanged() {
    if (!mounted) {
      return;
    }
    final latestSnapshot = _store.latestSnapshot;
    setState(() {
      if (!_mutationInProgress) {
        _frontStates = _cloneStates(_store.viewStates);
        _frontSnapshot = latestSnapshot;
        if (latestSnapshot != null) {
          _frontGeometry = latestSnapshot.geometry;
          _debugLog('front_snapshot_updated id=${latestSnapshot.id}');
        }
      }
    });
    _scheduleSemanticsUpdate();
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
        _store.updateGeometry(geometryCopy, notify: false);
        setState(() {
          _frontGeometry = geometryCopy;
          _frontStates = _cloneStates(_store.viewStates);
          _frontSnapshot = _store.latestSnapshot;
        });
        _scheduleSemanticsUpdate();
      });
      return;
    }
    _geometryQueue.enqueue(geometry, notify: shouldNotify);
  }

  void _scheduleSemanticsUpdate() {
    if (!widget.semanticsOverlayEnabled) {
      if (_semanticsSnapshot != null && !_semanticsUpdateScheduled) {
        _semanticsUpdateScheduled = true;
        _scheduleNextFrameSemanticsUpdate(() {
          if (!mounted) return;
          if (_semanticsSnapshot != null) {
            setState(() {
              _semanticsSnapshot = null;
            });
          }
        });
      }
      return;
    }

    final target = _frontSnapshot;
    if (target == null) {
      if (_semanticsSnapshot != null && !_semanticsUpdateScheduled) {
        _semanticsUpdateScheduled = true;
        _scheduleNextFrameSemanticsUpdate(() {
          if (!mounted) return;
          if (_semanticsSnapshot != null) {
            setState(() {
              _semanticsSnapshot = null;
            });
          }
        });
      }
      return;
    }

    if (_semanticsSnapshot?.id == target.id || _semanticsUpdateScheduled) {
      return;
    }

    _semanticsUpdateScheduled = true;
    _scheduleNextFrameSemanticsUpdate(() {
      if (!mounted) {
        return;
      }
      if (!widget.semanticsOverlayEnabled) {
        if (_semanticsSnapshot != null) {
          setState(() {
            _semanticsSnapshot = null;
          });
        }
        return;
      }
      final current = _frontSnapshot;
      if (current == null) {
        if (_semanticsSnapshot != null) {
          setState(() {
            _semanticsSnapshot = null;
          });
        }
        return;
      }
      if (_semanticsSnapshot?.id == current.id) {
        return;
      }
      setState(() {
        _semanticsSnapshot = current;
      });
    });
  }

  /// セマンティクス更新を2フレーム後まで遅延させる。
  ///
  /// endOfFrame → endOfFrame → addPostFrameCallback のパターンを使用することで、
  /// スナップショットスワップから2フレーム後にセマンティクス更新が行われる。
  /// これにより、PinterestSliverGrid のレイアウトと parentData の更新が
  /// 完全に完了した後にセマンティクスが更新され、_needsLayout と
  /// parentDataDirty アサーションの両方を回避できる。
  void _scheduleNextFrameSemanticsUpdate(VoidCallback updateCallback) {
    final startTime = DateTime.now();
    const maxDelay = Duration(seconds: 3);

    // 1フレーム目の終わりまで待つ
    SchedulerBinding.instance.endOfFrame.then((_) {
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed > maxDelay) {
        _debugLog(
            'semantics update timeout (${elapsed.inMilliseconds}ms); forcing update');
      }

      // 2フレーム目の終わりまで待つ
      SchedulerBinding.instance.endOfFrame.then((_) {
        // 3フレーム目の postFrameCallbacks で実行
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _semanticsUpdateScheduled = false;
          try {
            updateCallback();
          } catch (error, stackTrace) {
            _debugLog('semantics update error: $error');
            debugPrintStack(
                stackTrace: stackTrace, label: 'semantics_update_error');
          }
        });
      }).catchError((error, stackTrace) {
        // 2フレーム目の endOfFrame の Future が失敗した場合
        _debugLog('endOfFrame(2nd) error: $error; skipping semantics update');
        debugPrintStack(stackTrace: stackTrace, label: 'endOfFrame_2nd_error');
        _semanticsUpdateScheduled = false;
      });
    }).catchError((error, stackTrace) {
      // 1フレーム目の endOfFrame の Future が失敗した場合
      _debugLog('endOfFrame(1st) error: $error; skipping semantics update');
      debugPrintStack(stackTrace: stackTrace, label: 'endOfFrame_1st_error');
      _semanticsUpdateScheduled = false;
    });
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
    final shouldExcludeSemantics = !_semanticsExcluded || notify;

    if (shouldExcludeSemantics) {
      setState(() {
        _semanticsExcluded = true;
      });
      if (_hasPendingSemanticsUpdates()) {
        if (_waitingForPreCommitSemantics) {
          return;
        }
        _waitingForPreCommitSemantics = true;
        final waitCompleter = Completer<void>();
        SchedulerBinding.instance.endOfFrame.then((_) {
          Future.microtask(() {
            _waitingForPreCommitSemantics = false;
            waitCompleter.complete();
          });
        });
        await waitCompleter.future;
        if (!mounted || job.ticket.isCancelled) {
          return;
        }
      }
    }

    widget.onMutateStart?.call(notify);
    _mutationInProgress = true;
    bool mutationEndScheduled = false;

    try {
      final mutationCompleter = Completer<void>();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || job.ticket.isCancelled) {
          _mutationInProgress = false;
          _waitingForSemantics = false;
          if (!mutationCompleter.isCompleted) {
            mutationCompleter.complete();
          }
          return;
        }
        try {
          _debugLog(
            'geometry_commit geometry=$geometry notify=$notify taskPhase=${SchedulerBinding.instance.schedulerPhase}',
          );
          _logSemanticsStatus('commit_start notify=$notify');
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
          _scheduleSemanticsUpdate();
        } catch (error, stackTrace) {
          _debugLog('geometry_commit error: $error');
          debugPrintStack(stackTrace: stackTrace, label: 'geometry_commit');
        } finally {
          if (!mutationEndScheduled) {
            mutationEndScheduled = true;
            _scheduleMutationEnd(notify, job.ticket).whenComplete(() {
              if (mounted && !job.ticket.isCancelled) {
                try {
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
                      _gridResetKey = UniqueKey();
                      if (_frontSnapshot != null) {
                        _debugLog(
                            'front_snapshot_swapped id=${_frontSnapshot!.id}');
                      }
                    }
                  });
                  _scheduleSemanticsUpdate();
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
      // 最終フォールバック: もし何らかの理由で endMutation が呼ばれていなければ、ここで呼ぶ
      if (!mutationEndScheduled) {
        _debugLog(
            'FALLBACK: calling onMutateEnd because _scheduleMutationEnd was never invoked');
        widget.onMutateEnd?.call(notify);
        _mutationInProgress = false;
        _waitingForSemantics = false;
        if (_semanticsExcluded) {
          setState(() {
            _semanticsExcluded = false;
          });
        }
      }
    }
  }

  void _debugLog(String message) {
    // ignore: avoid_print
    debugPrint('[GridLayoutSurface] $message');
  }

  Future<void> _scheduleMutationEnd(
    bool hideGrid,
    GeometryMutationTicket ticket,
  ) {
    final completer = Completer<void>();
    final startTime = DateTime.now();
    const absoluteTimeout = Duration(seconds: 5);

    void finish() {
      if (!mounted) {
        _mutationInProgress = false;
        _waitingForSemantics = false;
        if (!completer.isCompleted) {
          completer.complete();
        }
        return;
      }
      widget.onMutateEnd?.call(hideGrid);
      _mutationInProgress = false;
      _waitingForSemantics = false;
      _logSemanticsStatus('mutate_end hide=$hideGrid');
      final shouldRestoreGrid = hideGrid && _gridHiddenForReset;
      final shouldRestoreSemantics = _semanticsExcluded;
      if (shouldRestoreGrid || shouldRestoreSemantics) {
        try {
          setState(() {
            if (shouldRestoreGrid) {
              _gridHiddenForReset = false;
            }
            if (shouldRestoreSemantics) {
              _semanticsExcluded = false;
            }
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

    final shouldWaitForSemantics = _semanticsExcluded && hideGrid;
    if (!shouldWaitForSemantics) {
      WidgetsBinding.instance.addPostFrameCallback((_) => finish());
      _logSemanticsStatus(
          hideGrid ? 'schedule_end_soft' : 'schedule_end_immediate');
      return completer.future;
    }

    if (_waitingForSemantics) {
      if (!completer.isCompleted) {
        completer.complete();
      }
      return completer.future;
    }
    _waitingForSemantics = true;
    var retries = 0;
    const maxRetries = 8;

    void scheduleNextWait() {
      SchedulerBinding.instance.endOfFrame.then((_) {
        Future.microtask(() {
          // 絶対タイムアウトチェック
          final elapsed = DateTime.now().difference(startTime);
          if (elapsed > absoluteTimeout) {
            _debugLog(
              'semantics wait ABSOLUTE TIMEOUT reached (${elapsed.inMilliseconds}ms); forcing finish()',
            );
            finish();
            return;
          }

          if (ticket.isCancelled) {
            finish();
            return;
          }
          if (_hasPendingSemanticsUpdates()) {
            retries += 1;
            if (retries >= maxRetries) {
              _debugLog(
                'semantics wait max retries reached; re-enabling semantics anyway',
              );
              finish();
              return;
            }
            scheduleNextWait();
            return;
          }
          _logSemanticsStatus(
            hideGrid ? 'schedule_end_hard' : 'schedule_end_semantics_only',
          );
          finish();
        });
      }).catchError((error, stackTrace) {
        // endOfFrame の Future が失敗した場合の保険
        _debugLog('scheduleNextWait endOfFrame error: $error; forcing finish()');
        debugPrintStack(
            stackTrace: stackTrace, label: 'scheduleNextWait_endOfFrame');
        finish();
      });
    }

    scheduleNextWait();
    return completer.future;
  }

  void _logSemanticsStatus(String label) {
    final binding = SemanticsBinding.instance;
    final semanticsOwner =
        RendererBinding.instance.pipelineOwner.semanticsOwner;
    final hasOwner = semanticsOwner != null;
    var needsUpdate = false;
    // `semanticsOwnerNeedsUpdate` は Flutter 3.22 以降で追加されたプロパティ。
    // 互換性を保つため dynamic 経由で参照し、存在しない場合は false 扱いにする。
    try {
      final pipelineOwner = RendererBinding.instance.pipelineOwner;
      // ignore: avoid_dynamic_calls
      final dynamicNeedsUpdate =
          (pipelineOwner as dynamic).semanticsOwnerNeedsUpdate;
      if (dynamicNeedsUpdate is bool) {
        needsUpdate = dynamicNeedsUpdate;
      }
    } catch (_) {
      needsUpdate = false;
    }
    final semanticsEnabled = binding?.semanticsEnabled ?? false;
    final phase = SchedulerBinding.instance.schedulerPhase;
    debugPrint(
      '[GridLayoutSurface] semantics $label hasOwner=$hasOwner needsUpdate=$needsUpdate '
      'semanticsEnabled=$semanticsEnabled schedulerPhase=$phase',
    );
  }

  bool _hasPendingSemanticsUpdates() {
    final pipelineOwner = RendererBinding.instance.pipelineOwner;
    try {
      // ignore: avoid_dynamic_calls
      final dynamic needsUpdate =
          (pipelineOwner as dynamic).semanticsOwnerNeedsUpdate;
      if (needsUpdate is bool && needsUpdate) {
        return true;
      }
    } catch (_) {
      // 無視: 古い Flutter バージョンではこのプロパティが存在しない
    }
    final semanticsOwner = pipelineOwner.semanticsOwner;
    if (semanticsOwner == null || !semanticsOwner.hasListeners) {
      return false;
    }
    final semanticsBinding = SemanticsBinding.instance;
    if (semanticsBinding != null) {
      try {
        // ignore: avoid_dynamic_calls
        final dynamic hasScheduled =
            (semanticsBinding as dynamic).hasScheduledSemanticsUpdate;
        if (hasScheduled is bool && hasScheduled) {
          return true;
        }
      } catch (_) {
        // 無視: プロパティが存在しない環境向け
      }
    }
    return false;
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
