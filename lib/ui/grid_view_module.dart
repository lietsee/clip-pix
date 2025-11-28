import 'dart:async';
import 'dart:convert';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:logging/logging.dart';
import 'package:provider/provider.dart';
import 'package:win32/win32.dart';

import '../data/file_info_manager.dart';
import '../data/grid_card_preferences_repository.dart';
import '../data/grid_layout_settings_repository.dart';
import '../data/grid_order_repository.dart';
import '../data/models/content_item.dart';
import '../data/models/content_type.dart';
import '../data/models/grid_layout_settings.dart';
import '../data/models/image_item.dart';
import '../data/models/text_content_item.dart';
import '../system/clipboard_copy_service.dart';
import '../system/delete_service.dart' as clip_pix_delete;
import '../system/image_preview_process_manager.dart';
import '../system/text_preview_process_manager.dart';
import '../system/state/deletion_mode_notifier.dart';
import '../system/state/deletion_mode_state.dart';
import '../system/state/grid_layout_mutation_controller.dart';
import '../system/state/grid_layout_store.dart';
import '../system/state/image_library_notifier.dart';
import '../system/state/image_library_state.dart';
import '../system/state/selected_folder_state.dart';
import 'image_card.dart';
import 'widgets/grid_layout_surface.dart';
import 'widgets/pinterest_grid.dart';
import 'widgets/text_card.dart';
import 'widgets/text_preview_window.dart';
import 'package:path/path.dart' as p;

class GridViewModule extends StatefulWidget {
  const GridViewModule({
    super.key,
    required this.state,
    this.controller,
  });

  final ImageLibraryState state;
  final ScrollController? controller;

  @override
  State<GridViewModule> createState() => _GridViewModuleState();
}

class _GridViewModuleState extends State<GridViewModule> {
  static const Duration _animationDuration = Duration(milliseconds: 200);
  static const double _outerPadding = 12;
  static const double _gridGap = 3;

  bool _isInitialized = false;

  final Map<String, Timer> _scaleDebounceTimers = {};
  final Map<String, ScrollController> _directoryControllers = {};
  final Map<String, ScrollController> _stagingControllers = {};
  final Map<String, GlobalKey> _cardKeys = {};
  bool _needsRestorationRetry = false;
  bool _needsImageRestorationRetry = false;
  TextPreviewProcessManager? _processManager;
  ImagePreviewProcessManager? _imagePreviewManager;
  GridLayoutSettingsRepository? _layoutSettingsRepository;
  GridOrderRepository? _orderRepository;
  late GridLayoutStore _layoutStore;
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
  bool _firstFrameComplete = false;
  bool _reconciliationPending =
      false; // Track pending reconciliation to skip assertion during tab transitions
  final Set<Object> _currentBuildKeys = <Object>{};

  // Scroll position preservation for image add/delete within same folder
  bool _preserveScrollOnReconcile = false;
  double? _scrollOffsetBeforeReconcile;

  // Track if reconciliation is due to directory change (show loading indicator)
  // vs same-folder card add/delete (keep existing grid to avoid flicker)
  bool _isDirectoryChangeReconcile = false;

