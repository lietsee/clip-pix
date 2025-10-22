import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';

import '../data/grid_card_preferences_repository.dart';
import '../data/grid_layout_settings_repository.dart';
import '../data/grid_order_repository.dart';
import '../data/models/grid_layout_settings.dart';
import '../data/models/image_item.dart';
import '../system/clipboard_copy_service.dart';
import '../system/state/folder_view_mode.dart';
import '../system/state/grid_resize_controller.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import '../system/state/selected_folder_state.dart';
import 'image_card.dart';
import 'image_preview_window.dart';
import 'widgets/pinterest_grid.dart';

class GridViewModule extends StatefulWidget {
  const GridViewModule({super.key, required this.state, this.controller});

  final ImageLibraryState state;
  final ScrollController? controller;

  @override
  State<GridViewModule> createState() => _GridViewModuleState();
}

class _GridViewModuleState extends State<GridViewModule> {
  static const Duration _animationDuration = Duration(milliseconds: 200);
  static const double _outerPadding = 12;
  static const double _gridGap = 3;

  late GridCardPreferencesRepository _preferences;
  bool _isInitialized = false;

  final Map<String, ValueNotifier<Size>> _sizeNotifiers = {};
  final Map<String, ValueNotifier<double>> _scaleNotifiers = {};
  final Map<String, Timer> _scaleDebounceTimers = {};
  final Map<String, ScrollController> _directoryControllers = {};
  final Map<String, VoidCallback> _sizeListeners = {};
  final Map<String, GlobalKey> _cardKeys = {};
  GridLayoutSettingsRepository? _layoutSettingsRepository;
  GridOrderRepository? _orderRepository;
  GridResizeController? _resizeController;
  GridResizeListener? _resizeListener;
  double _lastViewportWidth = 0;
  double _lastAvailableWidth = 0;
  int _lastColumnCount = 1;
  OverlayEntry? _dragOverlay;
  String? _draggingId;
  Offset _dragOverlayOffset = Offset.zero;
  Offset _dragPointerOffset = Offset.zero;
  Size _draggedSize = Size.zero;
  int? _dragInitialIndex;
  _GridEntry? _draggedEntry;
  int? _pendingPointerId;
  String? _pendingPointerCardId;
  int? _activePointerId;
  OverlayEntry? _dropIndicatorOverlay;
  Rect? _dropIndicatorRect;
  int? _dropInsertIndex;

