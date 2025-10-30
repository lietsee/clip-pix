import 'dart:io';
import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:meta/meta.dart';

import 'package:path/path.dart' as p;

import '../data/models/image_item.dart';
import '../system/state/grid_layout_store.dart';
import 'widgets/memo_edit_dialog.dart';

class ImageCard extends StatefulWidget {
  const ImageCard({
    super.key,
    required this.item,
    required this.viewState,
    required this.onResize,
    required this.onSpanChange,
    required this.onZoom,
    required this.onRetry,
    required this.onOpenPreview,
    required this.onCopyImage,
    required this.onEditMemo,
    required this.onFavoriteToggle,
    required this.columnWidth,
    required this.columnCount,
    required this.columnGap,
    required this.backgroundColor,
    this.onReorderPointerDown,
    this.onStartReorder,
    this.onReorderUpdate,
    this.onReorderEnd,
    this.onReorderCancel,
  });

  final ImageItem item;
  final GridCardViewState viewState;
  final void Function(String id, Size newSize) onResize;
  final void Function(String id, int span) onSpanChange;
  final void Function(String id, double scale) onZoom;
  final void Function(String id) onRetry;
  final void Function(ImageItem item) onOpenPreview;
  final void Function(ImageItem item) onCopyImage;
  final void Function(String id, String memo) onEditMemo;
  final void Function(String id, int favorite) onFavoriteToggle;
  final double columnWidth;
  final int columnCount;
  final double columnGap;
  final Color backgroundColor;
  final void Function(String id, int pointer)? onReorderPointerDown;
  final void Function(String id, Offset globalPosition)? onStartReorder;
  final void Function(String id, Offset globalPosition)? onReorderUpdate;
  final void Function(String id)? onReorderEnd;
  final void Function(String id)? onReorderCancel;

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

class _ImageCardState extends State<ImageCard> {
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
  Offset? _panStartLocal;
  Offset? _panStartOffset;
  Offset _imageOffset = Offset.zero;
  ImageChunkEvent? _latestChunk;
  Key _imageKey = UniqueKey();
  ImageStream? _imageStream;
  ImageStreamListener? _streamListener;
  String? _resolvedSignature;
  double _currentScale = 1.0;
  bool _suppressScaleListener = false;
  Timer? _loadingTimeout;
  int _loadingStateVersion = 0;
  late ValueNotifier<Size> _sizeNotifier;
  late ValueNotifier<double> _scaleNotifier;

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
  }

