import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';

import '../data/models/image_item.dart';

class ImageCard extends StatefulWidget {
  const ImageCard({
    super.key,
    required this.item,
    required this.sizeNotifier,
    required this.scaleNotifier,
    required this.onResize,
    required this.onZoom,
    required this.onRetry,
    required this.onOpenPreview,
    required this.onCopyImage,
  });

  final ImageItem item;
  final ValueNotifier<Size> sizeNotifier;
  final ValueNotifier<double> scaleNotifier;
  final void Function(String id, Size newSize) onResize;
  final void Function(String id, double scale) onZoom;
  final void Function(String id) onRetry;
  final void Function(ImageItem item) onOpenPreview;
  final void Function(ImageItem item) onCopyImage;

  @override
  State<ImageCard> createState() => _ImageCardState();
}

enum _CardVisualState { loading, ready, error }

class _ImageCardState extends State<ImageCard> {
  static const double _minWidth = 100;
  static const double _minHeight = 100;
  static const double _maxWidth = 1920;
  static const double _maxHeight = 1080;
  static const double _minScale = 0.5;
  static const double _maxScale = 3.0;
  static const double _zoomFactor = 400;
  static const int _maxRetryCount = 3;

  final FocusNode _focusNode = FocusNode(debugLabel: 'ImageCardFocus');
  _CardVisualState _visualState = _CardVisualState.loading;
  bool _consumeScroll = false;
  bool _isRightButtonPressed = false;
  bool _isResizing = false;
  int _retryCount = 0;
  Size? _resizeStartSize;
  Offset? _resizeStartGlobalPosition;
  ImageChunkEvent? _latestChunk;
  Key _imageKey = UniqueKey();
  ImageStream? _imageStream;
  ImageStreamListener? _streamListener;
  String? _resolvedSignature;

  @override
  void initState() {
    super.initState();
    widget.sizeNotifier.addListener(_handleSizeExternalChange);
    widget.scaleNotifier.addListener(_handleScaleExternalChange);
  }

  @override
  void didUpdateWidget(covariant ImageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sizeNotifier != widget.sizeNotifier) {
      oldWidget.sizeNotifier.removeListener(_handleSizeExternalChange);
      widget.sizeNotifier.addListener(_handleSizeExternalChange);
    }
    if (oldWidget.scaleNotifier != widget.scaleNotifier) {
      oldWidget.scaleNotifier.removeListener(_handleScaleExternalChange);
      widget.scaleNotifier.addListener(_handleScaleExternalChange);
    }
    if (oldWidget.item.filePath != widget.item.filePath) {
      _reloadImage();
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    widget.sizeNotifier.removeListener(_handleSizeExternalChange);
    widget.scaleNotifier.removeListener(_handleScaleExternalChange);
    _detachImageStream();
    super.dispose();
  }

  void _handleSizeExternalChange() {
    final size = _clampSize(widget.sizeNotifier.value);
    if (size != widget.sizeNotifier.value) {
      widget.sizeNotifier.value = size;
    }
  }

