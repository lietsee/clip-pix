import 'dart:io';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'package:path/path.dart' as p;

import '../data/models/image_item.dart';
import '../system/state/grid_layout_store.dart';
import 'widgets/memo_edit_dialog.dart';
import 'widgets/memo_tooltip_overlay.dart';
import 'widgets/resize_preview_overlay.dart';

/// リサイズハンドルの位置を表すenum
enum ResizeCorner {
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

class ImageCard extends StatefulWidget {
  const ImageCard({
    super.key,
    required this.item,
    required this.viewState,
    required this.onResize,
    required this.onSpanChange,
    required this.onZoom,
    required this.onPan,
    required this.onRetry,
    required this.onOpenPreview,
    required this.onCopyImage,
    required this.onEditMemo,
    required this.onFavoriteToggle,
    required this.columnWidth,
    required this.columnCount,
    required this.columnGap,
    required this.backgroundColor,
    this.isDeletionMode = false,
    this.isSelected = false,
    this.isHighlighted = false,
    this.onDelete,
    this.onSelectionToggle,
    this.onReorderPointerDown,
    this.onStartReorder,
    this.onReorderUpdate,
    this.onReorderEnd,
    this.onReorderCancel,
    this.onHoverChanged,
  });

  final ImageItem item;
  final GridCardViewState viewState;
  final void Function(String id, Size newSize, {ResizeCorner? corner}) onResize;
  final void Function(String id, int span) onSpanChange;
  final void Function(String id, double scale) onZoom;
  final void Function(String id, Offset offset) onPan;
  final void Function(String id) onRetry;
  final void Function(ImageItem item) onOpenPreview;
  final void Function(ImageItem item) onCopyImage;
  final void Function(String id, String memo) onEditMemo;
  final void Function(String id, int favorite) onFavoriteToggle;
  final double columnWidth;
  final int columnCount;
  final double columnGap;
  final Color backgroundColor;
  final bool isDeletionMode;
  final bool isSelected;
  final bool isHighlighted;
  final void Function(ImageItem item)? onDelete;
  final void Function(String id)? onSelectionToggle;
  final void Function(String id, int pointer)? onReorderPointerDown;
  final void Function(String id, Offset globalPosition)? onStartReorder;
  final void Function(String id, Offset globalPosition)? onReorderUpdate;
  final void Function(String id)? onReorderEnd;
  final void Function(String id)? onReorderCancel;
  final void Function(bool isHovered)? onHoverChanged;