  List<_GridEntry> _entries = <_GridEntry>[];
  bool _loggedInitialBuild = false;
  final Set<Object> _currentBuildKeys = <Object>{};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      _preferences = context.read<GridCardPreferencesRepository>();
      _layoutSettingsRepository = context.read<GridLayoutSettingsRepository>();
      _orderRepository = context.read<GridOrderRepository>();
      final orderedImages = _applyDirectoryOrder(widget.state.images);
      _entries = orderedImages.map(_createEntry).toList(growable: true);
      for (final item in orderedImages) {
        _ensureNotifiers(item);
      }
      setState(() {
        _isInitialized = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final entry in _entries) {
          _animateEntryVisible(entry);
        }
      });
    }
    _attachResizeController();
  }

  @override
  void didUpdateWidget(covariant GridViewModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isInitialized) {
      return;
    }
    if (!listEquals(oldWidget.state.images, widget.state.images)) {
      _reconcileEntries(widget.state.images);
    } else {
      final orderedImages = _applyDirectoryOrder(widget.state.images);
      for (final item in orderedImages) {
        _ensureNotifiers(item);
      }
    }
  }

  @override
  void dispose() {
    for (final entry in _entries) {
      entry.removalTimer?.cancel();
    }
    for (final controller in _directoryControllers.values) {
      controller.dispose();
    }
    for (final timer in _scaleDebounceTimers.values) {
      timer.cancel();
    }
    _sizeNotifiers.forEach((key, notifier) {
      final listener = _sizeListeners[key];
      if (listener != null) {
        notifier.removeListener(listener);
      }
      notifier.dispose();
    });
    _sizeListeners.clear();
    for (final notifier in _scaleNotifiers.values) {
      notifier.dispose();
    }
    _detachResizeController();
    _detachResizeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.state.isLoading && widget.state.images.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_entries.where((entry) => !entry.isRemoving).isEmpty) {
      return const Center(child: Text('フォルダ内に画像がありません'));
    }

    final libraryNotifier = context.read<ImageLibraryNotifier>();
    final selectedState = context.watch<SelectedFolderState>();

    if (!_loggedInitialBuild) {
      _loggedInitialBuild = true;
      _logEntries('build_init', _entries);
    }

    return RefreshIndicator(
      onRefresh: () => libraryNotifier.refresh(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          _orderRepository = context.watch<GridOrderRepository>();
          final settingsRepo = context.watch<GridLayoutSettingsRepository>();
          final settings = settingsRepo.value;
          final controller = _resolveController(selectedState);

          final viewportWidth = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.of(context).size.width;
          final availableWidth =
              math.max(0.0, viewportWidth - (_outerPadding * 2));
          _lastViewportWidth = viewportWidth;
          _lastAvailableWidth = availableWidth;
          final effectiveColumns = _resolveColumnCount(
            availableWidth,
            settings,
          );
          _lastColumnCount = effectiveColumns;
          final gridDelegate = PinterestGridDelegate(
            columnCount: effectiveColumns,
            gap: _gridGap,
          );
          final columnWidth = _calculateColumnWidth(effectiveColumns);
          final backgroundColor = _backgroundForTone(settings.background);
          _currentBuildKeys.clear();

          return Container(
            color: backgroundColor,
            child: CustomScrollView(
              controller: controller,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: _outerPadding,
                    vertical: _outerPadding,
                  ).copyWith(bottom: _outerPadding + 68),
                  sliver: PinterestSliverGrid(
                    gridDelegate: gridDelegate,
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        if (index >= _entries.length) {
                          return null;
                        }
                        final entry = _entries[index];
                        final item = entry.item;
                        final sizeNotifier = _sizeNotifiers[item.id]!;
                        final scaleNotifier = _scaleNotifiers[item.id]!;
                        final pref = _preferences.getOrCreate(item.id);
                        final currentSize = sizeNotifier.value;
                        final inferredSpan = _spanFromWidth(
                          currentSize.width,
                          columnWidth,
                          gridDelegate.columnCount,
                        );
                        final storedSpan =
                            pref.columnSpan.clamp(1, gridDelegate.columnCount);
                        final span = currentSize.width > 0
                            ? inferredSpan.clamp(
                                1,
                                gridDelegate.columnCount,
                              )
                            : storedSpan;
                        final desiredWidth = _spanWidth(span, columnWidth);

                        if ((currentSize.width - desiredWidth).abs() > 0.5) {
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (!mounted) return;
                            sizeNotifier.value =
                                Size(desiredWidth, currentSize.height);
                          });
                        }

                        final cardWidget = _buildCard(
                          entry: entry,
                          sizeNotifier: sizeNotifier,
                          scaleNotifier: scaleNotifier,
                          columnWidth: columnWidth,
                          columnCount: gridDelegate.columnCount,
                          span: span,
                        );
                        return PinterestGridTile(
                          span: span,
                          child: cardWidget,
                        );
                      },
                      childCount: _entries.length,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: false,
                      addSemanticIndexes: false,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildCard({
    required _GridEntry entry,
    required ValueNotifier<Size> sizeNotifier,
    required ValueNotifier<double> scaleNotifier,
    required double columnWidth,
    required int columnCount,
    required int span,
  }) {
    final item = entry.item;
    final animatedKey = ObjectKey(entry);
    final entryHash = identityHashCode(entry);
    debugPrint(
      '[GridViewModule] build_child key=$animatedKey entryHash=$entryHash removing=${entry.isRemoving} dragging=${entry.isDragging} opacity=${entry.opacity.toStringAsFixed(2)}',
    );
    if (!_currentBuildKeys.add(animatedKey)) {
      debugPrint(
        '[GridViewModule] duplicate_detected key=$animatedKey entryHash=$entryHash',
      );
    }
    final cardKey = _cardKeys.putIfAbsent(item.id, () => GlobalKey());
    return SizedBox(
      key: cardKey,
      child: AnimatedOpacity(
        key: animatedKey,
        duration: _animationDuration,
        opacity: entry.opacity,
        child: ImageCard(
          item: item,
          sizeNotifier: sizeNotifier,
          scaleNotifier: scaleNotifier,
          onResize: _handleResize,
          onSpanChange: _handleSpanChange,
          onZoom: _handleZoom,
          onRetry: _handleRetry,
          onOpenPreview: _showPreviewDialog,
          onCopyImage: _handleCopy,
          columnWidth: columnWidth,
          columnCount: columnCount,
          columnGap: _gridGap,
          onReorderPointerDown: _handleReorderPointerDown,
          onStartReorder: _startReorder,
          onReorderUpdate: _updateReorder,
          onReorderEnd: _endReorder,
          onReorderCancel: _handleReorderCancel,
        ),
      ),
    );
  }

  void _handleCopy(ImageItem item) async {
    final copyService = context.read<ClipboardCopyService>();
    try {
      await copyService.copyImage(item);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('クリップボードにコピーしました')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('コピーに失敗しました')));
    }
  }

  void _handleRetry(String id) {
    final item = widget.state.images.firstWhere(
      (image) => image.id == id,
      orElse: () => _entries.firstWhere((entry) => entry.item.id == id).item,
    );
    final notifier = context.read<ImageLibraryNotifier>();
    unawaited(notifier.addOrUpdate(File(item.filePath)));
  }

  void _handleResize(String id, Size newSize) {
    unawaited(_preferences.saveSize(id, newSize));
  }

  void _handleZoom(String id, double scale) {
    _scaleDebounceTimers[id]?.cancel();
    _scaleDebounceTimers[id] = Timer(const Duration(milliseconds: 150), () {
      unawaited(_preferences.saveScale(id, scale));
    });
  }

  void _handleSpanChange(String id, int span) {
    unawaited(_preferences.saveColumnSpan(id, span));
    if (mounted) {
      setState(() {});
    }
  }

  ScrollController _resolveController(SelectedFolderState selectedState) {
    if (selectedState.viewMode == FolderViewMode.root &&
        widget.controller != null) {
      return widget.controller!;
    }
    final directory = widget.state.activeDirectory;
    final key = directory?.path ?? '_root';
    return _directoryControllers.putIfAbsent(key, () => ScrollController());
  }

  _GridEntry _createEntry(ImageItem item) {
    _ensureNotifiers(item);
    return _GridEntry(item: item, opacity: 0);
  }

  void _ensureNotifiers(ImageItem item) {
    _sizeNotifiers.putIfAbsent(item.id, () {
      final pref =
          _preferences.get(item.id) ?? _preferences.getOrCreate(item.id);
      final notifier = ValueNotifier<Size>(pref.size);
      _attachSizeListener(item.id, notifier);
      return notifier;
    });
    if (!_sizeListeners.containsKey(item.id)) {
      _attachSizeListener(item.id, _sizeNotifiers[item.id]!);
    }
    _scaleNotifiers.putIfAbsent(item.id, () {
      final pref =
          _preferences.get(item.id) ?? _preferences.getOrCreate(item.id);
      return ValueNotifier<double>(pref.scale);
    });
  }

  void _reconcileEntries(List<ImageItem> newItems) {
    final orderedItems = _applyDirectoryOrder(newItems);
    _logEntries('reconcile_before', _entries);
    final duplicateIncoming = _findDuplicateIds(
      orderedItems.map((item) => item.id),
    );
    if (duplicateIncoming.isNotEmpty) {
      debugPrint(
        '[GridViewModule] incoming duplicates detected: $duplicateIncoming',
      );
    }
    final newIds = orderedItems.map((item) => item.id).toSet();
    final existingMap = {for (final entry in _entries) entry.item.id: entry};

    for (final entry in _entries) {
      if (!newIds.contains(entry.item.id) && !entry.isRemoving) {
        entry.isRemoving = true;
        entry.opacity = 0;
        entry.removalTimer?.cancel();
        entry.removalTimer = Timer(_animationDuration, () {
          if (!mounted) return;
          setState(() {
            _entries.remove(entry);
            _disposeEntry(entry);
          });
          _logEntries('reconcile_remove', _entries);
        });
      }
    }

    final List<_GridEntry> reordered = <_GridEntry>[];
    for (final item in orderedItems) {
      final existing = existingMap[item.id];
      if (existing != null) {
        existing.item = item;
        if (existing.isRemoving) {
          existing.removalTimer?.cancel();
          existing.isRemoving = false;
        }
        if (existing.opacity != 1) {
          existing.opacity = 1;
        }
        existing.version += 1;
        reordered.add(existing);
      } else {
        final entry = _createEntry(item);
        reordered.add(entry);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            _animateEntryVisible(entry);
          }
        });
      }
    }

    for (final entry in _entries) {
      if (entry.isRemoving && !reordered.contains(entry)) {
        reordered.add(entry);
      }
    }

    _logEntries('reconcile_after_pending', reordered);
    setState(() {
      _entries = reordered;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _logEntries('reconcile_after_post', _entries);
    });
  }

  void _animateEntryVisible(_GridEntry entry) {
    if (!mounted) {
      return;
    }
    if (entry.opacity == 1) {
      return;
    }
    setState(() {
      entry.opacity = 1;
    });
  }

  void _disposeEntry(_GridEntry entry) {
    entry.removalTimer?.cancel();
    entry.removalTimer = null;
    final id = entry.item.id;
    _scaleDebounceTimers.remove(id)?.cancel();
    final sizeNotifier = _sizeNotifiers.remove(id);
    final sizeListener = _sizeListeners.remove(id);
    if (sizeNotifier != null && sizeListener != null) {
      sizeNotifier.removeListener(sizeListener);
    }
    sizeNotifier?.dispose();
    _scaleNotifiers.remove(id)?.dispose();
  }

  void _attachSizeListener(String id, ValueNotifier<Size> notifier) {
    final existing = _sizeListeners[id];
    if (existing != null) {
      notifier.removeListener(existing);
    }
    void listener() {
      if (mounted) {
        setState(() {});
      }
    }

    notifier.addListener(listener);
    _sizeListeners[id] = listener;
  }

  void _showPreviewDialog(ImageItem item) {
    final copyService = context.read<ClipboardCopyService>();
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (routeContext) => ImagePreviewWindow(
          item: item,
          initialAlwaysOnTop: false,
          onClose: () {},
          onToggleAlwaysOnTop: (_) {},
          onCopyImage: (image) => copyService.copyImage(image),
        ),
      ),
    );
  }

  void _logEntries(String label, List<_GridEntry> entries) {
    final counts = <String, int>{};
    for (final entry in entries) {
      final key = '${entry.item.id}_${entry.version}';
      counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    }
    final duplicates = counts.entries
        .where((element) => element.value > 1)
        .map((e) => e.key)
        .toList();
    debugPrint(
      '[GridViewModule] $label total=${entries.length} removing=${entries.where((e) => e.isRemoving).length} duplicates=$duplicates entries=${entries.map((e) => '${e.item.id}|v${e.version}|rem=${e.isRemoving}|opacity=${e.opacity.toStringAsFixed(2)}').join(', ')}',
    );
  }

  List<String> _findDuplicateIds(Iterable<String> ids) {
    final seen = <String>{};
    final duplicates = <String>[];
    for (final id in ids) {
      if (!seen.add(id)) {
        duplicates.add(id);
      }
    }
    return duplicates;
  }

  int _resolveColumnCount(double availableWidth, GridLayoutSettings settings) {
    if (availableWidth <= 0) {
      return 1;
    }
    final maxColumns = settings.maxColumns;
    final preferred = settings.preferredColumns;
    final target = preferred.clamp(1, maxColumns);
    final minColumnWidth = 150.0;
    final maxPossible = math.max(1, (availableWidth / minColumnWidth).floor());
    return math.max(1, math.min(target, maxPossible));
  }

  int _resolveSpan(double storedWidth, double availableWidth, int columnCount) {
    if (columnCount <= 0) {
      return 1;
    }
    final gapTotal = _gridGap * (columnCount - 1);
    final columnWidth = (availableWidth - gapTotal) / columnCount;
    if (columnWidth <= 0) {
      return 1;
    }
    final rawSpan = (storedWidth / columnWidth).round();
    return rawSpan.clamp(1, columnCount);
  }

  Color _backgroundForTone(GridBackgroundTone tone) {
    switch (tone) {
      case GridBackgroundTone.white:
        return Colors.white;
      case GridBackgroundTone.lightGray:
        return const Color(0xFFF0F0F0);
      case GridBackgroundTone.darkGray:
        return const Color(0xFF2E2E2E);
      case GridBackgroundTone.black:
        return Colors.black;
    }
  }

  void _attachResizeController() {
    final controller = context.read<GridResizeController>();
    if (_resizeController == controller) {
      return;
    }
    _detachResizeController();
    _resizeController = controller;
    _resizeListener = _handleResizeCommand;
    controller.attach(_resizeListener!);
  }

  void _detachResizeController() {
    final controller = _resizeController;
    final listener = _resizeListener;
    if (controller != null && listener != null) {
      controller.detach(listener);
    }
    _resizeController = null;
    _resizeListener = null;
  }

  Future<GridResizeSnapshot?> _handleResizeCommand(
    GridResizeCommand command,
  ) async {
    switch (command.type) {
      case GridResizeCommandType.apply:
        final span = command.span;
        if (span == null || _entries.isEmpty) {
          return null;
        }
        final snapshot = _captureSnapshot();
        await _applyBulkSpan(span);
        return snapshot;
      case GridResizeCommandType.undo:
        final snapshot = command.snapshot;
        if (snapshot == null) {
          return null;
        }
        final redoSnapshot = _captureSnapshot();
        await _restoreSnapshot(snapshot);
        return redoSnapshot;
      case GridResizeCommandType.redo:
        final snapshot = command.snapshot;
        if (snapshot == null) {
          return null;
        }
        final undoSnapshot = _captureSnapshot();
        await _restoreSnapshot(snapshot);
        return undoSnapshot;
    }
  }

  GridResizeSnapshot _captureSnapshot() {
    final values = <String, GridCardSizeSnapshot>{};
    for (final entry in _entries) {
      final item = entry.item;
      final sizeNotifier = _sizeNotifiers[item.id];
      if (sizeNotifier == null) {
        continue;
      }
      final size = sizeNotifier.value;
      final pref = _preferences.getOrCreate(item.id);
      values[item.id] = GridCardSizeSnapshot(
        width: size.width,
        height: size.height,
        columnSpan: pref.columnSpan,
        customHeight: pref.customHeight,
      );
    }
    return GridResizeSnapshot(
      directoryPath: widget.state.activeDirectory?.path,
      values: values,
    );
  }

  Future<void> _applyBulkSpan(int span) async {
    final columnCount = math.max(1, _lastColumnCount);
    final clampedSpan = span.clamp(1, columnCount);
    final columnWidth = _calculateColumnWidth(columnCount);
    if (columnWidth <= 0) {
      return;
    }
    final futures = <Future<void>>[];
    for (final entry in _entries) {
      final item = entry.item;
      final sizeNotifier = _sizeNotifiers[item.id];
      if (sizeNotifier == null) {
        continue;
      }
      final currentSize = sizeNotifier.value;
      final ratio = currentSize.width > 0
          ? (currentSize.height / currentSize.width)
          : 1.0;
      final width = columnWidth * clampedSpan +
          _gridGap * math.max(0.0, (clampedSpan - 1).toDouble());
      final height = ratio.isFinite && ratio > 0 ? width * ratio : width;
      sizeNotifier.value = Size(width, height);
      futures.add(_preferences.saveSize(item.id, Size(width, height)));
      futures.add(_preferences.saveColumnSpan(item.id, clampedSpan));
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _restoreSnapshot(GridResizeSnapshot snapshot) async {
    final futures = <Future<void>>[];
    for (final entry in _entries) {
      final item = entry.item;
      final saved = snapshot.values[item.id];
      if (saved == null) {
        continue;
      }
      final sizeNotifier = _sizeNotifiers[item.id];
      sizeNotifier?.value = Size(saved.width, saved.height);
      futures
          .add(_preferences.saveSize(item.id, Size(saved.width, saved.height)));
      futures.add(_preferences.saveColumnSpan(item.id, saved.columnSpan));
      futures.add(_preferences.saveCustomHeight(item.id, saved.customHeight));
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }
    if (mounted) {
      setState(() {});
    }
  }

  double _calculateColumnWidth(int columnCount) {
    if (columnCount <= 0) {
      return 0;
    }
    final totalGap = _gridGap * (columnCount - 1);
    final width = _lastAvailableWidth - totalGap;
    if (width <= 0) {
      return 0;
    }
    return width / columnCount;
  }

  double _spanWidth(int span, double columnWidth) {
    return columnWidth * span + _gridGap * math.max(0.0, (span - 1).toDouble());
  }

  int _spanFromWidth(
    double width,
    double columnWidth,
    int columnCount,
  ) {
    if (columnWidth <= 0 || columnCount <= 0 || width <= 0) {
      return 1;
    }
    final unit = columnWidth + _gridGap;
    if (unit <= 0) {
      return 1;
    }
    final normalized = (width + _gridGap) / unit;
    if (!normalized.isFinite) {
      return 1;
    }
    final rounded = normalized.round();
    return rounded.clamp(1, columnCount);
  }

  List<ImageItem> _applyDirectoryOrder(List<ImageItem> items) {
    final path = widget.state.activeDirectory?.path;
    final repo = _orderRepository;
    if (path == null || repo == null) {
      return items;
    }
    final stored = repo.getOrder(path);
    debugPrint(
        '[GridViewModule] apply order path=$path stored=$stored incoming=${items.map((e) => e.id).toList()}');
    if (items.isEmpty) {
      debugPrint('[GridViewModule] incoming empty; skip reorder');
      return items;
    }
    final ids = items.map((item) => item.id).toList();
    final currentSet = ids.toSet();
    final orderedIds = <String>[];
    for (final id in stored) {
      if (currentSet.contains(id)) {
        orderedIds.add(id);
      }
    }
    for (final id in ids) {
      if (!orderedIds.contains(id)) {
        orderedIds.add(id);
      }
    }
    if (!listEquals(stored, orderedIds)) {
      scheduleMicrotask(() => repo.save(path, orderedIds));
    }
    final map = {for (final item in items) item.id: item};
    final orderedItems = <ImageItem>[];
    for (final id in orderedIds) {
      final item = map[id];
      if (item != null) {
        orderedItems.add(item);
      }
    }
    return orderedItems;
  }

  Future<void> _persistOrder() async {
    final path = widget.state.activeDirectory?.path;
    final repo = _orderRepository;
    if (path == null || repo == null) {
      return;
    }
    final order = _entries.map((entry) => entry.item.id).toList();
    debugPrint('[GridViewModule] persist order path=$path order=$order');
    await repo.save(path, order);
  }

  void _handleReorderPointerDown(String id, int pointerId) {
    if (_draggingId != null && _draggingId != id) {
      return;
    }
    _pendingPointerId = pointerId;
    _pendingPointerCardId = id;
    debugPrint(
      '[GridViewModule] reorder_pointer_down id=$id pointer=$pointerId dragging=$_draggingId',
    );
  }

  void _handleReorderCancel(String id) {
    if (_draggingId != id) {
      return;
    }
    debugPrint('[GridViewModule] reorder_cancel id=$id');
    _endReorder(id, canceled: true);
  }

  void _startReorder(String id, Offset globalPosition) {
    debugPrint(
      '[GridViewModule] reorder_start request id=$id global=${globalPosition.dx.toStringAsFixed(1)},${globalPosition.dy.toStringAsFixed(1)} dragging=$_draggingId overlay=${_dragOverlay != null}',
    );
    if (_draggingId != null) {
      debugPrint(
        '[GridViewModule] reorder_start ignored reason=already_dragging active=$_draggingId',
      );
      return;
    }
    final key = _cardKeys[id];
    final cardContext = key?.currentContext;
    if (cardContext == null) {
      debugPrint(
          '[GridViewModule] reorder_start abort reason=no_context id=$id');
      return;
    }
    final box = cardContext.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      debugPrint('[GridViewModule] reorder_start abort reason=no_size id=$id');
      return;
    }
    final overlayState = Overlay.of(cardContext);
    if (overlayState == null) {
      debugPrint(
          '[GridViewModule] reorder_start abort reason=no_overlay id=$id');
      return;
    }
    final origin = box.localToGlobal(Offset.zero);
    _dragPointerOffset = globalPosition - origin;
    _dragOverlayOffset = origin;
    _draggedSize = box.size;
    _draggingId = id;
    _dragInitialIndex = _entries.indexWhere((entry) => entry.item.id == id);
    debugPrint(
      '[GridViewModule] reorder_start metrics id=$id origin=${origin.dx.toStringAsFixed(1)},${origin.dy.toStringAsFixed(1)} pointerOffset=${_dragPointerOffset.dx.toStringAsFixed(1)},${_dragPointerOffset.dy.toStringAsFixed(1)} size=${_draggedSize.width.toStringAsFixed(1)}x${_draggedSize.height.toStringAsFixed(1)} initialIndex=$_dragInitialIndex',
    );
    final pointerId = _pendingPointerCardId == id ? _pendingPointerId : null;
    _pendingPointerId = null;
    _pendingPointerCardId = null;
    if (_dragInitialIndex != null) {
      _draggedEntry = _entries[_dragInitialIndex!];
      setState(() {
        _draggedEntry!
          ..opacity = 0
          ..isDragging = true;
      });
      _dropInsertIndex = _dragInitialIndex;
    }
    if (pointerId != null) {
      _activatePointerRoute(pointerId);
    }
    _dropIndicatorRect = null;
    _dropIndicatorOverlay =
        OverlayEntry(builder: (context) => _buildDropIndicator());
    overlayState.insert(_dropIndicatorOverlay!);
    _dragOverlay = OverlayEntry(
      builder: (context) => Positioned(
        left: _dragOverlayOffset.dx,
        top: _dragOverlayOffset.dy,
        child: IgnorePointer(
          child: _buildDragPreview(),
        ),
      ),
    );
    overlayState.insert(_dragOverlay!);
    _updateDropTarget(globalPosition);
    debugPrint('[GridViewModule] reorder_start overlay_inserted id=$id');
  }

  void _activatePointerRoute(int pointerId) {
    if (_activePointerId == pointerId) {
      return;
    }
    _detachPointerRoute();
    GestureBinding.instance.pointerRouter
        .addRoute(pointerId, _handleReorderPointerEvent);
    _activePointerId = pointerId;
    debugPrint(
      '[GridViewModule] reorder_pointer_route_add pointer=$pointerId',
    );
  }

  void _detachPointerRoute() {
    final pointerId = _activePointerId;
    if (pointerId == null) {
      return;
    }
    GestureBinding.instance.pointerRouter
        .removeRoute(pointerId, _handleReorderPointerEvent);
    debugPrint(
      '[GridViewModule] reorder_pointer_route_remove pointer=$pointerId',
    );
    _activePointerId = null;
  }

  void _handleReorderPointerEvent(PointerEvent event) {
    if (_activePointerId != event.pointer || _draggingId == null) {
      return;
    }
    if (event is PointerMoveEvent) {
      _updateReorder(_draggingId!, event.position);
    } else if (event is PointerUpEvent) {
      debugPrint(
        '[GridViewModule] reorder_pointer_up id=$_draggingId pointer=${event.pointer}',
      );
      _endReorder(_draggingId!);
    } else if (event is PointerCancelEvent) {
      debugPrint(
        '[GridViewModule] reorder_pointer_cancel id=$_draggingId pointer=${event.pointer}',
      );
      _cancelReorderFromPointer();
    }
  }

  void _cancelReorderFromPointer() {
    final id = _draggingId;
    if (id == null) {
      return;
    }
    _endReorder(id, canceled: true);
  }

  void _updateReorder(String id, Offset globalPosition) {
    if (_draggingId != id || _dragOverlay == null) {
      debugPrint(
        '[GridViewModule] reorder_update ignored id=$id active=$_draggingId overlay=${_dragOverlay != null}',
      );
      return;
    }
    _dragOverlayOffset = globalPosition - _dragPointerOffset;
    _dragOverlay!.markNeedsBuild();
    _updateDropTarget(globalPosition);
  }

  void _updateDropTarget(Offset globalPosition) {
    final target = _resolveDropTarget(globalPosition);
    if (target == null) {
      if (_dropInsertIndex != null || _dropIndicatorRect != null) {
        _dropInsertIndex = null;
        _dropIndicatorRect = null;
        _dropIndicatorOverlay?.markNeedsBuild();
      }
      return;
    }

    final rectChanged = _dropIndicatorRect == null ||
        !_rectEquals(_dropIndicatorRect!, target.rect);
    if (rectChanged || _dropInsertIndex != target.insertIndex) {
      _dropInsertIndex = target.insertIndex;
      _dropIndicatorRect = target.rect;
      debugPrint(
        '[GridViewModule] reorder_update target insert=${target.insertIndex} rect=${target.rect}',
      );
      _dropIndicatorOverlay?.markNeedsBuild();
    }
  }

  void _endReorder(String id, {bool canceled = false}) {
    if (_draggingId != id) {
      debugPrint(
          '[GridViewModule] reorder_end ignored id=$id active=$_draggingId');
      return;
    }
    debugPrint(
      '[GridViewModule] reorder_end id=$id insert=$_dropInsertIndex overlay=${_dragOverlay != null}',
    );
    final overlay = _dragOverlay;
    if (overlay != null) {
      overlay.remove();
    }
    _dragOverlay = null;
    final indicator = _dropIndicatorOverlay;
    if (indicator != null) {
      indicator.remove();
    }
    _dropIndicatorOverlay = null;
    _dropIndicatorRect = null;
    _detachPointerRoute();
    if (_draggedEntry != null) {
      final dragged = _draggedEntry!;
      final desiredIndex = canceled
          ? _dragInitialIndex
          : (_dropInsertIndex ?? _dragInitialIndex);
      setState(() {
        final currentIndex = _entries.indexOf(dragged);
        if (currentIndex != -1) {
          _entries.removeAt(currentIndex);
        }
        var targetIndex = desiredIndex ?? 0;
        if (currentIndex != -1 && targetIndex > currentIndex) {
          targetIndex -= 1;
        }
        targetIndex = targetIndex.clamp(0, _entries.length);
        _entries.insert(targetIndex, dragged);
        dragged
          ..opacity = 1
          ..isDragging = false;
      });
    }
    if (!canceled) {
      unawaited(_persistOrder());
    }
    debugPrint(
      '[GridViewModule] reorder_end reset id=$id entries=${_entries.length} canceled=$canceled',
    );
    _draggingId = null;
    _dragInitialIndex = null;
    _draggedEntry = null;
    _dropInsertIndex = null;
    _draggedSize = Size.zero;
    _dragPointerOffset = Offset.zero;
  }

  Widget _buildDragPreview() {
    final entry = _draggedEntry;
    if (entry == null) {
      return const SizedBox.shrink();
    }
    return Material(
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: _draggedSize.width,
        height: _draggedSize.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            File(entry.item.filePath),
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }

  Widget _buildDropIndicator() {
    final rect = _dropIndicatorRect;
    if (rect == null) {
      return const SizedBox.shrink();
    }
    return Positioned(
      left: rect.left,
      top: rect.top,
      child: IgnorePointer(
        child: Container(
          width: rect.width,
          height: rect.height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Colors.blueAccent.withOpacity(0.9),
              width: 2,
            ),
            color: Colors.blueAccent.withOpacity(0.12),
          ),
        ),
      ),
    );
  }

  _DropTarget? _resolveDropTarget(Offset globalPosition) {
    Rect? firstRect;
    Rect? lastRect;
    int? lastIndex;
    double bestScore = double.infinity;
    Rect? bestRect;
    int? bestInsertIndex;

    for (var i = 0; i < _entries.length; i++) {
      final entry = _entries[i];
      if (entry.item.id == _draggingId) {
        continue;
      }
      final key = _cardKeys[entry.item.id];
      final context = key?.currentContext;
      if (context == null) {
        continue;
      }
      final box = context.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) {
        continue;
      }
      final origin = box.localToGlobal(Offset.zero);
      final rect = origin & box.size;
      firstRect ??= rect;
      lastRect = rect;
      lastIndex = i;

      if (rect.contains(globalPosition)) {
        final insertAfter = globalPosition.dy >= rect.center.dy;
        final insertIndex = insertAfter ? i + 1 : i;
        debugPrint(
          '[GridViewModule] reorder_hit rect=$rect insertIndex=$insertIndex',
        );
        return _DropTarget(rect: rect, insertIndex: insertIndex);
      }

      final verticalDistance = (rect.center.dy - globalPosition.dy).abs();
      final horizontalDistance = (rect.center.dx - globalPosition.dx).abs();
      final score = verticalDistance + horizontalDistance * 0.15;
      if (score < bestScore) {
        bestScore = score;
        bestRect = rect;
        bestInsertIndex = globalPosition.dy >= rect.center.dy ? i + 1 : i;
      }
    }

    if (bestRect != null && bestInsertIndex != null) {
      return _DropTarget(rect: bestRect!, insertIndex: bestInsertIndex!);
    }

    if (firstRect != null && globalPosition.dy < firstRect!.top) {
      return _DropTarget(rect: firstRect!, insertIndex: 0);
    }

    if (lastRect != null) {
      final insertIndex = (lastIndex ?? (_entries.length - 1)) + 1;
      return _DropTarget(rect: lastRect!, insertIndex: insertIndex);
    }

    if (_draggedEntry != null) {
      final rect = Rect.fromLTWH(
        _dragOverlayOffset.dx,
        _dragOverlayOffset.dy,
        _draggedSize.width,
        _draggedSize.height,
      );
      final insertIndex = (_dragInitialIndex ?? 0).clamp(0, _entries.length);
      return _DropTarget(rect: rect, insertIndex: insertIndex);
    }

    return null;
  }

  bool _rectEquals(Rect a, Rect b, {double tolerance = 0.5}) {
    return (a.left - b.left).abs() <= tolerance &&
        (a.top - b.top).abs() <= tolerance &&
        (a.width - b.width).abs() <= tolerance &&
        (a.height - b.height).abs() <= tolerance;
  }
}

class _GridEntry {
  _GridEntry({required this.item, required this.opacity, this.version = 0});

  ImageItem item;
  double opacity;
  bool isRemoving = false;
  Timer? removalTimer;
  int version;
  bool isDragging = false;
}

class _DropTarget {
  _DropTarget({required this.rect, required this.insertIndex});

  final Rect rect;
  final int insertIndex;
}