  @override
  void didUpdateWidget(covariant ImageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // リサイズ中は外部からのサイズ同期をスキップ
    if (!_isResizing) {
      final newSize = Size(widget.viewState.width, widget.viewState.height);
      if (_sizeNotifier.value != newSize) {
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
    if (oldWidget.columnWidth != widget.columnWidth ||
        oldWidget.columnGap != widget.columnGap ||
        oldWidget.columnCount != widget.columnCount) {
      _currentSpan = widget.viewState.columnSpan;
    }
    if (oldWidget.viewState.columnSpan != widget.viewState.columnSpan) {
      _currentSpan = widget.viewState.columnSpan;
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _sizeNotifier.removeListener(_handleSizeExternalChange);
    _scaleNotifier.removeListener(_handleScaleExternalChange);
    _sizeNotifier.dispose();
    _scaleNotifier.dispose();
    _detachImageStream();
    _cancelLoadingTimeout();
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
          onPointerDown: _handlePointerDown,
          onPointerUp: _handlePointerUp,
          onPointerMove: _handlePointerMove,
          onPointerSignal: _handlePointerSignal,
          child: MouseRegion(
            onEnter: (_) => _setControlsVisible(true),
            onExit: (_) => _setControlsVisible(false),
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
                return SizedBox(
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
                onTap: () => widget.onOpenPreview(widget.item),
                onDoubleTap: () => widget.onOpenPreview(widget.item),
                onTapDown: (_) => _focusNode.requestFocus(),
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
        // メモボタン（左上）
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
        // コピーボタン（右上）
        Positioned(
          top: 12,
          right: 12,
          child: _fadeChild(
            child: Tooltip(
              message: 'コピー',
              child: ElevatedButton(
                onPressed: () => widget.onCopyImage(widget.item),
                style: ElevatedButton.styleFrom(
                  padding: EdgeInsets.zero,
                  shape: const CircleBorder(),
                  minimumSize: const Size(32, 32),
                ),
                child: const Icon(Icons.copy, size: 18),
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          child: _fadeChild(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onPanStart: _onResizeStart,
              onPanUpdate: _onResizeUpdate,
              onPanEnd: _onResizeEnd,
              child: Semantics(
                label: 'サイズ変更ハンドル',
                button: true,
                child: Container(
                  width: 24,
                  height: 24,
                  decoration: const BoxDecoration(
                    color: Color(0x44000000),
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(12),
                    ),
                  ),
                  alignment: Alignment.bottomRight,
                  child: const Icon(
                    Icons.open_in_full,
                    size: 16,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ),
        ),
        // お気に入りボタン（左下）
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
                  backgroundColor: _backgroundColorForFavorite(widget.item.favorite),
                ),
                child: Icon(
                  widget.item.favorite > 0 ? Icons.favorite : Icons.favorite_border,
                  size: 18,
                  color: widget.item.favorite > 0 ? Colors.white : null,
                ),
              ),
            ),
          ),
        ),
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

  void _onResizeStart(DragStartDetails details) {
    setState(() {
      _isResizing = true;
      _resizeStartSize = _sizeNotifier.value;
      _resizeStartGlobalPosition = details.globalPosition;
      _resizeStartSpan = _currentSpan;
    });
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    if (_resizeStartSize == null || _resizeStartGlobalPosition == null) {
      return;
    }
    final delta = details.globalPosition - _resizeStartGlobalPosition!;
    final targetWidth =
        (_resizeStartSize!.width + delta.dx).clamp(_minWidth, _maxWidth);
    final snappedSpan = _snapSpan(targetWidth);
    final snappedWidth = _widthForSpan(snappedSpan);
    final newHeight =
        (_resizeStartSize!.height + delta.dy).clamp(_minHeight, _maxHeight);
    final newSize = Size(snappedWidth, newHeight);
    if (_sizeNotifier.value != newSize) {
      _sizeNotifier.value = newSize;
    }
    if (snappedSpan != _currentSpan) {
      setState(() {
        _currentSpan = snappedSpan;
      });
    }
  }

  void _onResizeEnd(DragEndDetails details) {
    setState(() {
      _isResizing = false;
      _resizeStartSize = null;
      _resizeStartGlobalPosition = null;
    });
    _attachImageStream(_sizeNotifier.value, _currentScale);
    widget.onResize(widget.item.id, _sizeNotifier.value);
    if (_currentSpan != _resizeStartSpan) {
      widget.onSpanChange(widget.item.id, _currentSpan);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _isRightButtonPressed = event.buttons & kSecondaryMouseButton != 0;
      final shiftPressed = _isShiftPressed();
      if (shiftPressed && event.buttons & kPrimaryMouseButton != 0) {
        final box = context.findRenderObject() as RenderBox?;
        if (box != null) {
          final local = box.globalToLocal(event.position);
          _isPanning = true;
          _panStartLocal = local;
          _panStartOffset = _imageOffset;
        }
      }
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _isRightButtonPressed = false;
      if (_isPanning) {
        _isPanning = false;
        _panStartLocal = null;
        _panStartOffset = null;
      }
    }
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (!_isPanning || _panStartLocal == null || _panStartOffset == null) {
      return;
    }
    if (!_isShiftPressed()) {
      _isPanning = false;
      _panStartLocal = null;
      _panStartOffset = null;
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
        debugPrint(
            '[ImageCard] image_ready id=${widget.item.id} size=${size.width}x${size.height} scale=$scale');
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