  // Track viewDirectory from SelectedFolderState to detect tab changes
  // (ImageLibraryState.activeDirectory updates asynchronously, so we need
  // to detect changes directly from SelectedFolderState in build())
  String? _lastViewDirectory;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_isInitialized) {
      _layoutStore = context.read<GridLayoutStore>();
      _layoutSettingsRepository = context.read<GridLayoutSettingsRepository>();
      _orderRepository = context.read<GridOrderRepository>();
      _processManager = context.read<TextPreviewProcessManager>();
      _imagePreviewManager = context.read<ImagePreviewProcessManager>();
      final orderedImages = _applyDirectoryOrder(widget.state.images);
      _entries = orderedImages.map(_createEntry).toList(growable: true);
      _layoutStore.syncLibrary(
        orderedImages,
        directoryPath: widget.state.activeDirectory?.path,
        notify: false,
      );
      setState(() {
        _isInitialized = true;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _firstFrameComplete = true;
        for (final entry in _entries) {
          _animateEntryVisible(entry);
        }
        // Restore text preview windows after first frame
        _restoreTextPreviewWindows();
        // Restore image preview windows after first frame
        _restoreOpenImagePreviews();
      });
    } else {
      _layoutStore = context.read<GridLayoutStore>();
    }
  }

  @override
  void didUpdateWidget(covariant GridViewModule oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_isInitialized) {
      return;
    }

    // Early return if directory path hasn't changed and images are the same
    // This prevents unnecessary syncLibrary calls when switching between tabs
    final oldPath = oldWidget.state.activeDirectory?.path;
    final newPath = widget.state.activeDirectory?.path;
    final directoryChanged = oldPath != newPath;

    // Use ID-based comparison instead of instance equality
    // to avoid unnecessary rebuilds when only item properties change
    final imagesChanged =
        _imagesChanged(oldWidget.state.images, widget.state.images);
    debugPrint(
        '[GridViewModule] didUpdateWidget: imagesChanged=$imagesChanged, '
        'directoryChanged=$directoryChanged, oldPath=$oldPath, newPath=$newPath, '
        'oldCount=${oldWidget.state.images.length}, newCount=${widget.state.images.length}');

    // Only proceed if directory changed or images changed
    if (!directoryChanged && !imagesChanged) {
      debugPrint(
          '[GridViewModule] didUpdateWidget: no changes, skipping syncLibrary');
      return;
    }

    // ディレクトリが変わった場合も reconciliation を実行
    // (directoryChanged=true but imagesChanged=false のケースで _entries が更新されない問題を修正)
    if (imagesChanged || directoryChanged) {
      // ディレクトリ変更時は、まず _entries をクリア
      // これにより childBuilder の childCount が 0 になり、
      // 旧データによる SizedBox.shrink() の大量生成を防ぐ
      // (大量の SizedBox.shrink がレンダーツリーを破損させ、ヒットテストが効かなくなる問題の修正)
      if (directoryChanged) {
        print('[GridViewModule] didUpdateWidget: directory changed, clearing _entries');
        setState(() {
          _entries = [];
        });
      }

      // ディレクトリ変更時は、画像が新しいディレクトリに属しているか検証
      // 画像ロードは非同期なので、activeDirectory が更新されても
      // images はまだ古いディレクトリの画像の可能性がある
      if (directoryChanged && widget.state.images.isNotEmpty) {
        final newDirPath = widget.state.activeDirectory?.path;
        if (newDirPath != null) {
          // 最初の画像のパスがディレクトリパスで始まるかチェック
          final firstImagePath = widget.state.images.first.id;
          final imagesMatchDirectory = firstImagePath.startsWith(newDirPath);

          if (!imagesMatchDirectory) {
            debugPrint('[GridViewModule] didUpdateWidget: skipping sync - '
                'images not yet updated for new directory. '
                'newPath=$newDirPath, firstImage=$firstImagePath');
            return; // 次の didUpdateWidget を待つ
          }
        }
      }

      // [DIAGNOSTIC] Track specific image positions in state.images
      final stateImages = widget.state.images;
      final note2Index =
          stateImages.indexWhere((item) => item.id.contains('note_2.txt'));
      final g3jjyIndex = stateImages
          .indexWhere((item) => item.id.contains('G3JJYDIa8AAezjR_orig.jpg'));
      debugPrint('[GridViewModule] state_images_order: '
          'note_2.txt@$note2Index, G3JJYDIa8AAezjR_orig.jpg@$g3jjyIndex, '
          'first10=[${stateImages.take(10).map((e) => e.id.split('/').last).join(', ')}]');

      final orderedImages = _applyDirectoryOrder(widget.state.images);
      final orderChanged = !listEquals(
        widget.state.images.map((e) => e.id).toList(),
        orderedImages.map((e) => e.id).toList(),
      );
      debugPrint(
        '[GridViewModule] order_comparison: '
        'original=[${widget.state.images.take(3).map((e) => e.id.split('/').last).join(', ')}...] '
        'ordered=[${orderedImages.take(3).map((e) => e.id.split('/').last).join(', ')}...] '
        'orderChanged=$orderChanged',
      );

      // [DIAGNOSTIC] Track orderedImages positions before syncLibrary
      final note2OrderedIdx =
          orderedImages.indexWhere((item) => item.id.contains('note_2.txt'));
      final g3jjyOrderedIdx = orderedImages
          .indexWhere((item) => item.id.contains('G3JJYDIa8AAezjR_orig.jpg'));
      debugPrint('[GridViewModule] before_syncLibrary: '
          'note_2.txt@$note2OrderedIdx, G3JJYDIa8AAezjR_orig.jpg@$g3jjyOrderedIdx, '
          'first10=[${orderedImages.take(10).map((e) => e.id.split('/').last).join(', ')}]');

      // CRITICAL: Sync viewStates BEFORE reconciling entries
      // This ensures viewStates are populated before build() is triggered by setState
      // notify: false during build, then manually notify in postFrameCallback
      // This prevents "setState during build" error in GridLayoutSurface
      debugPrint('[GridViewModule] syncLibrary_params: '
          'orderChanged=$orderChanged, notify=false (deferred)');
      _layoutStore.syncLibrary(
        orderedImages,
        directoryPath: widget.state.activeDirectory?.path,
        notify: false,
      );

      // Defer notification to avoid "setState during build" error
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _layoutStore.notifyListeners();
      });

      debugPrint(
          '[GridViewModule] after_syncLibrary: synced ${orderedImages.length} items to layoutStore');

      // [DIAGNOSTIC] Track which method is called
      final activeEntriesCount = _entries.where((e) => !e.isRemoving).length;
      final itemCountChanged = widget.state.images.length != activeEntriesCount;
      final willReconcile =
          _entries.isEmpty || orderChanged || itemCountChanged;
      debugPrint('[GridViewModule] reconcile_decision: '
          '_entries.isEmpty=${_entries.isEmpty}, orderChanged=$orderChanged, '
          'itemCountChanged=$itemCountChanged (images=${widget.state.images.length}, activeEntries=$activeEntriesCount), '
          'will_call=${willReconcile ? "_reconcileEntries" : "_updateEntriesProperties"}');

      if (willReconcile) {
        // Initial load or order changed: reconcile entries to rebuild grid
        // Defer to postFrameCallback to avoid "setState during build" error
        _reconciliationPending = true; // Mark reconciliation as pending

        // Track if this is a directory change (show loading indicator)
        // or same-folder change (keep existing grid to avoid flicker)
        _isDirectoryChangeReconcile = directoryChanged;

        // Preserve scroll position when images change within the same folder
        // (e.g., clipboard save, file deletion)
        if (imagesChanged && !directoryChanged) {
          _preserveScrollOnReconcile = true;
          debugPrint(
              '[GridViewModule] scroll_preserve: flagged for preservation');
        }

        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _reconcileEntries(orderedImages);
        });
      } else {
        // Only properties changed: update entry items without setState
        _updateEntriesProperties(orderedImages);
      }
    }

    // Retry text preview restoration if it was deferred due to empty images
    if (_needsRestorationRetry && widget.state.images.isNotEmpty) {
      debugPrint(
          '[GridViewModule] Retrying text preview restoration with ${widget.state.images.length} images loaded');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreTextPreviewWindows();
      });
    }

    // Retry image preview restoration if it was deferred due to empty images
    if (_needsImageRestorationRetry && widget.state.images.isNotEmpty) {
      debugPrint(
          '[GridViewModule] Retrying image preview restoration with ${widget.state.images.length} images loaded');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _restoreOpenImagePreviews();
      });
    }
  }

  /// Check if image list changed based on IDs or properties (order-independent)
  /// Returns false if only order changed, true if IDs or properties changed
  bool _imagesChanged(List<ContentItem> oldList, List<ContentItem> newList) {
    // Check if IDs changed (additions/deletions)
    final oldIds = oldList.map((e) => e.id).toSet();
    final newIds = newList.map((e) => e.id).toSet();

    // Different set sizes or different members = IDs changed
    if (oldIds.length != newIds.length) return true;
    if (!oldIds.containsAll(newIds)) return true;

    // Build maps for property comparison (order-independent)
    final oldMap = {for (var item in oldList) item.id: item};
    final newMap = {for (var item in newList) item.id: item};

    // Check if properties changed for any ID
    for (final id in newIds) {
      final oldItem = oldMap[id]!;
      final newItem = newMap[id]!;

      if (oldItem.favorite != newItem.favorite ||
          oldItem.memo != newItem.memo) {
        return true;
      }
    }

    // Only order changed, not IDs or properties
    return false;
  }

  @override
  void dispose() {
    // Text preview processes are cleaned up by MainScreen.dispose()
    // Dispose other resources
    for (final entry in _entries) {
      entry.removalTimer?.cancel();
    }
    for (final controller in _directoryControllers.values) {
      controller.dispose();
    }
    for (final controller in _stagingControllers.values) {
      controller.dispose();
    }
    _stagingControllers.clear();
    for (final timer in _scaleDebounceTimers.values) {
      timer.cancel();
    }
    _dragOverlay?.remove();
    _dragOverlay = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    // Prevent rendering during reconciliation to avoid _entries/viewStates mismatch
    // Only show loading indicator for directory changes; for same-folder card add/delete,
    // keep existing grid to avoid visual flicker
    if (_reconciliationPending && _isDirectoryChangeReconcile) {
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

    // Detect directory mismatch between viewDirectory and activeDirectory
    // When user switches tabs, viewDirectory updates immediately but images
    // are loaded asynchronously. Show loading until images are ready.
    final currentViewDirectory = selectedState.viewDirectory?.path;
    final activeDirectory = widget.state.activeDirectory?.path;

    // Check 1: viewDirectory と activeDirectory の不一致
    final directoriesMismatch = currentViewDirectory != null &&
        activeDirectory != null &&
        currentViewDirectory != activeDirectory;

    // Check 2: images が activeDirectory に属しているか
    // loadForDirectory が activeDirectory を先に更新するため、
    // images がまだ古いディレクトリの場合がある
    bool imagesMismatch = false;
    if (!directoriesMismatch &&
        activeDirectory != null &&
        widget.state.images.isNotEmpty) {
      final firstImagePath = widget.state.images.first.id;
      imagesMismatch = !firstImagePath.startsWith(activeDirectory);
    }

    if (directoriesMismatch || imagesMismatch) {
      debugPrint('[GridViewModule] directory mismatch: '
          'view=$currentViewDirectory, active=$activeDirectory, '
          'imagesMismatch=$imagesMismatch, showing loading');
      return const Center(child: CircularProgressIndicator());
    }
    _lastViewDirectory = currentViewDirectory;

    final layoutStore = context.watch<GridLayoutStore>();
    final mutationController = context.watch<GridLayoutMutationController>();
    final settingsRepo = context.watch<GridLayoutSettingsRepository>();
    final settings = settingsRepo.value;
    final isMutating = mutationController.isMutating;
    final shouldHideGrid = mutationController.shouldHideGrid;
    // 診断ログ: 操作不能バグの原因特定用
    print(
      '[GridViewModule] build: isMutating=$isMutating, shouldHideGrid=$shouldHideGrid',
    );
    assert(() {
      // Skip alignment check when reconciliation is pending (tab transitions)
      if (_reconciliationPending) {
        return true;
      }
      // Skip alignment check during initial frame to avoid race condition
      // between _entries population and GridLayoutStore.viewStates sync
      if (!_firstFrameComplete || layoutStore.viewStates.isEmpty) {
        return true;
      }
      final activeEntryIds = _entries
          .where((entry) => !entry.isRemoving)
          .map((entry) => entry.item.id)
          .toList(growable: false);
      final viewStateIds =
          layoutStore.viewStates.map((state) => state.id).toList();
      final entrySet = activeEntryIds.toSet();
      final viewSet = viewStateIds.toSet();
      final missingInStore = entrySet.difference(viewSet).toList()..sort();
      final missingInEntries = viewSet.difference(entrySet).toList()..sort();
      if (missingInStore.isNotEmpty || missingInEntries.isNotEmpty) {
        debugPrint(
          '[GridViewModule] assert_alignment_failed missing_store=$missingInStore missing_entries=$missingInEntries '
          'entryOrder=${activeEntryIds.join(', ')} viewOrder=${viewStateIds.join(', ')}',
        );
        return false;
      }
      return true;
    }());

    if (!_loggedInitialBuild) {
      _loggedInitialBuild = true;
      _logEntries('build_init', _entries);
    }

    final content = RefreshIndicator(
      onRefresh: () => libraryNotifier.refresh(),
      child: GridLayoutSurface(
        store: layoutStore,
        columnGap: _gridGap,
        padding: EdgeInsets.zero,
        resolveColumnCount: (availableWidth) =>
            _resolveColumnCount(availableWidth, settings),
        onMutateStart: (hideGrid) =>
            mutationController.beginMutation(hideGrid: hideGrid),
        onMutateEnd: (hideGrid) =>
            mutationController.endMutation(hideGrid: hideGrid),
        geometryQueueEnabled: true,
        childBuilder: (context, geometry, states, snapshot,
            {bool isStaging = false}) {
          _orderRepository = context.watch<GridOrderRepository>();
          final controller = isStaging
              ? _resolveStagingController(selectedState)
              : _resolveController(selectedState);
          final backgroundColor = _backgroundForTone(settings.background);
          final cardBackgroundColor =
              _cardBackgroundForTone(settings.background);
          final columnCount = math.max(1, geometry.columnCount).toInt();
          _currentBuildKeys.clear();

          // Create a Set of current image IDs for efficient lookup in childBuilder
          // This ensures deleted items are skipped even before _reconcileEntries runs
          final currentImageIds =
              widget.state.images.map((img) => img.id).toSet();

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
                    gridDelegate: PinterestGridDelegate(
                      columnCount: columnCount,
                      gap: _gridGap,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        // [DIAGNOSTIC] Log _entries order at build time (once per build)
                        if (index == 0) {
                          print('[GridViewModule] childBuilder START: '
                              '_entriesCount=${_entries.length}, '
                              'viewStatesCount=${layoutStore.viewStates.length}, '
                              'isStaging=$isStaging, snapshotId=${snapshot?.id}');
                        }

                        if (index >= _entries.length) {
                          print('[GridViewModule] childBuilder[$index]: returning null (index >= _entries.length)');
                          return null;
                        }
                        final entry = _entries[index];

                        // Skip entries being removed to avoid ViewState access errors
                        if (entry.isRemoving) {
                          print('[GridViewModule] childBuilder[$index]: returning null (isRemoving) item=${entry.item.id.split('/').last}');
                          return null;
                        }
                        // Skip deleted items (not yet removed from _entries but already removed from state)
                        // This ensures deleted items are hidden immediately, before _reconcileEntries runs
                        if (!currentImageIds.contains(entry.item.id)) {
                          print('[GridViewModule] childBuilder[$index]: returning SizedBox.shrink (not in currentImageIds) item=${entry.item.id.split('/').last}');
                          return const SizedBox.shrink();
                        }
                        // Skip if viewState not yet synced (during initial load/folder change)
                        if (!layoutStore.hasViewState(entry.item.id)) {
                          print('[GridViewModule] childBuilder[$index]: returning SizedBox.shrink (no viewState) item=${entry.item.id.split('/').last}');
                          return const SizedBox.shrink();
                        }
                        final viewState = layoutStore.viewStateFor(
                          entry.item.id,
                        );
                        final span =
                            viewState.columnSpan.clamp(1, columnCount).toInt();
                        final cardWidget = _buildCard(
                          entry: entry,
                          viewState: viewState,
                          columnWidth: geometry.columnWidth,
                          columnCount: columnCount,
                          span: span,
                          backgroundColor: cardBackgroundColor,
                          usePersistentKey: !isStaging,
                          snapshotId: snapshot?.id,
                        );
                        // Log only first few cards to avoid spam
                        if (index < 3) {
                          print('[GridViewModule] childBuilder[$index]: built card item=${entry.item.id.split('/').last}');
                        }
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

    print('[GridViewModule] returning outer Stack: '
        'shouldHideGrid=$shouldHideGrid, isMutating=$isMutating, '
        'hasOverlay=$shouldHideGrid, '
        '_entriesCount=${_entries.length}, '
        '_reconciliationPending=$_reconciliationPending');

    return Stack(
      children: [
        Offstage(
          offstage: shouldHideGrid,
          child: IgnorePointer(
            ignoring: isMutating,
            child: content,
          ),
        ),
        if (shouldHideGrid)
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.04),
              child: const Center(
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildCard({
    required _GridEntry entry,
    required GridCardViewState viewState,
    required double columnWidth,
    required int columnCount,
    required int span,
    required Color backgroundColor,
    required bool usePersistentKey,
    String? snapshotId,
  }) {
    final item = entry.item;

    // [DIAGNOSTIC] Log card construction to track which cards are being built
    debugPrint('[GridViewModule] _buildCard: '
        'id=${item.id.split('/').last}, '
        'version=${entry.version}, '
        'usePersistentKey=$usePersistentKey');

    final animatedKey = usePersistentKey
        ? ObjectKey(entry)
        : ValueKey(
            'staging-${entry.item.id}-${snapshotId ?? 'none'}-${identityHashCode(entry)}',
          );
    final entryHash = identityHashCode(entry);
    // debugPrint(
    //   '[GridViewModule] build_child key=$animatedKey entryHash=$entryHash removing=${entry.isRemoving} dragging=${entry.isDragging} opacity=${entry.opacity.toStringAsFixed(2)}',
    // );
    if (!_currentBuildKeys.add(animatedKey)) {
      debugPrint(
        '[GridViewModule] duplicate_detected key=$animatedKey entryHash=$entryHash',
      );
    }
    final cardKey = usePersistentKey
        ? _cardKeys.putIfAbsent(item.id, () => GlobalKey())
        : null;

    // Get deletion mode state
    final deletionMode = context.watch<DeletionModeState>();
    final isDeletionMode = deletionMode.isActive;
    final isSelected = deletionMode.isSelected(item.id);

    return SizedBox(
      key: cardKey,
      child: AnimatedOpacity(
        key: animatedKey,
        duration: _animationDuration,
        opacity: entry.opacity,
        child: item.contentType == ContentType.text
            ? TextCard(
                item: item as TextContentItem,
                viewState: viewState,
                onResize: _handleResize,
                onSpanChange: _handleSpanChange,
                onEditMemo: _handleEditMemo,
                onFavoriteToggle: _handleFavorite,
                onCopyText: _handleCopyText,
                onOpenPreview: _showTextPreviewDialog,
                onSaveText: _handleSaveText,
                columnWidth: columnWidth,
                columnCount: columnCount,
                columnGap: _gridGap,
                backgroundColor: const Color(0xFF72CC82),
                isDeletionMode: isDeletionMode,
                isSelected: isSelected,
                onDelete: _handleDeleteText,
                onSelectionToggle: _handleSelectionToggle,
                onReorderPointerDown: _handleReorderPointerDown,
                onStartReorder: _startReorder,
                onReorderUpdate: _updateReorder,
                onReorderEnd: _endReorder,
                onReorderCancel: _handleReorderCancel,
              )
            : ImageCard(
                item: item as ImageItem,
                viewState: viewState,
                onResize: _handleResize,
                onSpanChange: _handleSpanChange,
                onZoom: _handleZoom,
                onPan: _handlePan,
                onRetry: _handleRetry,
                onOpenPreview: _showPreviewDialog,
                onCopyImage: _handleCopy,
                onEditMemo: _handleEditMemo,
                onFavoriteToggle: _handleFavorite,
                columnWidth: columnWidth,
                columnCount: columnCount,
                columnGap: _gridGap,
                isDeletionMode: isDeletionMode,
                isSelected: isSelected,
                onDelete: _handleDeleteImage,
                onSelectionToggle: _handleSelectionToggle,
                onReorderPointerDown: _handleReorderPointerDown,
                onStartReorder: _startReorder,
                onReorderUpdate: _updateReorder,
                onReorderEnd: _endReorder,
                onReorderCancel: _handleReorderCancel,
                backgroundColor: backgroundColor,
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

  void _handleCopyText(TextContentItem item) async {
    final copyService = context.read<ClipboardCopyService>();
    try {
      await copyService.copyText(item);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('クリップボードにコピーしました')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('コピー失敗: $error')));
    }
  }

  void _handleDeleteImage(ImageItem item) {
    _showDeleteConfirmationAndExecute([item.id], itemName: p.basename(item.id));
  }

  void _handleDeleteText(TextContentItem item) {
    _showDeleteConfirmationAndExecute([item.id], itemName: p.basename(item.id));
  }

  void _handleSelectionToggle(String cardId) {
    context.read<DeletionModeNotifier>().toggleSelection(cardId);
  }

  Future<void> _showDeleteConfirmationAndExecute(
    List<String> itemPaths, {
    String? itemName,
  }) async {
    final count = itemPaths.length;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('削除確認'),
        content: Text(
          itemName != null
              ? '$itemNameをゴミ箱に移動しますか？'
              : '選択した${count}件のアイテムをゴミ箱に移動しますか？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('キャンセル'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('OK'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    await _executeDelete(itemPaths);
  }

  Future<void> _executeDelete(List<String> itemPaths) async {
    final deletionNotifier = context.read<DeletionModeNotifier>();
    final libraryNotifier = context.read<ImageLibraryNotifier>();

    // Set deleting flag
    deletionNotifier.setDeleting(true);

    // Save scroll position before deletion to preserve it after grid update
    final controller = widget.controller;
    double? scrollOffsetBeforeDelete;
    if (controller != null && controller.hasClients) {
      scrollOffsetBeforeDelete = controller.position.pixels;
      debugPrint(
          '[GridViewModule] delete: saved scroll offset=${scrollOffsetBeforeDelete.toStringAsFixed(1)}');
    }

    try {
      // Import DeleteService at the top of the file
      final fileInfoManager = context.read<FileInfoManager>();
      final preferencesRepo = context.read<GridCardPreferencesRepository>();

      // Create DeleteService with dependencies
      final deleteService = clip_pix_delete.DeleteService(
        fileInfoManager: fileInfoManager,
        preferencesRepository: preferencesRepo,
      );

      // Execute deletion
      final result = await deleteService.deleteItems(itemPaths);

      // Remove successfully deleted items from ImageLibrary
      // Defer state updates to avoid setState during build
      // Set preservation flag before removing items to trigger scroll restoration
      if (scrollOffsetBeforeDelete != null) {
        _scrollOffsetBeforeReconcile = scrollOffsetBeforeDelete;
        _preserveScrollOnReconcile = true;
      }
      SchedulerBinding.instance.addPostFrameCallback((_) {
        for (final path in result.successfulPaths) {
          libraryNotifier.remove(path);
        }
      });

      // Show result message
      if (mounted) {
        final message = result.hasFailures
            ? '${result.successCount}件削除しました（${result.failureCount}件失敗）'
            : '${result.successCount}件削除しました';

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('削除に失敗しました: $error'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    } finally {
      deletionNotifier.setDeleting(false);
    }
  }

  Future<void> _showTextPreviewDialog(TextContentItem item) async {
    if (_processManager == null) {
      debugPrint('[GridViewModule] ProcessManager is null');
      return;
    }

    // 起動中の場合は何もしない
    if (_processManager!.isLaunching(item.id)) {
      debugPrint(
          '[GridViewModule] Text preview already launching for ${item.id}');
      return;
    }

    // 既にウィンドウが開いている場合はアクティブ化
    if (_processManager!.isRunning(item.id)) {
      debugPrint(
          '[GridViewModule] Existing process found for ${item.id}, checking window...');
      // ウィンドウが実際に存在するか確認
      if (_isTextPreviewWindowOpen(item.id)) {
        debugPrint(
            '[GridViewModule] Activating existing text preview for ${item.id}');
        _activateTextPreviewWindow(item.id);
        return;
      } else {
        // ウィンドウが閉じられている場合、プロセス参照をクリーンアップ
        debugPrint(
            '[GridViewModule] Process manager will clean up dead process for ${item.id}');
      }
    }

    // 新しいウィンドウを起動
    if (await _launchTextPreviewWindowProcess(item)) {
      return;
    }
    _showFallbackTextPreview(item);
  }

  void _showFallbackTextPreview(TextContentItem item) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        child: TextPreviewWindow(
          item: item,
          onSave: _handleSaveText,
          onClose: () {
            Navigator.of(context).pop();
            _handleTextPreviewClosed(item.id);
          },
        ),
      ),
    );
  }

  void _handleSaveText(String textId, String text) async {
    try {
      // テキストファイルに書き込み
      final item = widget.state.images.firstWhere((img) => img.id == textId);
      final file = File(item.filePath);
      await file.writeAsString(text);

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('テキストを保存しました')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('テキストの保存に失敗しました')));
    }
  }

  void _handleEditMemo(String imageId, String memo) async {
    final notifier = context.read<ImageLibraryNotifier>();
    try {
      await notifier.updateMemo(imageId, memo);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('メモを保存しました')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('メモの保存に失敗しました')));
    }
  }

  void _handleFavorite(String imageId, int favorite) async {
    final notifier = context.read<ImageLibraryNotifier>();
    try {
      await notifier.updateFavorite(imageId, favorite);
      // お気に入りはサイレント更新（SnackBar表示なし）
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('お気に入りの更新に失敗しました')));
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
    unawaited(_layoutStore.updateCard(id: id, customSize: newSize));
  }

  void _handleZoom(String id, double scale) {
    _scaleDebounceTimers[id]?.cancel();
    _scaleDebounceTimers[id] = Timer(const Duration(milliseconds: 150), () {
      unawaited(_layoutStore.updateCard(id: id, scale: scale));
    });
  }

  void _handlePan(String id, Offset offset) {
    print(
        '[GridViewModule] _handlePan: id=${id.split('/').last}, offset=$offset');
    unawaited(_layoutStore.updateCard(id: id, offset: offset));
  }

  void _handleSpanChange(String id, int span) {
    unawaited(_layoutStore.updateCard(id: id, columnSpan: span));
  }

  ScrollController _resolveController(SelectedFolderState selectedState) {
    // Use provided controller if available (for both root and subfolder)
    if (widget.controller != null) {
      return widget.controller!;
    }
    // Fallback to internal controller management
    final directory = widget.state.activeDirectory;
    final key = directory?.path ?? '_root';
    return _directoryControllers.putIfAbsent(key, () => ScrollController());
  }

  ScrollController _resolveStagingController(
      SelectedFolderState selectedState) {
    final directory = widget.state.activeDirectory;
    final key = '${directory?.path ?? '_root'}_staging';
    return _stagingControllers.putIfAbsent(key, () => ScrollController());
  }

  _GridEntry _createEntry(ContentItem item) {
    return _GridEntry(item: item, opacity: 0);
  }

  /// Update properties of existing entries without changing order or triggering setState
  /// Used when only properties (favorite, memo) changed but order remained the same
  void _updateEntriesProperties(List<ContentItem> items) {
    // [DIAGNOSTIC] Track _entries order before update
    final entriesBeforeIds =
        _entries.take(10).map((e) => e.item.id.split('/').last).toList();
    final note2BeforeIdx =
        _entries.indexWhere((e) => e.item.id.contains('note_2.txt'));
    final g3jjyBeforeIdx = _entries
        .indexWhere((e) => e.item.id.contains('G3JJYDIa8AAezjR_orig.jpg'));
    debugPrint('[GridViewModule] _updateEntriesProperties_before: '
        'note_2.txt@$note2BeforeIdx, G3JJYDIa8AAezjR_orig.jpg@$g3jjyBeforeIdx, '
        'first10=$entriesBeforeIds');

    final itemMap = {for (final item in items) item.id: item};
    int versionIncrementCount = 0;
    bool anyChanged = false;
    int processedCount = 0;

    // [DIAGNOSTIC] Log loop start
    debugPrint('[GridViewModule] _updateEntriesProperties_loop_start: '
        'entriesCount=${_entries.length}, itemsCount=${items.length}');

    try {
      for (final entry in _entries) {
        processedCount++;
        final itemId = entry.item.id;
        final shortId = itemId.split('/').last;

        final newItem = itemMap[itemId];
        if (newItem != null) {
          // Check if properties that affect visual display have changed
          final favoriteChanged = entry.item.favorite != newItem.favorite;
          final memoChanged = entry.item.memo != newItem.memo;
          final pathChanged = entry.item.filePath != newItem.filePath;
          final itemChanged = favoriteChanged || memoChanged || pathChanged;

          // [DIAGNOSTIC] Log only if item changed (reduce log volume)
          if (itemChanged) {
            debugPrint('[GridViewModule] item_changed: '
                'id=$shortId, favoriteChanged=$favoriteChanged, '
                'memoChanged=$memoChanged, pathChanged=$pathChanged');
          }

          final oldFavorite = entry.item.favorite;
          final newFavorite = newItem.favorite;
          final oldItem = entry.item;
          entry.item = newItem; // Update item properties

          if (itemChanged) {
            entry.version += 1; // Trigger ImageCard rebuild only if changed
            versionIncrementCount++;
            anyChanged = true;

            // [DIAGNOSTIC] Log which specific card's version was incremented and why
            try {
              debugPrint('[GridViewModule] version_increment: '
                  'item=$shortId, '
                  'newVersion=${entry.version}, '
                  'favoriteChanged=$favoriteChanged (old=$oldFavorite, new=$newFavorite), '
                  'memoChanged=$memoChanged, pathChanged=$pathChanged');
            } catch (e) {
              debugPrint('[GridViewModule] version_increment_log_error: $e');
            }
          }
        }
      }
    } catch (e, stackTrace) {
      debugPrint('[GridViewModule] _updateEntriesProperties_error: $e');
      debugPrint(
          '[GridViewModule] _updateEntriesProperties_stackTrace: $stackTrace');
    }

    debugPrint('[GridViewModule] _updateEntriesProperties_loop_complete: '
        'processedCount=$processedCount, versionIncrementCount=$versionIncrementCount');

    // [DIAGNOSTIC] Track _entries order after update
    final entriesAfterIds =
        _entries.take(10).map((e) => e.item.id.split('/').last).toList();
    final note2AfterIdx =
        _entries.indexWhere((e) => e.item.id.contains('note_2.txt'));
    final g3jjyAfterIdx = _entries
        .indexWhere((e) => e.item.id.contains('G3JJYDIa8AAezjR_orig.jpg'));

    debugPrint('[GridViewModule] _updateEntriesProperties_after: '
        'note_2.txt@$note2AfterIdx, G3JJYDIa8AAezjR_orig.jpg@$g3jjyAfterIdx, '
        'first10=$entriesAfterIds, updated=${_entries.length} entries, versionIncremented=$versionIncrementCount');

    // Call setState() only if any item changed to trigger ImageCard rebuilds
    if (anyChanged) {
      setState(() {
        // Entry versions updated above
      });
    }
  }

  void _reconcileEntries(List<ContentItem> newItems) {
    _reconciliationPending = false; // Clear pending flag
    _isDirectoryChangeReconcile = false; // Clear directory change flag
    debugPrint(
        '[GridViewModule] _reconcileEntries: newItems=${newItems.length}, currentEntries=${_entries.length}');
    _logEntries('reconcile_before', _entries);

    // Save scroll position before reconcile if preservation is requested
    if (_preserveScrollOnReconcile) {
      final controller = widget.controller;
      if (controller != null && controller.hasClients) {
        _scrollOffsetBeforeReconcile = controller.position.pixels;
        debugPrint(
            '[GridViewModule] scroll_preserve: saved offset=${_scrollOffsetBeforeReconcile?.toStringAsFixed(1)}');
      }
    }
    final duplicateIncoming = _findDuplicateIds(
      newItems.map((item) => item.id),
    );
    if (duplicateIncoming.isNotEmpty) {
      debugPrint(
        '[GridViewModule] incoming duplicates detected: $duplicateIncoming',
      );
    }
    final newIds = newItems.map((item) => item.id).toSet();
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

    int updatedCount = 0;
    int newCount = 0;
    int versionIncrementCount = 0;
    final List<_GridEntry> reordered = <_GridEntry>[];
    for (final item in newItems) {
      final existing = existingMap[item.id];
      if (existing != null) {
        // Only increment version if item properties actually changed
        // This prevents mass rebuilds when only one item's favorite/memo changed
        final itemChanged = existing.item.favorite != item.favorite ||
            existing.item.memo != item.memo ||
            existing.item.filePath != item.filePath;
        existing.item = item;
        updatedCount++;
        if (existing.isRemoving) {
          existing.removalTimer?.cancel();
          existing.isRemoving = false;
        }
        if (existing.opacity != 1) {
          existing.opacity = 1;
        }
        if (itemChanged) {
          existing.version += 1;
          versionIncrementCount++;
        }
        reordered.add(existing);
      } else {
        final entry = _createEntry(item);
        newCount++;
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
    debugPrint('[GridViewModule] _reconcileEntries completed: '
        'updated=$updatedCount, new=$newCount, versionIncremented=$versionIncrementCount, total=${reordered.length}');
    setState(() {
      _entries = reordered;
    });

    // Schedule scroll position restoration after rebuild
    if (_preserveScrollOnReconcile && _scrollOffsetBeforeReconcile != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _restoreScrollPosition();
      });
    }
    _preserveScrollOnReconcile = false;

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

  /// Restore scroll position after grid reconciliation
  void _restoreScrollPosition() {
    final controller = widget.controller;
    final targetOffset = _scrollOffsetBeforeReconcile;

    if (controller == null || targetOffset == null) {
      _scrollOffsetBeforeReconcile = null;
      return;
    }

    if (!controller.hasClients) {
      debugPrint('[GridViewModule] scroll_restore: no clients, retrying');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreScrollPosition();
      });
      return;
    }

    final position = controller.position;
    if (!position.hasContentDimensions) {
      debugPrint('[GridViewModule] scroll_restore: no dimensions, retrying');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _restoreScrollPosition();
      });
      return;
    }

    final clamped = targetOffset.clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );

    debugPrint(
        '[GridViewModule] scroll_restore: jumping to ${clamped.toStringAsFixed(1)} '
        '(target=${targetOffset.toStringAsFixed(1)}, max=${position.maxScrollExtent.toStringAsFixed(1)})');

    controller.jumpTo(clamped);
    _scrollOffsetBeforeReconcile = null;
  }

  void _disposeEntry(_GridEntry entry) {
    entry.removalTimer?.cancel();
    entry.removalTimer = null;
    final id = entry.item.id;
    _scaleDebounceTimers.remove(id)?.cancel();
    _cardKeys.remove(id);
  }

  int _resolveColumnCount(
    double availableWidth,
    GridLayoutSettings settings,
  ) {
    if (availableWidth <= 0) {
      return 1;
    }
    final preferred = settings.preferredColumns.clamp(1, settings.maxColumns);
    final target = math.max(1, preferred);
    final maxByWidth = math.max(
      1,
      (availableWidth / (GridLayoutPreferenceRecord.defaultWidth + _gridGap))
          .floor(),
    );
    final capped = math.min(settings.maxColumns, maxByWidth);
    return math.max(1, math.min(target, capped));
  }

  Future<void> _showPreviewDialog(ImageItem item) async {
    if (_imagePreviewManager == null) {
      debugPrint('[GridViewModule] ImagePreviewProcessManager is null');
      _showFallbackPreview(item);
      return;
    }

    // 起動中の場合は何もしない
    if (_imagePreviewManager!.isLaunching(item.id)) {
      debugPrint(
          '[GridViewModule] Image preview already launching for ${item.id}');
      return;
    }

    // 既にウィンドウが開いている場合はアクティブ化
    if (_imagePreviewManager!.isRunning(item.id)) {
      debugPrint(
          '[GridViewModule] Existing process found for ${item.id}, checking window...');
      // ウィンドウが実際に存在するか確認
      if (_isImagePreviewWindowOpen(item.id)) {
        debugPrint(
            '[GridViewModule] Activating existing image preview for ${item.id}');
        _activateImagePreviewWindow(item.id);
        return;
      } else {
        // ウィンドウが閉じられている場合、プロセス参照をクリーンアップ
        debugPrint(
            '[GridViewModule] Process manager will clean up dead process for ${item.id}');
      }
    }

    // 新しいウィンドウを起動
    if (await _launchPreviewWindowProcess(item)) {
      return;
    }
    _showFallbackPreview(item);
  }

  Future<bool> _launchPreviewWindowProcess(ImageItem item) async {
    if (_imagePreviewManager == null) {
      debugPrint('[GridViewModule] ImagePreviewProcessManager is null');
      return false;
    }

    // Check if already launching or running
    if (_imagePreviewManager!.isLaunching(item.id) ||
        _imagePreviewManager!.isRunning(item.id)) {
      debugPrint(
          '[GridViewModule] Image preview already launching/running for ${item.id}');
      return true;
    }

    final exePath = _resolveExecutablePath();
    if (exePath == null) {
      debugPrint('[GridViewModule] preview exe not found');
      return false;
    }

    // Mark as launching to prevent duplicate launches
    _imagePreviewManager!.markLaunching(item.id);

    final payload = jsonEncode({
      'item': {
        'id': item.id,
        'filePath': item.filePath,
        'metadataPath': item.metadataPath,
        'sourceType': item.sourceType.index,
        'savedAt': item.savedAt.toIso8601String(),
        'source': item.source,
      },
      'alwaysOnTop': false,
    });

    try {
      debugPrint(
          '[GridViewModule] Starting image preview process for ${item.id} (hashCode=${item.id.hashCode})');
      final process = await Process.start(
        exePath,
        ['--preview', payload],
        mode: ProcessStartMode.normal,
      );

      debugPrint('[GridViewModule] Process started, PID: ${process.pid}');

      // Capture stdout and stderr from preview process
      process.stdout.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            debugPrint('[ImagePreview:${item.id.hashCode}] $line');
          }
        }
      });

      process.stderr.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            debugPrint('[ImagePreview:${item.id.hashCode} ERROR] $line');
          }
        }
      });

      // Note: process exit monitoring is handled by ImagePreviewProcessManager

      debugPrint(
          '[GridViewModule] Process started, waiting for window to appear...');

      // Wait for window to appear (poll for 10 seconds)
      bool windowAppeared = false;
      for (int i = 0; i < 100; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_isImagePreviewWindowOpen(item.id)) {
          windowAppeared = true;
          debugPrint(
              '[GridViewModule] Window appeared after ${(i + 1) * 100}ms');
          break;
        }
      }

      if (windowAppeared) {
        // Register process with manager (handles tracking and exit monitoring)
        await _imagePreviewManager!
            .registerProcess(item.id, process, alwaysOnTop: false);
        debugPrint('[GridViewModule] Launched image preview for ${item.id}');
        return true;
      } else {
        debugPrint(
            '[GridViewModule] ERROR: Window did not appear after 10s, killing process');
        process.kill();
        _imagePreviewManager!.removeLaunching(item.id);
        return false;
      }
    } catch (error, stackTrace) {
      debugPrint('[GridViewModule] failed to launch image preview: $error');
      Logger('GridViewModule').warning(
        'Failed to launch image preview window',
        error,
        stackTrace,
      );
      _imagePreviewManager!.removeLaunching(item.id);
      return false;
    }
  }

  Future<bool> _launchTextPreviewWindowProcess(TextContentItem item) async {
    if (_processManager == null) {
      debugPrint('[GridViewModule] ProcessManager is null');
      return false;
    }

    // Check if already launching or running
    if (_processManager!.isLaunching(item.id) ||
        _processManager!.isRunning(item.id)) {
      debugPrint(
          '[GridViewModule] Text preview already launching/running for ${item.id}');
      return true;
    }

    final exePath = _resolveExecutablePath();
    if (exePath == null) {
      debugPrint('[GridViewModule] preview exe not found');
      return false;
    }

    // Mark as launching to prevent duplicate launches
    _processManager!.markLaunching(item.id);

    final payload = jsonEncode({
      'item': {
        'id': item.id,
        'filePath': item.filePath,
        'sourceType': item.sourceType.index,
        'savedAt': item.savedAt.toIso8601String(),
        'source': item.source,
        'fontSize': item.fontSize,
        'memo': item.memo,
        'favorite': item.favorite,
      },
      'alwaysOnTop': false,
    });

    try {
      debugPrint(
          '[GridViewModule] Starting process for ${item.id} (hashCode=${item.id.hashCode})');
      final process = await Process.start(
        exePath,
        ['--preview-text', payload],
        mode: ProcessStartMode.normal,
      );

      debugPrint('[GridViewModule] Process started, PID: ${process.pid}');

      // Capture stdout and stderr from preview process
      process.stdout.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            debugPrint('[TextPreview:${item.id.hashCode}] $line');
          }
        }
      });

      process.stderr.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          if (line.trim().isNotEmpty) {
            debugPrint('[TextPreview:${item.id.hashCode} ERROR] $line');
          }
        }
      });

      // Note: process exit monitoring is handled by TextPreviewProcessManager

      debugPrint(
          '[GridViewModule] Process started, waiting for window to appear...');

      // Wait for window to appear (poll for 10 seconds)
      bool windowAppeared = false;
      for (int i = 0; i < 100; i++) {
        await Future.delayed(const Duration(milliseconds: 100));
        if (_isTextPreviewWindowOpen(item.id)) {
          windowAppeared = true;
          debugPrint(
              '[GridViewModule] Window appeared after ${(i + 1) * 100}ms');
          break;
        }
      }

      if (windowAppeared) {
        // Register process with manager (handles tracking and exit monitoring)
        await _processManager!
            .registerProcess(item.id, process, alwaysOnTop: false);
        debugPrint('[GridViewModule] Launched text preview for ${item.id}');
        return true;
      } else {
        debugPrint(
            '[GridViewModule] ERROR: Window did not appear after 10s, killing process');
        process.kill();
        _processManager!.removeLaunching(item.id);
        return false;
      }
    } catch (error, stackTrace) {
      debugPrint('[GridViewModule] failed to launch text preview: $error');
      Logger('GridViewModule').warning(
        'Failed to launch text preview window',
        error,
        stackTrace,
      );
      _processManager!.removeLaunching(item.id);
      return false;
    }
  }

  bool _isTextPreviewWindowOpen(String textId) {
    if (!Platform.isWindows) return false;

    try {
      final titleHash = 'clip_pix_text_${textId.hashCode}';
      final titlePtr = TEXT(titleHash);
      // Search by window title only (class name = nullptr)
      final hwnd = FindWindow(Pointer.fromAddress(0), titlePtr);
      calloc.free(titlePtr);

      debugPrint(
          '[GridViewModule] _isTextPreviewWindowOpen: textId="$textId", hashCode=${textId.hashCode}, titleHash="$titleHash", hwnd=$hwnd');

      if (hwnd == 0) {
        return false;
      }

      // Verify the window handle is still valid
      final isValid = IsWindow(hwnd) != 0;
      debugPrint('[GridViewModule] IsWindow result: $isValid for hwnd=$hwnd');

      if (!isValid) {
        // Window was closed (cleanup handled by process manager)
        debugPrint('[GridViewModule] Window $textId is no longer valid');
      }

      return isValid;
    } catch (e) {
      debugPrint('[GridViewModule] Error checking window existence: $e');
      return false;
    }
  }

  void _activateTextPreviewWindow(String textId) {
    if (!Platform.isWindows) return;

    try {
      // Window title hash used for FindWindow
      final titleHash = 'clip_pix_text_${textId.hashCode}';
      final titlePtr = TEXT(titleHash);
      // Search by window title only (class name = nullptr)
      final hwnd = FindWindow(Pointer.fromAddress(0), titlePtr);
      calloc.free(titlePtr);

      if (hwnd == 0) {
        debugPrint('[GridViewModule] Window not found: $titleHash');
        return;
      }

      // Verify window is still valid
      if (IsWindow(hwnd) == 0) {
        debugPrint(
            '[GridViewModule] IsWindow returned invalid: $titleHash (hwnd=$hwnd)');
        return;
      }

      // Restore if minimized
      if (IsIconic(hwnd) != 0) {
        final restoreResult = ShowWindow(hwnd, SW_RESTORE);
        debugPrint(
            '[GridViewModule] ShowWindow(SW_RESTORE) result: $restoreResult');
      }

      // Get thread IDs for input attachment
      final foregroundHwnd = GetForegroundWindow();
      final foregroundThreadId = GetWindowThreadProcessId(
          foregroundHwnd, Pointer<Uint32>.fromAddress(0));
      final targetThreadId =
          GetWindowThreadProcessId(hwnd, Pointer<Uint32>.fromAddress(0));

      debugPrint(
          '[GridViewModule] Thread IDs: foreground=$foregroundThreadId, target=$targetThreadId');

      // Attach input if different threads
      int attachResult = 0;
      if (foregroundThreadId != targetThreadId && foregroundThreadId != 0) {
        attachResult = AttachThreadInput(foregroundThreadId, targetThreadId, 1);
        debugPrint('[GridViewModule] AttachThreadInput result: $attachResult');
      }

      // Multiple activation attempts for reliability
      final bringToTopResult = BringWindowToTop(hwnd);
      final showResult = ShowWindow(hwnd, SW_SHOW);
      final setForegroundResult = SetForegroundWindow(hwnd);
      final setFocusResult = SetFocus(hwnd);

      debugPrint('[GridViewModule] Activation results: '
          'BringWindowToTop=$bringToTopResult, ShowWindow=$showResult, '
          'SetForegroundWindow=$setForegroundResult, SetFocus=$setFocusResult');

      // Detach input
      if (foregroundThreadId != targetThreadId && foregroundThreadId != 0) {
        final detachResult =
            AttachThreadInput(foregroundThreadId, targetThreadId, 0);
        debugPrint('[GridViewModule] DetachThreadInput result: $detachResult');
      }

      debugPrint('[GridViewModule] Activated window: $titleHash (hwnd=$hwnd)');
    } catch (e, stackTrace) {
      Logger('GridViewModule').warning(
        'Failed to activate text preview window',
        e,
        stackTrace,
      );
    }
  }

  String? _resolveExecutablePath() {
    final exe = Platform.resolvedExecutable;
    if (exe.toLowerCase().contains('clip_pix')) {
      return exe;
    }
    final debugCandidate = p.join(
      Directory.current.path,
      'build',
      'windows',
      'x64',
      'runner',
      'Debug',
      'clip_pix.exe',
    );
    if (File(debugCandidate).existsSync()) {
      return debugCandidate;
    }
    final releaseCandidate = p.join(
      Directory.current.path,
      'build',
      'windows',
      'x64',
      'runner',
      'Release',
      'clip_pix.exe',
    );
    if (File(releaseCandidate).existsSync()) {
      return releaseCandidate;
    }
    return null;
  }

  void _showFallbackPreview(ImageItem item) {
    showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: InteractiveViewer(
          child: Image.file(File(item.filePath), fit: BoxFit.contain),
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
    final layoutStore = _layoutStore;
    List<String> viewStateIds = const [];
    if (layoutStore != null) {
      viewStateIds = layoutStore.viewStates.map((state) => state.id).toList();
    }
    final entryIds = entries.map((e) => e.item.id).toList();
    final entrySet = entryIds.toSet();
    final viewSet = viewStateIds.toSet();
    final missingInStore = entrySet.difference(viewSet).toList()..sort();
    final missingInEntries = viewSet.difference(entrySet).toList()..sort();
    final orderMatches = listEquals(entryIds, viewStateIds);
    debugPrint(
      '[GridViewModule] $label total=${entries.length} removing=${entries.where((e) => e.isRemoving).length} duplicates=$duplicates '
      'entryOrder=[${entryIds.join(', ')}] viewOrder=[${viewStateIds.join(', ')}] '
      'orderMatches=$orderMatches '
      'missing_store=$missingInStore missing_entries=$missingInEntries '
      'details=${entries.map((e) => '${e.item.id}|v${e.version}|rem=${e.isRemoving}|opacity=${e.opacity.toStringAsFixed(2)}').join(', ')}',
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

  Color _backgroundForTone(GridBackgroundTone tone) {
    switch (tone) {
      case GridBackgroundTone.white:
        return Colors.white;
      case GridBackgroundTone.lightGray:
        return const Color(0xFFC0C0C0);
      case GridBackgroundTone.darkGray:
        return const Color(0xFF2E2E2E);
      case GridBackgroundTone.black:
        return Colors.black;
    }
  }

  Color _cardBackgroundForTone(GridBackgroundTone tone) {
    final base = _backgroundForTone(tone);
    final hsl = HSLColor.fromColor(base);
    final darkerLightness = (hsl.lightness - 0.08).clamp(0.0, 1.0);
    return hsl.withLightness(darkerLightness).toColor();
  }

  List<ContentItem> _applyDirectoryOrder(List<ContentItem> items) {
    final path = widget.state.activeDirectory?.path;
    final repo = _orderRepository;
    if (path == null || repo == null) {
      return items;
    }
    final stored = repo.getOrder(path);
    if (items.isEmpty) {
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
    final orderedItems = <ContentItem>[];
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
    final orderedItems = _entries
        .where((entry) => !entry.isRemoving)
        .map((entry) => entry.item)
        .toList(growable: false);
    _layoutStore.syncLibrary(
      orderedItems,
      directoryPath: widget.state.activeDirectory?.path,
    );
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
          child: entry.item.contentType == ContentType.text
              ? Container(
                  color: const Color(0xFF72CC82),
                  padding: const EdgeInsets.all(12),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.description, size: 48, color: Colors.white),
                      SizedBox(height: 8),
                      Text(
                        'テキスト',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                )
              : Image.file(
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
        final insertAfter = globalPosition.dx >= rect.center.dx;
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
        bestInsertIndex = globalPosition.dx >= rect.center.dx ? i + 1 : i;
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

  /// Restore text preview windows from previous session
  Future<void> _restoreTextPreviewWindows() async {
    if (_processManager == null) {
      debugPrint(
          '[GridViewModule] ProcessManager is null, skipping restoration');
      return;
    }

    // Skip restoration if image library is not yet loaded
    if (widget.state.images.isEmpty) {
      debugPrint(
          '[GridViewModule] Image library is empty, deferring restoration');
      _needsRestorationRetry = true;
      return;
    }

    try {
      final openPreviews = _processManager!.getOpenPreviews();
      debugPrint(
          '[GridViewModule] Restoring ${openPreviews.length} text preview windows from ${widget.state.images.length} loaded images');

      if (openPreviews.isEmpty) {
        _needsRestorationRetry = false;
        return;
      }

      // Clean up old entries (older than 30 days)
      await _processManager!.removeOldPreviews(const Duration(days: 30));

      int restoredCount = 0;
      int failedCount = 0;
      const maxRestore = 10; // Limit to 10 windows

      for (final preview in openPreviews.take(maxRestore)) {
        try {
          // Find the item in current library
          final item = widget.state.images.firstWhere(
            (img) => img.id == preview.itemId,
            orElse: () => throw StateError('Item not found'),
          );

          if (item is! TextContentItem) {
            debugPrint(
                '[GridViewModule] Item ${preview.itemId} is not a TextContentItem, skipping');
            await _processManager!.removePreview(preview.itemId);
            continue;
          }

          // Launch the preview window
          debugPrint('[GridViewModule] Restoring preview for ${item.id}');
          final success = await _launchTextPreviewWindowProcess(item);

          if (success) {
            restoredCount++;
            debugPrint(
                '[GridViewModule] Successfully restored preview for ${item.id}');
          } else {
            failedCount++;
            debugPrint(
                '[GridViewModule] Failed to restore preview for ${item.id}');
            // Remove from repository if restoration failed
            await _processManager!.removePreview(preview.itemId);
          }

          // Add delay between launches to avoid resource contention
          if (preview != openPreviews.last) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        } catch (error) {
          failedCount++;
          debugPrint(
              '[GridViewModule] Error restoring preview ${preview.itemId}: $error');
          // Remove from repository if item no longer exists
          await _processManager!.removePreview(preview.itemId);
        }
      }

      debugPrint(
          '[GridViewModule] Preview restoration complete: $restoredCount restored, $failedCount failed');
      _needsRestorationRetry = false;
    } catch (error, stackTrace) {
      Logger('GridViewModule').warning(
        'Failed to restore text preview windows',
        error,
        stackTrace,
      );
      _needsRestorationRetry = false;
    }
  }

  /// Handle text preview window closed
  void _handleTextPreviewClosed(String itemId) {
    // Cleanup is now handled by TextPreviewProcessManager
    debugPrint('[GridViewModule] Text preview closed for $itemId');
  }

  /// Check if image preview window is open by finding its window handle
  bool _isImagePreviewWindowOpen(String imageId) {
    if (!Platform.isWindows) return false;

    try {
      final titleHash = 'clip_pix_image_${imageId.hashCode}';
      final titlePtr = TEXT(titleHash);
      // Search by window title only (class name = nullptr)
      final hwnd = FindWindow(Pointer.fromAddress(0), titlePtr);
      calloc.free(titlePtr);

      debugPrint(
          '[GridViewModule] _isImagePreviewWindowOpen: imageId="$imageId", hashCode=${imageId.hashCode}, titleHash="$titleHash", hwnd=$hwnd');

      if (hwnd == 0) {
        return false;
      }

      // Verify the window handle is still valid
      final isValid = IsWindow(hwnd) != 0;
      debugPrint('[GridViewModule] IsWindow result: $isValid for hwnd=$hwnd');

      if (!isValid) {
        // Window was closed (cleanup handled by process manager)
        debugPrint('[GridViewModule] Window $imageId is no longer valid');
      }

      return isValid;
    } catch (e) {
      debugPrint('[GridViewModule] Error checking window existence: $e');
      return false;
    }
  }

  /// Activate existing image preview window
  void _activateImagePreviewWindow(String imageId) {
    if (!Platform.isWindows) return;

    try {
      // Window title hash used for FindWindow
      final titleHash = 'clip_pix_image_${imageId.hashCode}';
      final titlePtr = TEXT(titleHash);
      // Search by window title only (class name = nullptr)
      final hwnd = FindWindow(Pointer.fromAddress(0), titlePtr);
      calloc.free(titlePtr);

      if (hwnd == 0) {
        debugPrint('[GridViewModule] Window not found: $titleHash');
        return;
      }

      // Verify window is still valid
      if (IsWindow(hwnd) == 0) {
        debugPrint(
            '[GridViewModule] IsWindow returned invalid: $titleHash (hwnd=$hwnd)');
        return;
      }

      // Restore if minimized
      if (IsIconic(hwnd) != 0) {
        final restoreResult = ShowWindow(hwnd, SW_RESTORE);
        debugPrint(
            '[GridViewModule] ShowWindow(SW_RESTORE) result: $restoreResult');
      }

      // Get thread IDs for input attachment
      final foregroundHwnd = GetForegroundWindow();
      final foregroundThreadId = GetWindowThreadProcessId(
          foregroundHwnd, Pointer<Uint32>.fromAddress(0));
      final targetThreadId =
          GetWindowThreadProcessId(hwnd, Pointer<Uint32>.fromAddress(0));

      debugPrint(
          '[GridViewModule] Thread IDs: foreground=$foregroundThreadId, target=$targetThreadId');

      // Attach input if different threads
      int attachResult = 0;
      if (foregroundThreadId != targetThreadId && foregroundThreadId != 0) {
        attachResult = AttachThreadInput(foregroundThreadId, targetThreadId, 1);
        debugPrint('[GridViewModule] AttachThreadInput result: $attachResult');
      }

      // Multiple activation attempts for reliability
      final bringToTopResult = BringWindowToTop(hwnd);
      final showResult = ShowWindow(hwnd, SW_SHOW);
      final setForegroundResult = SetForegroundWindow(hwnd);
      final setFocusResult = SetFocus(hwnd);

      debugPrint('[GridViewModule] Activation results: '
          'BringWindowToTop=$bringToTopResult, ShowWindow=$showResult, '
          'SetForegroundWindow=$setForegroundResult, SetFocus=$setFocusResult');

      // Detach input
      if (foregroundThreadId != targetThreadId && foregroundThreadId != 0) {
        final detachResult =
            AttachThreadInput(foregroundThreadId, targetThreadId, 0);
        debugPrint('[GridViewModule] DetachThreadInput result: $detachResult');
      }

      debugPrint('[GridViewModule] Activated window: $titleHash (hwnd=$hwnd)');
    } catch (e, stackTrace) {
      Logger('GridViewModule').warning(
        'Failed to activate image preview window',
        e,
        stackTrace,
      );
    }
  }

  /// Restore image preview windows from previous session
  Future<void> _restoreOpenImagePreviews() async {
    if (_imagePreviewManager == null) {
      debugPrint(
          '[GridViewModule] ImagePreviewProcessManager is null, skipping restoration');
      return;
    }

    // Skip restoration if image library is not yet loaded
    if (widget.state.images.isEmpty) {
      debugPrint(
          '[GridViewModule] Image library is empty, deferring restoration');
      _needsImageRestorationRetry = true;
      return;
    }

    try {
      final openPreviews = _imagePreviewManager!.getOpenPreviews();
      debugPrint(
          '[GridViewModule] Restoring ${openPreviews.length} image preview windows from ${widget.state.images.length} loaded images');

      if (openPreviews.isEmpty) {
        _needsImageRestorationRetry = false;
        return;
      }

      // Clean up old entries (older than 30 days)
      await _imagePreviewManager!.removeOldPreviews(const Duration(days: 30));

      int restoredCount = 0;
      int failedCount = 0;
      const maxRestore = 10; // Limit to 10 windows

      for (final preview in openPreviews.take(maxRestore)) {
        try {
          // Find the item in current library
          final item = widget.state.images.firstWhere(
            (img) => img.id == preview.itemId,
            orElse: () => throw StateError('Item not found'),
          );

          if (item is! ImageItem) {
            debugPrint(
                '[GridViewModule] Item ${preview.itemId} is not an ImageItem, skipping');
            await _imagePreviewManager!.removePreview(preview.itemId);
            continue;
          }

          // Launch the preview window
          debugPrint('[GridViewModule] Restoring preview for ${item.id}');
          final success = await _launchPreviewWindowProcess(item);

          if (success) {
            restoredCount++;
            debugPrint(
                '[GridViewModule] Successfully restored preview for ${item.id}');
          } else {
            failedCount++;
            debugPrint(
                '[GridViewModule] Failed to restore preview for ${item.id}');
            // Remove from repository if restoration failed
            await _imagePreviewManager!.removePreview(preview.itemId);
          }

          // Add delay between launches to avoid resource contention
          if (preview != openPreviews.last) {
            await Future.delayed(const Duration(milliseconds: 150));
          }
        } catch (error) {
          failedCount++;
          debugPrint(
              '[GridViewModule] Error restoring preview ${preview.itemId}: $error');
          // Remove from repository if item no longer exists
          await _imagePreviewManager!.removePreview(preview.itemId);
        }
      }

      debugPrint(
          '[GridViewModule] Image preview restoration complete: $restoredCount restored, $failedCount failed');
      _needsImageRestorationRetry = false;
    } catch (error, stackTrace) {
      Logger('GridViewModule').warning(
        'Failed to restore image preview windows',
        error,
        stackTrace,
      );
      _needsImageRestorationRetry = false;
    }
  }

  /// Handle image preview window closed
  void _handleImagePreviewClosed(String itemId) {
    // Cleanup is now handled by ImagePreviewProcessManager
    debugPrint('[GridViewModule] Image preview closed for $itemId');
  }
}

class _GridEntry {
  _GridEntry({required this.item, required this.opacity, this.version = 0});

  ContentItem item;
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
