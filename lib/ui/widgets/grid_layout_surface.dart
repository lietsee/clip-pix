import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../system/state/grid_layout_store.dart';

typedef GridLayoutChildBuilder = Widget Function(
  BuildContext context,
  GridLayoutGeometry geometry,
  List<GridCardViewState> states,
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
  });

  final GridLayoutSurfaceStore store;
  final GridLayoutChildBuilder childBuilder;
  final double columnGap;
  final EdgeInsets padding;
  final GridColumnCountResolver resolveColumnCount;
  final void Function(bool hideGrid)? onMutateStart;
  final void Function(bool hideGrid)? onMutateEnd;

  @override
  State<GridLayoutSurface> createState() => _GridLayoutSurfaceState();
}

class _GridLayoutSurfaceState extends State<GridLayoutSurface> {
  GridLayoutGeometry? _lastReportedGeometry;
  GridLayoutGeometry? _pendingGeometry;
  bool _pendingNotify = false;
  Timer? _geometryDebounceTimer;
  bool _semanticsTaskScheduled = false;
  bool _mutationInProgress = false;
  static const _throttleDuration = Duration(milliseconds: 40);

  GridLayoutSurfaceStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.addListener(_handleStoreChanged);
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
    _geometryDebounceTimer?.cancel();
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

        final child = widget.childBuilder(
          context,
          geometry,
          _store.viewStates,
        );

        if (widget.padding == EdgeInsets.zero) {
          return child;
        }
        return Padding(
          padding: widget.padding,
          child: child,
        );
      },
    );
  }

  void _handleStoreChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
  }

  void _maybeUpdateGeometry(GridLayoutGeometry geometry) {
    final previous = _lastReportedGeometry;
    if (previous != null && _geometryEquals(previous, geometry)) {
      return;
    }
    _lastReportedGeometry = geometry;
    final shouldNotify =
        previous == null || previous.columnCount != geometry.columnCount;
    _pendingGeometry = geometry;
    _pendingNotify = _pendingNotify || shouldNotify;
    final deltaWidth =
        previous != null ? (geometry.columnWidth - previous.columnWidth) : null;
    _debugLog(
      'geometry_pending prev=$previous next=$geometry shouldNotify=$shouldNotify pendingNotify=$_pendingNotify '
      'deltaWidth=${deltaWidth?.toStringAsFixed(3)}',
    );
    if (shouldNotify) {
      _geometryDebounceTimer?.cancel();
      _geometryDebounceTimer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _commitPending());
      return;
    }
    if (_geometryDebounceTimer != null) {
      return;
    }
    _geometryDebounceTimer = Timer(_throttleDuration, () {
      _geometryDebounceTimer = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _commitPending());
    });
  }

  bool _geometryEquals(GridLayoutGeometry a, GridLayoutGeometry b) {
    return a.columnCount == b.columnCount &&
        (a.columnWidth - b.columnWidth).abs() < 0.1 &&
        (a.gap - b.gap).abs() < 0.1;
  }

  void _commitPending() {
    if (!mounted) {
      return;
    }
    if (_semanticsTaskScheduled) {
      _debugLog('commit_pending skipped because task already scheduled');
      return;
    }
    if (_mutationInProgress) {
      _debugLog('commit_pending deferred: mutation in progress');
      return;
    }
    if (_pendingGeometry == null) {
      _pendingNotify = false;
      return;
    }
    _semanticsTaskScheduled = true;
    final debugLabel = 'GridLayoutSurface.commitPending';
    SchedulerBinding.instance.scheduleTask<void>(
      () {
        _semanticsTaskScheduled = false;
        if (!mounted) {
          _pendingGeometry = null;
          _pendingNotify = false;
          return;
        }
        final pending = _pendingGeometry;
        final notify = _pendingNotify;
        _pendingGeometry = null;
        _pendingNotify = false;
        if (pending == null) {
          return;
        }
        _debugLog(
          'geometry_commit geometry=$pending notify=$notify taskPhase=${SchedulerBinding.instance.schedulerPhase}',
        );
        final hideGrid = notify;
        widget.onMutateStart?.call(hideGrid);
        _mutationInProgress = true;
        try {
          _store.updateGeometry(pending, notify: notify);
        } finally {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) {
              return;
            }
            widget.onMutateEnd?.call(hideGrid);
            _mutationInProgress = false;
            if (_pendingGeometry != null && !_semanticsTaskScheduled) {
              _debugLog('commit_pending resume after end');
              _commitPending();
            }
          });
        }
      },
      Priority.touch,
      debugLabel: debugLabel,
    );
    _debugLog(
      'geometry_schedule geometry=$_pendingGeometry notify=$_pendingNotify label=$debugLabel',
    );
  }

  void _debugLog(String message) {
    // ignore: avoid_print
    debugPrint('[GridLayoutSurface] $message');
  }
}