  void _handleScaleExternalChange() {
    final scale = _clampScale(widget.scaleNotifier.value);
    if (scale != widget.scaleNotifier.value) {
      widget.scaleNotifier.value = scale;
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
          onPointerSignal: _handlePointerSignal,
          child: MouseRegion(
            cursor: _isResizing
                ? SystemMouseCursors.resizeUpLeftDownRight
                : SystemMouseCursors.basic,
            child: ValueListenableBuilder<Size>(
              valueListenable: widget.sizeNotifier,
              builder: (context, size, _) {
                final clampedSize = _clampSize(size);
                if (clampedSize != size) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    widget.sizeNotifier.value = clampedSize;
                  });
                }
                return SizedBox(
                  width: clampedSize.width,
                  height: clampedSize.height,
                  child: Card(
                    clipBehavior: Clip.antiAlias,
                    elevation: 2,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _buildImageContent(context, clampedSize),
                        _buildResizeHandle(),
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
      valueListenable: widget.scaleNotifier,
      builder: (context, scale, _) {
        final clampedScale = _clampScale(scale);
        if (clampedScale != scale) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            widget.scaleNotifier.value = clampedScale;
          });
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            _buildImageLayer(size, clampedScale),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: switch (_visualState) {
                _CardVisualState.loading => _LoadingPlaceholder(
                  key: const ValueKey('loading'),
                  progress: _latestChunk,
                ),
                _CardVisualState.error => _ErrorPlaceholder(
                  key: const ValueKey('error'),
                  onRetry: _retryCount < _maxRetryCount ? _handleRetry : null,
                ),
                _ => const SizedBox.shrink(),
              },
            ),
            Positioned.fill(
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: () => widget.onOpenPreview(widget.item),
                  onDoubleTap: () => widget.onOpenPreview(widget.item),
                  onTapDown: (_) => _focusNode.requestFocus(),
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
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
          ],
        );
      },
    );
  }

  Widget _buildImageLayer(Size size, double scale) {
    _attachImageStream(size, scale);
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final cacheWidth = (size.width * scale * pixelRatio)
        .clamp(64, 4096)
        .round();

    return Positioned.fill(
      child: Transform.scale(
        scale: scale,
        child: Image.file(
          File(widget.item.filePath),
          key: ValueKey('${widget.item.filePath}_${_imageKey}_$cacheWidth'),
          fit: BoxFit.contain,
          cacheWidth: cacheWidth,
        ),
      ),
    );
  }

  Widget _buildResizeHandle() {
    return Positioned(
      right: 0,
      bottom: 0,
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
              color: Color(0x33000000),
              borderRadius: BorderRadius.only(topLeft: Radius.circular(12)),
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
    );
  }

  void _onResizeStart(DragStartDetails details) {
    setState(() {
      _isResizing = true;
      _resizeStartSize = widget.sizeNotifier.value;
      _resizeStartGlobalPosition = details.globalPosition;
    });
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    if (_resizeStartSize == null || _resizeStartGlobalPosition == null) {
      return;
    }
    final delta = details.globalPosition - _resizeStartGlobalPosition!;
    final newSize = Size(
      _resizeStartSize!.width + delta.dx,
      _resizeStartSize!.height + delta.dy,
    );
    final clamped = _clampSize(newSize);
    widget.sizeNotifier.value = clamped;
  }

  void _onResizeEnd(DragEndDetails details) {
    setState(() {
      _isResizing = false;
      _resizeStartSize = null;
      _resizeStartGlobalPosition = null;
    });
    widget.onResize(widget.item.id, widget.sizeNotifier.value);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _isRightButtonPressed = event.buttons & kSecondaryMouseButton != 0;
    }
  }

  void _handlePointerUp(PointerUpEvent event) {
    if (event.kind == PointerDeviceKind.mouse) {
      _isRightButtonPressed = false;
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent && _isRightButtonPressed) {
      final delta = -event.scrollDelta.dy / _zoomFactor;
      _applyZoom(delta);
      _consumeScroll = true;
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final pressed = HardwareKeyboard.instance.logicalKeysPressed;
    final ctrlPressed =
        pressed.contains(LogicalKeyboardKey.controlLeft) ||
        pressed.contains(LogicalKeyboardKey.controlRight);
    final shiftPressed =
        pressed.contains(LogicalKeyboardKey.shiftLeft) ||
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
        widget.sizeNotifier.value = const Size(200, 200);
        widget.onResize(widget.item.id, widget.sizeNotifier.value);
      } else {
        widget.onOpenPreview(widget.item);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _applyZoom(double delta) {
    final newScale = _clampScale(widget.scaleNotifier.value + delta);
    widget.scaleNotifier.value = newScale;
    widget.onZoom(widget.item.id, newScale);
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
      _visualState = _CardVisualState.loading;
      _retryCount += 1;
      _imageKey = UniqueKey();
      _resolvedSignature = null;
    });
    _detachImageStream();
    widget.onRetry(widget.item.id);
  }

  void _updateVisualState(_CardVisualState state, {ImageChunkEvent? chunk}) {
    if (!mounted) {
      return;
    }
    final shouldUpdate =
        _visualState != state ||
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
    }

    final phase = WidgetsBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks ||
        phase == SchedulerPhase.persistentCallbacks) {
      apply();
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => apply());
  }

  void _attachImageStream(Size size, double scale) {
    final signature =
        '${widget.item.filePath}_${_imageKey}_${size.width.toStringAsFixed(2)}_${size.height.toStringAsFixed(2)}_${scale.toStringAsFixed(2)}';
    if (_resolvedSignature == signature) {
      return;
    }
    _resolvedSignature = signature;
    _setLoadingDeferred();
    _detachImageStream();
    final provider = FileImage(File(widget.item.filePath));
    final stream = provider.resolve(const ImageConfiguration());
    _streamListener = ImageStreamListener(
      (image, synchronousCall) {
        _retryCount = 0;
        _updateVisualState(_CardVisualState.ready);
      },
      onChunk: (event) {
        _updateVisualState(_CardVisualState.loading, chunk: event);
      },
      onError: (error, stackTrace) {
        _updateVisualState(_CardVisualState.error);
      },
    );
    _imageStream = stream;
    _imageStream?.addListener(_streamListener!);
  }

  void _detachImageStream() {
    if (_imageStream != null && _streamListener != null) {
      _imageStream!.removeListener(_streamListener!);
    }
    _imageStream = null;
    _streamListener = null;
    _resolvedSignature = null;
  }

  void _setLoadingDeferred() {
    if (_visualState == _CardVisualState.loading) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _visualState = _CardVisualState.loading;
        _latestChunk = null;
      });
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