  @override
  State<ImageCard> createState() => _ImageCardState();
}

@visibleForTesting
Offset clampPanOffset({
  required Offset offset,
  required Size size,
  required double scale,
}) {
  if (!scale.isFinite || scale <= 1.0 || size.width <= 0 || size.height <= 0) {
    return Offset.zero;
  }
  final scaledWidth = size.width * scale;
  final scaledHeight = size.height * scale;
  final maxDx = (scaledWidth - size.width) / 2;
  final maxDy = (scaledHeight - size.height) / 2;
  return Offset(
    offset.dx.clamp(-maxDx, maxDx),
    offset.dy.clamp(-maxDy, maxDy),
  );
}

enum _CardVisualState { loading, ready, error }

class _ImageCardState extends State<ImageCard>
    with SingleTickerProviderStateMixin {
  static const double _minWidth = 100;
  static const double _minHeight = 100;
  static const double _maxWidth = 1920;
  static const double _maxHeight = 1080;
  static const double _minScale = 0.5;
  static const double _maxScale = 15.0;
  static const int _maxRetryCount = 3;

  final FocusNode _focusNode = FocusNode(debugLabel: 'ImageCardFocus');
  _CardVisualState _visualState = _CardVisualState.loading;
  bool _consumeScroll = false;
  bool _isRightButtonPressed = false;
  bool _isResizing = false;
  bool _showControls = false;
  bool _isPanning = false;
  int _retryCount = 0;
  int _currentSpan = 1;
  Size? _resizeStartSize;
  Offset? _resizeStartGlobalPosition;
  int _resizeStartSpan = 1;
  Size? _previewSize;
  ResizeCorner? _resizeCorner;
  Offset? _anchorPosition; // ドラッグ中の固定点（グローバル座標）
  ResizePreviewOverlayService? _overlayService;
  MemoTooltipOverlayService? _memoTooltipService;
  Timer? _memoHoverTimer;
  Offset? _panStartLocal;
  Offset? _panStartOffset;
  Offset _imageOffset = Offset.zero;
  ImageChunkEvent? _latestChunk;
  Key _imageKey = UniqueKey();
  ImageStream? _imageStream;
  ImageStreamListener? _streamListener;
  ImageInfo? _imageInfo;
  String? _resolvedSignature;
  double _currentScale = 1.0;
  bool _suppressScaleListener = false;
  Timer? _loadingTimeout;
  int _loadingStateVersion = 0;
  late ValueNotifier<Size> _sizeNotifier;
  late ValueNotifier<double> _scaleNotifier;
  late AnimationController _highlightController;
  late Animation<double> _highlightAnimation;

  @override
  void initState() {
    super.initState();
    _sizeNotifier = ValueNotifier<Size>(
      Size(widget.viewState.width, widget.viewState.height),
    );
    _scaleNotifier = ValueNotifier<double>(widget.viewState.scale);
    _sizeNotifier.addListener(_handleSizeExternalChange);
    _scaleNotifier.addListener(_handleScaleExternalChange);
    _currentSpan = widget.viewState.columnSpan;
    _currentScale = widget.viewState.scale;
    _imageOffset = widget.viewState.offset;

    // パルスアニメーション用コントローラー（2秒間で3回パルス）
    _highlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 667),
    );
    _highlightAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _highlightController, curve: Curves.easeInOut),
    );
    if (widget.isHighlighted) {
      _highlightController.repeat(reverse: true);
    }

    debugPrint('[ImageCard] initState_restore: id=${widget.item.id.split('/').last}, '
        'offset=$_imageOffset, scale=$_currentScale');
  }

  @override
  void didUpdateWidget(covariant ImageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // リサイズ中は外部からのサイズ同期をスキップ
    if (!_isResizing) {
      final newSize = Size(widget.viewState.width, widget.viewState.height);
      final currentSize = _sizeNotifier.value;
      // 1px以上の差がある場合はログ出力（デバッグ用）
      if ((currentSize.width - newSize.width).abs() > 1.0 ||
          (currentSize.height - newSize.height).abs() > 1.0) {
        debugPrint('[ImageCard] didUpdateWidget_size_sync: '
            'id=${widget.item.id.split('/').last}, '
            'oldSize=$currentSize, newSize=$newSize');
        _sizeNotifier.value = newSize;
      } else if (_sizeNotifier.value != newSize) {
        // 小さな差異は同期するがログ出力しない
        _sizeNotifier.value = newSize;
      }
    }
    if (_scaleNotifier.value != widget.viewState.scale) {
      _scaleNotifier.value = widget.viewState.scale;
      _currentScale = widget.viewState.scale;
    }
    if (oldWidget.item.filePath != widget.item.filePath) {
      _reloadImage();
    }
    // Trigger rebuild when favorite changes to update FavoriteIndicator
    if (oldWidget.item.favorite != widget.item.favorite) {
      // [DIAGNOSTIC] Log favorite property change detection
      debugPrint('[ImageCard] didUpdateWidget_favorite_changed: '
          'item=${widget.item.id.split('/').last}, '
          'oldFavorite=${oldWidget.item.favorite}, '
          'newFavorite=${widget.item.favorite}');
      // Defer setState to avoid calling it during build phase
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {});
        }
      });
    }
    if (oldWidget.columnWidth != widget.columnWidth ||
        oldWidget.columnGap != widget.columnGap ||
        oldWidget.columnCount != widget.columnCount) {
      _currentSpan = widget.viewState.columnSpan;
    }
    if (oldWidget.viewState.columnSpan != widget.viewState.columnSpan) {
      _currentSpan = widget.viewState.columnSpan;
    }
    // ハイライト状態の変更を検知してアニメーション制御
    if (oldWidget.isHighlighted != widget.isHighlighted) {
      debugPrint('[ImageCard] highlight_changed: ${widget.item.id.split('/').last}, '
          'old=${oldWidget.isHighlighted}, new=${widget.isHighlighted}');
      if (widget.isHighlighted) {
        _highlightController.repeat(reverse: true);
      } else {
        _highlightController.stop();
        _highlightController.reset();
      }
    }
  }

  @override
  void dispose() {
    print('[ImageCard] dispose: ${widget.item.id.split('/').last}, '
        'isResizing=$_isResizing, overlayService=${_overlayService != null}');
    _cancelMemoTooltip();
    _memoTooltipService?.dispose();
    _memoTooltipService = null;
    _overlayService?.dispose();
    _overlayService = null;
    _focusNode.dispose();
    _sizeNotifier.removeListener(_handleSizeExternalChange);
    _scaleNotifier.removeListener(_handleScaleExternalChange);
    _sizeNotifier.dispose();
    _scaleNotifier.dispose();
    _detachImageStream();
    _cancelLoadingTimeout();
    _highlightController.dispose();
    super.dispose();
  }

  void _handleSizeExternalChange() {
    final size = _clampSize(_sizeNotifier.value);
    if (size != _sizeNotifier.value) {
      _sizeNotifier.value = size;
    }
    _currentSpan = _computeSpan(size.width);
    final constrained = clampPanOffset(
      offset: _imageOffset,
      size: size,
      scale: _currentScale,
    );
    if (constrained != _imageOffset) {
      setState(() {
        _imageOffset = constrained;
      });
    }
  }

  void _handleScaleExternalChange() {
    final scale = _clampScale(_scaleNotifier.value);
    if (scale != _scaleNotifier.value) {
      _scaleNotifier.value = scale;
    }
    if (_suppressScaleListener) {
      return;
    }
    _currentScale = scale;
    final constrained = clampPanOffset(
      offset: _imageOffset,
      size: _sizeNotifier.value,
      scale: scale,
    );
    if (constrained != _imageOffset) {
      setState(() {
        _imageOffset = constrained;
      });
    }
  }

  void _reloadImage() {
    _detachImageStream();
    setState(() {
      _visualState = _CardVisualState.loading;
      _latestChunk = null;
      _imageKey = UniqueKey();
      _resolvedSignature = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    // [DIAGNOSTIC] Log every ImageCard build to track actual rebuilds
    print('[ImageCard] build_called: '
        'item=${widget.item.id.split('/').last}');

    return Focus(
      focusNode: _focusNode,
      onKeyEvent: _handleKeyEvent,
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (_consumeScroll) {
            _consumeScroll = false;
            return true;
          }
          return false;
        },
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            print('[ImageCard] onPointerDown: ${widget.item.id.split('/').last}');
            _handlePointerDown(e);
          },
          onPointerUp: _handlePointerUp,
          onPointerMove: _handlePointerMove,
          onPointerSignal: _handlePointerSignal,
          child: MouseRegion(
            onEnter: (_) {
              print('[ImageCard] onEnter: ${widget.item.id.split('/').last}');
              _setControlsVisible(true);
              _scheduleMemoTooltip();
              widget.onHoverChanged?.call(true);
            },
            onExit: (_) {
              print('[ImageCard] onExit: ${widget.item.id.split('/').last}');
              _setControlsVisible(false);
              _cancelMemoTooltip();
              widget.onHoverChanged?.call(false);
            },
            cursor: _isResizing
                ? SystemMouseCursors.resizeUpLeftDownRight
                : _isPanning
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.basic,
            child: ValueListenableBuilder<Size>(
              valueListenable: _sizeNotifier,
              builder: (context, size, _) {
                final clampedSize = _clampSize(size);
                if (clampedSize != size) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _sizeNotifier.value = clampedSize;
                  });
                }
                return AnimatedBuilder(
                  animation: _highlightAnimation,
                  builder: (context, child) {
                    final borderOpacity = widget.isHighlighted
                        ? _highlightAnimation.value
                        : 0.0;
                    return Container(
                      width: clampedSize.width,
                      height: clampedSize.height,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.blue.withOpacity(borderOpacity),
                          width: 3,
                        ),
                      ),
                      child: child,
                    );
                  },
                  child: SizedBox(
                    width: clampedSize.width,
                    height: clampedSize.height,
                    child: Card(
                      clipBehavior: Clip.antiAlias,
                      elevation: 2,
                      color: widget.backgroundColor,
                      surfaceTintColor: Colors.transparent,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _buildImageContent(
                            context,
                            Size(clampedSize.width, clampedSize.height),
                          ),
                          _buildHoverControls(),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageContent(BuildContext context, Size size) {
    return ValueListenableBuilder<double>(
      valueListenable: _scaleNotifier,
      builder: (context, scale, _) {
        final clampedScale = _clampScale(scale);
        if (clampedScale != scale) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scaleNotifier.value = clampedScale;
          });
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildImageLayer(size, clampedScale),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: switch (_visualState) {
                _CardVisualState.loading =>
                  _LoadingPlaceholder(progress: _latestChunk),
                _CardVisualState.error => _ErrorPlaceholder(
                    onRetry: _retryCount < _maxRetryCount ? _handleRetry : null,
                  ),
                _ => const SizedBox.shrink(),
              },
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => _focusNode.requestFocus(),
                onDoubleTap: () => widget.onOpenPreview(widget.item),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildImageLayer(Size size, double scale) {
    if (!_isResizing) {
      _attachImageStream(size, scale);
    }
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth =
        (size.width * scale * pixelRatio).clamp(64, 4096).round();

    final matrix = Matrix4.identity()
      ..translate(_imageOffset.dx, _imageOffset.dy)
      ..translate(size.width / 2, size.height / 2)
      ..scale(scale)
      ..translate(-size.width / 2, -size.height / 2);

    return Positioned.fill(
      child: ClipRect(
        child: Transform(
          alignment: Alignment.topLeft,
          transform: matrix,
          child: Image.file(
            File(widget.item.filePath),
            key: ValueKey('${widget.item.filePath}_${_imageKey}_$cacheWidth'),
            fit: BoxFit.contain,
            cacheWidth: cacheWidth,
            gaplessPlayback: true,
          ),
        ),
      ),
    );
  }

  Widget _buildHoverControls() {
    return Stack(
      children: [
        // メモボタン（左上）- 一括削除モード時は非表示
        if (!widget.isDeletionMode)
          Positioned(
            top: 12,
            left: 12,
            child: _fadeChild(
              child: Tooltip(
                message: widget.item.memo.isEmpty ? 'メモを追加' : 'メモを編集',
                child: ElevatedButton(
                  onPressed: _handleEditMemo,
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                    minimumSize: const Size(32, 32),
                    backgroundColor: widget.item.memo.isEmpty
                        ? null
                        : Theme.of(context).colorScheme.primaryContainer,
                  ),
                  child: Icon(
                    widget.item.memo.isEmpty ? Icons.note_add : Icons.edit_note,
                    size: 18,
                  ),
                ),
              ),
            ),
          ),
        // チェックボックス（左上、一括削除モード時のみ）または削除ボタン（右上）
        if (widget.isDeletionMode)
          Positioned(
            top: 12,
            left: 12,
            child: _buildSelectionCheckbox(), // 一括削除モード時は常時表示
          )
        else
          Positioned(
            top: 12,
            right: 12,
            child: _fadeChild(child: _buildDeleteButton()), // 通常時はホバーで表示
          ),
        // リサイズハンドル（四隅）- 一括削除モード時は非表示
        if (!widget.isDeletionMode) ...[
          // 右下
          Positioned(
            right: 0,
            bottom: 0,
            child: _fadeChild(
              child: _buildResizeHandle(ResizeCorner.bottomRight),
            ),
          ),
          // 左下
          Positioned(
            left: 0,
            bottom: 0,
            child: _fadeChild(
              child: _buildResizeHandle(ResizeCorner.bottomLeft),
            ),
          ),
          // 右上
          Positioned(
            right: 0,
            top: 0,
            child: _fadeChild(
              child: _buildResizeHandle(ResizeCorner.topRight),
            ),
          ),
          // 左上
          Positioned(
            left: 0,
            top: 0,
            child: _fadeChild(
              child: _buildResizeHandle(ResizeCorner.topLeft),
            ),
          ),
        ],
        // お気に入りボタン（左下）
        // 一括削除モード時: favorite > 0 の場合のみ常時表示、通常時: ホバー時のみ表示
        if (widget.isDeletionMode && widget.item.favorite > 0)
          Positioned(
            bottom: 12,
            left: 12,
            child: Tooltip(
              message: 'お気に入り',
              child: ElevatedButton(
                onPressed: _handleFavoriteToggle,
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                  minimumSize: const Size(32, 32),
                  backgroundColor:
                      _backgroundColorForFavorite(widget.item.favorite),
                ),
                child: Icon(
                  Icons.favorite,
                  size: 18,
                  color: Colors.white,
                ),
              ),
            ),
          )
        else if (!widget.isDeletionMode)
          Positioned(
            bottom: 12,
            left: 12,
            child: _fadeChild(
              child: Tooltip(
                message: 'お気に入り',
                child: ElevatedButton(
                  onPressed: _handleFavoriteToggle,
                  style: ElevatedButton.styleFrom(
                    padding: EdgeInsets.zero,
                    shape: const CircleBorder(),
                    minimumSize: const Size(32, 32),
                    backgroundColor:
                        _backgroundColorForFavorite(widget.item.favorite),
                  ),
                  child: Icon(
                    widget.item.favorite > 0
                        ? Icons.favorite
                        : Icons.favorite_border,
                    size: 18,
                    color: widget.item.favorite > 0 ? Colors.white : null,
                  ),
                ),
              ),
            ),
          ),
        // 並べ替えアイコン（下部中央）- 一括削除モード時は非表示
        if (!widget.isDeletionMode)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(
              child: _fadeChild(
                child: Listener(
                  onPointerDown: (event) {
                    widget.onReorderPointerDown
                        ?.call(widget.item.id, event.pointer);
                  },
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onPanStart: (details) {
                      debugPrint(
                        '[ImageCard] reorder_pan_start id=${widget.item.id} global=${details.globalPosition}',
                      );
                      widget.onStartReorder?.call(
                        widget.item.id,
                        details.globalPosition,
                      );
                    },
                    onPanUpdate: (details) {
                      debugPrint(
                        '[ImageCard] reorder_pan_update id=${widget.item.id} global=${details.globalPosition}',
                      );
                      widget.onReorderUpdate?.call(
                        widget.item.id,
                        details.globalPosition,
                      );
                    },
                    onPanEnd: (_) {
                      debugPrint(
                          '[ImageCard] reorder_pan_end id=${widget.item.id}');
                      widget.onReorderEnd?.call(widget.item.id);
                    },
                    onPanCancel: () {
                      debugPrint(
                          '[ImageCard] reorder_pan_cancel id=${widget.item.id}');
                      widget.onReorderCancel?.call(widget.item.id);
                    },
                    child: Container(
                      padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0x33000000),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _fadeChild({required Widget child}) {
    return AnimatedOpacity(
      opacity: _showControls ? 1 : 0,
      duration: const Duration(milliseconds: 150),
      child: IgnorePointer(
        ignoring: !_showControls,
        child: child,
      ),
    );
  }

  /// リサイズハンドルを構築する
  Widget _buildResizeHandle(ResizeCorner corner) {
    // コーナーに応じた角丸の位置を決定
    BorderRadius borderRadius;
    Alignment alignment;
    double rotation;

    switch (corner) {
      case ResizeCorner.bottomRight:
        borderRadius = const BorderRadius.only(topLeft: Radius.circular(12));
        alignment = Alignment.bottomRight;
        rotation = 0;
      case ResizeCorner.bottomLeft:
        borderRadius = const BorderRadius.only(topRight: Radius.circular(12));
        alignment = Alignment.bottomLeft;
        rotation = math.pi / 2; // 90度回転
      case ResizeCorner.topRight:
        borderRadius = const BorderRadius.only(bottomLeft: Radius.circular(12));
        alignment = Alignment.topRight;
        rotation = -math.pi / 2; // -90度回転
      case ResizeCorner.topLeft:
        borderRadius = const BorderRadius.only(bottomRight: Radius.circular(12));
        alignment = Alignment.topLeft;
        rotation = math.pi; // 180度回転
    }

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (details) => _onResizeStart(details, corner),
      onPanUpdate: _onResizeUpdate,
      onPanEnd: _onResizeEnd,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: const Color(0x44000000),
          borderRadius: borderRadius,
        ),
        alignment: alignment,
        child: Transform.rotate(
          angle: rotation,
          child: const Icon(
            Icons.open_in_full,
            size: 16,
            color: Colors.white,
          ),
        ),
      ),
    );
  }

  void _onResizeStart(DragStartDetails details, ResizeCorner corner) {
    // Get card's global position
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final globalOffset = box.localToGlobal(Offset.zero);
    final currentSize = _sizeNotifier.value;

    // ドラッグ中の固定点（アンカー）を計算（ドラッグコーナーの反対側）
    Offset anchor;
    switch (corner) {
      case ResizeCorner.bottomRight:
        // 左上が固定
        anchor = globalOffset;
      case ResizeCorner.bottomLeft:
        // 右上が固定
        anchor = Offset(globalOffset.dx + currentSize.width, globalOffset.dy);
      case ResizeCorner.topRight:
        // 左下が固定
        anchor = Offset(globalOffset.dx, globalOffset.dy + currentSize.height);
      case ResizeCorner.topLeft:
        // 右下が固定
        anchor = Offset(
          globalOffset.dx + currentSize.width,
          globalOffset.dy + currentSize.height,
        );
    }

    setState(() {
      _isResizing = true;
      _resizeStartSize = currentSize;
      _resizeStartGlobalPosition = details.globalPosition;
      _resizeStartSpan = _currentSpan;
      _resizeCorner = corner;
      _anchorPosition = anchor;
    });

    // Create and show overlay
    _overlayService = ResizePreviewOverlayService();
    _overlayService!.show(
      context: context,
      globalRect: Rect.fromLTWH(
        globalOffset.dx,
        globalOffset.dy,
        currentSize.width,
        currentSize.height,
      ),
      columnSpan: _currentSpan,
    );
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    if (_resizeStartSize == null ||
        _resizeStartGlobalPosition == null ||
        _resizeCorner == null ||
        _anchorPosition == null) {
      return;
    }

    final delta = details.globalPosition - _resizeStartGlobalPosition!;

    // コーナーに応じてデルタの符号を調整
    // 左側のコーナーからドラッグする場合、dxを反転
    double adjustedDx;
    switch (_resizeCorner!) {
      case ResizeCorner.bottomRight:
      case ResizeCorner.topRight:
        // 右方向へのドラッグで幅が増加
        adjustedDx = delta.dx;
      case ResizeCorner.bottomLeft:
      case ResizeCorner.topLeft:
        // 左方向へのドラッグで幅が増加（符号反転）
        adjustedDx = -delta.dx;
    }

    final targetWidth =
        (_resizeStartSize!.width + adjustedDx).clamp(_minWidth, _maxWidth);
    final snappedSpan = _snapSpan(targetWidth);
    final snappedWidth = _widthForSpan(snappedSpan);

    // 画像のアスペクト比に基づいて高さを計算（画像ロード済みの場合）
    double newHeight;
    if (_imageInfo != null) {
      final aspectRatio = _imageInfo!.image.width / _imageInfo!.image.height;
      newHeight = (snappedWidth / aspectRatio).clamp(_minHeight, _maxHeight);
    } else {
      // フォールバック: 画像未ロード時は垂直ドラッグに従う
      // 上側コーナーの場合はdyを反転
      double adjustedDy;
      switch (_resizeCorner!) {
        case ResizeCorner.bottomRight:
        case ResizeCorner.bottomLeft:
          adjustedDy = delta.dy;
        case ResizeCorner.topRight:
        case ResizeCorner.topLeft:
          adjustedDy = -delta.dy;
      }
      newHeight =
          (_resizeStartSize!.height + adjustedDy).clamp(_minHeight, _maxHeight);
    }

    // アンカー位置を基準にプレビューRectを計算
    final previewRect = _calculatePreviewRect(
      Size(snappedWidth, newHeight),
      _anchorPosition!,
      _resizeCorner!,
    );

    // Update overlay
    _overlayService?.update(
      globalRect: previewRect,
      columnSpan: snappedSpan,
    );

    // Update local state for span tracking
    final newSize = Size(snappedWidth, newHeight);
    if (snappedSpan != _currentSpan || _previewSize != newSize) {
      setState(() {
        _currentSpan = snappedSpan;
        _previewSize = newSize;
      });
    }
  }

  /// アンカー位置を基準にプレビューRectを計算する
  Rect _calculatePreviewRect(Size size, Offset anchor, ResizeCorner corner) {
    switch (corner) {
      case ResizeCorner.bottomRight:
        // 左上がアンカー
        return Rect.fromLTWH(anchor.dx, anchor.dy, size.width, size.height);
      case ResizeCorner.bottomLeft:
        // 右上がアンカー
        return Rect.fromLTWH(
          anchor.dx - size.width,
          anchor.dy,
          size.width,
          size.height,
        );
      case ResizeCorner.topRight:
        // 左下がアンカー
        return Rect.fromLTWH(
          anchor.dx,
          anchor.dy - size.height,
          size.width,
          size.height,
        );
      case ResizeCorner.topLeft:
        // 右下がアンカー
        return Rect.fromLTWH(
          anchor.dx - size.width,
          anchor.dy - size.height,
          size.width,
          size.height,
        );
    }
  }

  void _onResizeEnd(DragEndDetails details) {
    // Hide overlay
    _overlayService?.hide();
    _overlayService?.dispose();
    _overlayService = null;

    // プレビューサイズを最終サイズとして適用
    final finalSize = _previewSize ?? _sizeNotifier.value;
    _sizeNotifier.value = finalSize;

    // リサイズコーナーを保存してからクリア
    final corner = _resizeCorner;

    setState(() {
      _isResizing = false;
      _resizeStartSize = null;
      _resizeStartGlobalPosition = null;
      _previewSize = null;
      _resizeCorner = null;
      _anchorPosition = null;
    });

    _attachImageStream(finalSize, _currentScale);
    // onResize で customSize と columnSpan と resizeCorner を一緒に処理する
    // (GridViewModule._handleResize 内でスパンと目標列を計算)
    widget.onResize(widget.item.id, finalSize, corner: corner);
  }

  void _handlePointerDown(PointerDownEvent event) {
    print('[ImageCard] _handlePointerDown ENTRY: kind=${event.kind}, buttons=${event.buttons}');
    if (event.kind == PointerDeviceKind.mouse) {
      _isRightButtonPressed = event.buttons & kSecondaryMouseButton != 0;
      print('[ImageCard] pointerDown: id=${widget.item.id.split('/').last}, '
          'rightButton=$_isRightButtonPressed, buttons=${event.buttons}');
      // 右クリックでパン操作を開始
      if (_isRightButtonPressed) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final local = box.globalToLocal(event.position);
          _isPanning = true;
          _panStartLocal = local;
          _panStartOffset = _imageOffset;
          print('[ImageCard] pan_start: id=${widget.item.id.split('/').last}, '
              'scale=$_currentScale, startOffset=$_panStartOffset');
        }
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    print('[ImageCard] _handlePointerUp ENTRY: kind=${event.kind}');
    if (event.kind == PointerDeviceKind.mouse) {
      print('[ImageCard] pointerUp: id=${widget.item.id.split('/').last}, '
          'isPanning=$_isPanning');
      _isRightButtonPressed = false;
      if (_isPanning) {
        _isPanning = false;
        _panStartLocal = null;
        _panStartOffset = null;
        // パン終了時にオフセットを永続化
        print('[ImageCard] pan_end: id=${widget.item.id.split('/').last}, '
            'offset=$_imageOffset, scale=$_currentScale');
        widget.onPan(widget.item.id, _imageOffset);
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_isPanning || _panStartLocal == null || _panStartOffset == null) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) {
      return;
    }
    final local = box.globalToLocal(event.position);
    final delta = local - _panStartLocal!;
    setState(() {
      _imageOffset = clampPanOffset(
        offset: _panStartOffset! + delta,
        size: _sizeNotifier.value,
        scale: _currentScale,
      );
    });
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _isRightButtonPressed) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (resolvedEvent) {
          final scrollEvent = resolvedEvent as PointerScrollEvent;
          final box = context.findRenderObject() as RenderBox?;
          final local = box?.globalToLocal(scrollEvent.position);
          _handleWheelZoom(scrollEvent.scrollDelta.dy, focalPoint: local);
          _consumeScroll = true;
        },
      );
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrlPressed = pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    final shiftPressed = pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);

    if (ctrlPressed &&
        (event.logicalKey == LogicalKeyboardKey.equal ||
            event.logicalKey == LogicalKeyboardKey.numpadAdd)) {
      _applyZoom(0.1);
      return KeyEventResult.handled;
    }
    if (ctrlPressed &&
        (event.logicalKey == LogicalKeyboardKey.minus ||
            event.logicalKey == LogicalKeyboardKey.numpadSubtract)) {
      _applyZoom(-0.1);
      return KeyEventResult.handled;
    }
    if (ctrlPressed && event.logicalKey == LogicalKeyboardKey.keyC) {
      widget.onCopyImage(widget.item);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (shiftPressed) {
        _sizeNotifier.value = const Size(200, 200);
        widget.onResize(widget.item.id, _sizeNotifier.value);
      } else {
        widget.onOpenPreview(widget.item);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _applyZoom(double delta, {Offset? focalPoint}) {
    final target = _clampScale(_currentScale + delta);
    _applyZoomImmediate(target, focalPoint: focalPoint);
  }

  void _handleWheelZoom(double scrollDeltaY, {Offset? focalPoint}) {
    final zoomFactor = math.exp(-scrollDeltaY / 300.0);
    final targetScale = _clampScale(_currentScale * zoomFactor);
    _applyZoomImmediate(targetScale, focalPoint: focalPoint);
  }

  void _applyZoomImmediate(double targetScale, {Offset? focalPoint}) {
    targetScale = _clampScale(targetScale);
    if ((targetScale - _currentScale).abs() < 0.0001) {
      return;
    }
    _applyZoomWithMatrices(targetScale, focalPoint: focalPoint);
  }

  void _applyZoomWithMatrices(double targetScale, {Offset? focalPoint}) {
    final size = _sizeNotifier.value;
    final center = Offset(size.width / 2, size.height / 2);
    Offset newOffset;
    final scaleRatio = targetScale / (_currentScale == 0 ? 1 : _currentScale);
    if (focalPoint != null) {
      final focalVector = focalPoint - center;
      newOffset = focalVector * (1 - scaleRatio) + _imageOffset * scaleRatio;
    } else {
      newOffset = _imageOffset * scaleRatio;
    }
    newOffset = clampPanOffset(
      offset: newOffset,
      size: size,
      scale: targetScale,
    );
    setState(() {
      _imageOffset = newOffset;
    });
    _currentScale = targetScale;
    _suppressScaleListener = true;
    _scaleNotifier.value = targetScale;
    _suppressScaleListener = false;
    widget.onZoom(widget.item.id, targetScale);
  }

  Size _clampSize(Size size) {
    return Size(
      size.width.clamp(_minWidth, _maxWidth),
      size.height.clamp(_minHeight, _maxHeight),
    );
  }

  double _clampScale(double scale) {
    return scale.clamp(_minScale, _maxScale);
  }

  void _handleRetry() {
    setState(() {
      _retryCount += 1;
    });
    _retryStreamLocally();
    widget.onRetry(widget.item.id);
  }

  Future<void> _handleEditMemo() async {
    final newMemo = await showDialog<String>(
      context: context,
      builder: (context) => MemoEditDialog(
        initialMemo: widget.item.memo,
        fileName: p.basename(widget.item.filePath),
      ),
    );
    if (newMemo != null && mounted) {
      widget.onEditMemo(widget.item.id, newMemo);
    }
  }

  void _handleFavoriteToggle() {
    final next = (widget.item.favorite + 1) % 4;
    widget.onFavoriteToggle(widget.item.id, next);
  }

  Color? _backgroundColorForFavorite(int level) {
    switch (level) {
      case 1:
        return Colors.green;
      case 2:
        return Colors.orange;
      case 3:
        return Colors.pink;
      default:
        return null;
    }
  }

  void _handleTimeoutRetry() {
    _retryStreamLocally();
  }

  void _retryStreamLocally() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _reloadImage();
    });
  }

  void _updateVisualState(_CardVisualState state, {ImageChunkEvent? chunk}) {
    if (!mounted) {
      return;
    }
    final shouldUpdate = _visualState != state ||
        (_latestChunk?.cumulativeBytesLoaded ?? -1) !=
            (chunk?.cumulativeBytesLoaded ?? -1);
    if (!shouldUpdate) {
      return;
    }

    void apply() {
      if (!mounted) {
        return;
      }
      setState(() {
        _visualState = state;
        _latestChunk = chunk;
      });
      if (state == _CardVisualState.ready || state == _CardVisualState.error) {
        _loadingStateVersion += 1;
        _cancelLoadingTimeout();
      } else if (state == _CardVisualState.loading) {
        _scheduleLoadingTimeout();
      }
    }

    final binding = WidgetsBinding.instance;
    final phase = binding.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      apply();
      return;
    }

    binding.addPostFrameCallback((_) => apply());
  }

  void _attachImageStream(Size size, double scale) {
    final signature =
        '${widget.item.filePath}_${_imageKey}_${size.width.round()}_${size.height.round()}_${scale.toStringAsFixed(2)}';
    if (_resolvedSignature == signature) {
      // debugPrint(
      //     '[ImageCard] stream_skip id=${widget.item.id} signature=$signature');
      return;
    }
    debugPrint(
        '[ImageCard] stream_update id=${widget.item.id} signature=$signature prev=$_resolvedSignature');
    _resolvedSignature = signature;
    _setLoadingDeferred();
    _detachImageStream();
    final provider = FileImage(File(widget.item.filePath));
    final stream = provider.resolve(const ImageConfiguration());
    _streamListener = ImageStreamListener(
      (image, synchronousCall) {
        _retryCount = 0;
        _imageInfo = image;
        debugPrint(
            '[ImageCard] image_ready id=${widget.item.id} size=${size.width}x${size.height} scale=$scale naturalSize=${image.image.width}x${image.image.height}');
        _updateVisualState(_CardVisualState.ready);
      },
      onChunk: (event) {
        debugPrint(
            '[ImageCard] image_chunk id=${widget.item.id} loaded=${event.cumulativeBytesLoaded} expected=${event.expectedTotalBytes}');
        _updateVisualState(_CardVisualState.loading, chunk: event);
        _scheduleLoadingTimeout();
      },
      onError: (error, stackTrace) {
        debugPrint('[ImageCard] image_error id=${widget.item.id} error=$error');
        _updateVisualState(_CardVisualState.error);
        _cancelLoadingTimeout();
      },
    );
    _imageStream = stream;
    _imageStream?.addListener(_streamListener!);
    _scheduleLoadingTimeout();
  }

  void _detachImageStream() {
    if (_imageStream != null && _streamListener != null) {
      _imageStream!.removeListener(_streamListener!);
    }
    _imageStream = null;
    _streamListener = null;
    _cancelLoadingTimeout();
  }

  void _setLoadingDeferred() {
    _loadingStateVersion += 1;
    final version = _loadingStateVersion;
    if (_visualState == _CardVisualState.loading) {
      _scheduleLoadingTimeout();
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || version != _loadingStateVersion) {
        return;
      }
      if (_visualState == _CardVisualState.ready) {
        return;
      }
      if (_visualState != _CardVisualState.loading) {
        setState(() {
          _visualState = _CardVisualState.loading;
          _latestChunk = null;
        });
      }
      _scheduleLoadingTimeout();
    });
  }

  void _scheduleLoadingTimeout() {
    _loadingTimeout?.cancel();
    _loadingTimeout = Timer(const Duration(milliseconds: 800), () {
      if (!mounted) {
        return;
      }
      if (_visualState == _CardVisualState.loading) {
        debugPrint(
          '[ImageCard] loading_timeout id=${widget.item.id} size=${_sizeNotifier.value} scale=$_currentScale retry=$_retryCount',
        );
        _handleTimeoutRetry();
      }
    });
  }

  void _cancelLoadingTimeout() {
    _loadingTimeout?.cancel();
    _loadingTimeout = null;
  }

  int _computeSpan(double width) {
    return _snapSpan(width);
  }

  int _snapSpan(double targetWidth) {
    if (widget.columnCount <= 1) {
      return 1;
    }
    int bestSpan = 1;
    double bestDiff = double.infinity;
    for (int span = 1; span <= widget.columnCount; span++) {
      final width = _widthForSpan(span);
      final diff = (width - targetWidth).abs();
      if (diff < bestDiff - 0.1) {
        bestDiff = diff;
        bestSpan = span;
      }
    }
    return bestSpan.clamp(1, widget.columnCount);
  }

  double _widthForSpan(int span) {
    final clamped = span.clamp(1, widget.columnCount);
    return widget.columnWidth * clamped +
        widget.columnGap * math.max(0, clamped - 1);
  }

  bool _isShiftPressed() {
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    return pressed.contains(LogicalKeyboardKey.shiftLeft) ||
        pressed.contains(LogicalKeyboardKey.shiftRight);
  }

  void _setControlsVisible(bool visible) {
    if (_showControls == visible) {
      return;
    }
    setState(() {
      _showControls = visible;
    });
  }

  void _scheduleMemoTooltip() {
    // Only show tooltip if memo exists
    if (widget.item.memo.isEmpty) {
      return;
    }

    // Cancel any pending timer
    _cancelMemoTooltip();

    // Schedule tooltip to show after hover delay
    _memoHoverTimer = Timer(const Duration(milliseconds: 500), () {
      _showMemoTooltip();
    });
  }

  void _cancelMemoTooltip() {
    _memoHoverTimer?.cancel();
    _memoHoverTimer = null;
    _memoTooltipService?.hide();
  }

  void _showMemoTooltip() {
    if (!mounted || widget.item.memo.isEmpty) {
      return;
    }

    // Get card's global position
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null || !renderBox.hasSize) {
      return;
    }

    final cardRect = renderBox.localToGlobal(Offset.zero) & renderBox.size;

    // Create service if needed
    _memoTooltipService ??= MemoTooltipOverlayService();

    // Show tooltip
    _memoTooltipService!.show(
      context: context,
      cardRect: cardRect,
      memo: widget.item.memo,
    );
  }

  Widget _buildDeleteButton() {
    return Tooltip(
      message: '削除',
      child: ElevatedButton(
        onPressed: widget.onDelete != null
            ? () => widget.onDelete!(widget.item)
            : null,
        style: ElevatedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: const CircleBorder(),
          minimumSize: const Size(32, 32),
        ),
        child: const Icon(Icons.delete_outline, size: 18),
      ),
    );
  }

  Widget _buildSelectionCheckbox() {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: widget.isSelected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.surface,
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      child: widget.isSelected
          ? Icon(
              Icons.check,
              size: 18,
              color: Theme.of(context).colorScheme.onPrimary,
            )
          : null,
    ).withInkWell(
      onTap: widget.onSelectionToggle != null
          ? () => widget.onSelectionToggle!(widget.item.id)
          : null,
    );
  }
}

extension on Widget {
  Widget withInkWell({VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: this,
      ),
    );
  }
}

class _LoadingPlaceholder extends StatelessWidget {
  const _LoadingPlaceholder({super.key, this.progress});

  final ImageChunkEvent? progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double? value;
    if (progress != null && progress!.expectedTotalBytes != null) {
      value = progress!.cumulativeBytesLoaded / progress!.expectedTotalBytes!;
    } else {
      value = null;
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
      ),
      child: Center(
        child: SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(value: value),
        ),
      ),
    );
  }
}

class _ErrorPlaceholder extends StatelessWidget {
  const _ErrorPlaceholder({super.key, this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.colorScheme.errorContainer),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.broken_image,
              size: 32,
              color: theme.colorScheme.onErrorContainer,
            ),
            const SizedBox(height: 8),
            Text(
              '読み込みに失敗しました',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('再読み込み'),
            ),
          ],
        ),
      ),
    );
  }
}
