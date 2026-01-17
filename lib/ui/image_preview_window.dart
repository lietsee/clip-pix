import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show Vector3;
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../data/image_preview_state_repository.dart';
import '../data/models/image_item.dart';
import '../system/window/always_on_top_helper.dart';

class ImagePreviewWindow extends StatefulWidget {
  const ImagePreviewWindow({
    super.key,
    required this.item,
    this.initialAlwaysOnTop = false,
    this.initialZoomScale,
    this.initialPanOffsetX,
    this.initialPanOffsetY,
    this.repository,
    this.onClose,
    this.onToggleAlwaysOnTop,
    this.onCopyImage,
    this.onSaveZoomState,
  });

  final ImageItem item;
  final bool initialAlwaysOnTop;
  final double? initialZoomScale;
  final double? initialPanOffsetX;
  final double? initialPanOffsetY;
  final ImagePreviewStateRepository? repository;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onToggleAlwaysOnTop;
  final Future<void> Function(ImageItem item)? onCopyImage;
  final Future<void> Function(double scale, double panX, double panY)?
      onSaveZoomState;

  @override
  State<ImagePreviewWindow> createState() => _ImagePreviewWindowState();
}

class _ImagePreviewWindowState extends State<ImagePreviewWindow>
    with WindowListener {
  final Logger _logger = Logger('ImagePreviewWindow');
  late bool _isAlwaysOnTop;
  bool _isClosing = false;
  bool _showUIElements = true;
  Timer? _autoHideTimer;

  // Window bounds saving state
  Timer? _boundsDebounceTimer;
  bool _needsSave = false;

  // Zoom state
  final TransformationController _transformationController =
      TransformationController();
  double _currentZoom = 1.0;
  static const double _minZoom = 0.5;
  static const double _maxZoom = 15.0;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _isAlwaysOnTop = widget.initialAlwaysOnTop;

    // Restore zoom state if provided
    _restoreZoomState();

    if (_isAlwaysOnTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (mounted) {
          final success = await _applyAlwaysOnTop(true);
          if (!success && mounted) {
            setState(() {
              _isAlwaysOnTop = false;
            });
          }
        }
      });
    }
  }

  void _restoreZoomState() {
    final scale = widget.initialZoomScale;
    final panX = widget.initialPanOffsetX;
    final panY = widget.initialPanOffsetY;

    if (scale != null && scale != 1.0) {
      final matrix = Matrix4.identity();
      // ignore: deprecated_member_use
      matrix.scale(scale);
      if (panX != null && panY != null) {
        matrix.setTranslation(Vector3(panX, panY, 0));
      }
      _transformationController.value = matrix;
      _currentZoom = scale;
    }
  }

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    _boundsDebounceTimer?.cancel();
    _transformationController.dispose();
    windowManager.removeListener(this);
    if (_isAlwaysOnTop) {
      // Fire-and-forget since window is closing
      unawaited(_applyAlwaysOnTop(false));
    }
    super.dispose();
  }

  /// Trigger debounced save (called on resize/move events)
  void _triggerDebouncedSave() {
    _needsSave = true;
    _boundsDebounceTimer?.cancel();
    _boundsDebounceTimer = Timer(const Duration(milliseconds: 300), () {
      _saveBounds(flush: false);
    });
  }

  /// Common method to save window bounds
  Future<void> _saveBounds({required bool flush}) async {
    if (widget.repository == null) return;

    try {
      final bounds = await windowManager.getBounds();
      await widget.repository!.save(
        widget.item.id,
        bounds,
        alwaysOnTop: _isAlwaysOnTop,
      );

      _needsSave = false; // Clear dirty flag after successful save

      if (flush) {
        await Hive.close(); // Flush to disk on window close
      }

      _logger.fine(
          'Saved window bounds: $bounds, alwaysOnTop: $_isAlwaysOnTop, flush: $flush');
    } catch (e, stackTrace) {
      _logger.warning('Failed to save window bounds', e, stackTrace);
    }
  }

  // WindowListener implementation
  @override
  void onWindowResized() {
    debugPrint('[ImagePreviewWindow] onWindowResized triggered');
    _triggerDebouncedSave();
  }

  @override
  void onWindowMoved() {
    debugPrint('[ImagePreviewWindow] onWindowMoved triggered');
    _triggerDebouncedSave();
  }

  @override
  Future<void> onWindowClose() async {
    debugPrint('[ImagePreviewWindow] onWindowClose triggered');
    if (_isClosing) return;
    _isClosing = true;

    _boundsDebounceTimer?.cancel(); // Cancel any pending debounced save

    // Save window bounds only if there are unsaved changes or debounce timer was active
    if (_needsSave || _boundsDebounceTimer != null) {
      debugPrint(
          '[ImagePreviewWindow] Saving bounds on close (needsSave: $_needsSave, timerActive: ${_boundsDebounceTimer != null})');
      await _saveBounds(flush: true);
    } else {
      debugPrint(
          '[ImagePreviewWindow] Skipping bounds save on close (already saved)');
    }

    widget.onClose?.call();
  }

  @override
  Widget build(BuildContext context) {
    // Use meta (Cmd) on macOS, control on Windows/Linux
    final bool useMeta = Platform.isMacOS;

    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): const _CloseIntent(),
      SingleActivator(LogicalKeyboardKey.keyW,
          control: !useMeta, meta: useMeta): const _CloseIntent(),
      SingleActivator(LogicalKeyboardKey.keyF,
          control: !useMeta, meta: useMeta, shift: true):
          const _ToggleAlwaysOnTopIntent(),
      SingleActivator(LogicalKeyboardKey.keyC,
          control: !useMeta, meta: useMeta): const _CopyIntent(),
      const SingleActivator(LogicalKeyboardKey.f11):
          const _ToggleUIElementsIntent(),
      // Zoom shortcuts
      SingleActivator(LogicalKeyboardKey.equal,
          control: !useMeta, meta: useMeta): const _ZoomInIntent(),
      SingleActivator(LogicalKeyboardKey.minus,
          control: !useMeta, meta: useMeta): const _ZoomOutIntent(),
      SingleActivator(LogicalKeyboardKey.digit0,
          control: !useMeta, meta: useMeta): const _ZoomResetIntent(),
      SingleActivator(LogicalKeyboardKey.numpadAdd,
          control: !useMeta, meta: useMeta): const _ZoomInIntent(),
      SingleActivator(LogicalKeyboardKey.numpadSubtract,
          control: !useMeta, meta: useMeta): const _ZoomOutIntent(),
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: MouseRegion(
        onHover: (event) => _handleMouseMove(event.localPosition),
        child: Shortcuts(
          shortcuts: shortcuts,
          child: Actions(
            actions: <Type, Action<Intent>>{
              _CloseIntent: CallbackAction<_CloseIntent>(onInvoke: (_) {
                _handleClose();
                return null;
              }),
              _ToggleAlwaysOnTopIntent:
                  CallbackAction<_ToggleAlwaysOnTopIntent>(onInvoke: (_) {
                _toggleAlwaysOnTop();
                return null;
              }),
              _CopyIntent: CallbackAction<_CopyIntent>(onInvoke: (_) {
                _copyImage();
                return null;
              }),
              _ToggleUIElementsIntent:
                  CallbackAction<_ToggleUIElementsIntent>(onInvoke: (_) {
                _toggleUIElements();
                return null;
              }),
              _ZoomInIntent: CallbackAction<_ZoomInIntent>(onInvoke: (_) {
                _zoomIn();
                return null;
              }),
              _ZoomOutIntent: CallbackAction<_ZoomOutIntent>(onInvoke: (_) {
                _zoomOut();
                return null;
              }),
              _ZoomResetIntent: CallbackAction<_ZoomResetIntent>(onInvoke: (_) {
                _resetZoom();
                return null;
              }),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                appBar: _buildAppBar(context),
                body: Stack(
                  children: [
                    Positioned.fill(child: _buildImageView()),
                    if (!_showUIElements)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        height: 40,
                        child: DragToMoveArea(
                          child: Container(color: Colors.transparent),
                        ),
                      ),
                    // Zoom level indicator
                    Positioned(
                      bottom: 16,
                      left: 16,
                      child: AnimatedOpacity(
                        opacity: _currentZoom != 1.0 ? 1.0 : 0.0,
                        duration: const Duration(milliseconds: 200),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Text(
                            '${(_currentZoom * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _toggleUIElements() {
    setState(() {
      _showUIElements = !_showUIElements;
    });

    if (!_showUIElements) {
      _autoHideTimer?.cancel();
      _autoHideTimer = null;
    }
  }

  void _showTemporarily() {
    _autoHideTimer?.cancel();

    setState(() {
      _showUIElements = true;
    });

    _autoHideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() {
          _showUIElements = false;
        });
      }
    });
  }

  void _handleMouseMove(Offset position) {
    if (!_showUIElements) {
      final size = MediaQuery.of(context).size;
      final isTopArea = position.dy < size.height * 0.1;

      if (isTopArea) {
        _showTemporarily();
      }
    }
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final title = p.basename(widget.item.filePath);

    if (!_showUIElements) {
      return PreferredSize(
        preferredSize: Size.zero,
        child: SizedBox.shrink(),
      );
    }

    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
      child: AnimatedOpacity(
        opacity: _showUIElements ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: DragToMoveArea(
          child: AppBar(
            title: Text(title, overflow: TextOverflow.ellipsis),
            actions: [
              IconButton(
                tooltip: _isAlwaysOnTop
                    ? '最前面表示を解除 (Ctrl+Shift+F)'
                    : '最前面表示 (Ctrl+Shift+F)',
                onPressed: _toggleAlwaysOnTop,
                style: IconButton.styleFrom(
                  backgroundColor: _isAlwaysOnTop
                      ? Theme.of(context).colorScheme.primary.withOpacity(0.2)
                      : null,
                ),
                icon: Icon(
                  Icons.push_pin,
                  color: _isAlwaysOnTop
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey.shade600,
                ),
              ),
              IconButton(
                tooltip: 'クリップボードにコピー (Ctrl+C)',
                onPressed: _copyImage,
                icon: const Icon(Icons.copy),
              ),
              IconButton(
                tooltip: '閉じる (Esc)',
                onPressed: _handleClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageView() {
    final file = File(widget.item.filePath);
    return Container(
      color: Colors.black,
      child: GestureDetector(
        onDoubleTap: _resetZoom,
        child: InteractiveViewer(
          transformationController: _transformationController,
          minScale: _minZoom,
          maxScale: _maxZoom,
          onInteractionEnd: (_) => _updateZoomLevel(),
          child: Center(
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!mounted) return;
                  _logger.severe(
                      'Failed to load preview image', error, stackTrace);
                  widget.onClose?.call();
                  if (Navigator.of(context).canPop()) {
                    Navigator.of(context).pop();
                  }
                });
                return Container(
                  color: Colors.grey.shade900,
                  alignment: Alignment.center,
                  child: const Text(
                    '読み込みに失敗しました',
                    style: TextStyle(color: Colors.white70),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  // Zoom control methods
  void _zoomIn() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale * 1.25).clamp(_minZoom, _maxZoom);
    _animateToScale(newScale);
  }

  void _zoomOut() {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    final newScale = (currentScale / 1.25).clamp(_minZoom, _maxZoom);
    _animateToScale(newScale);
  }

  void _resetZoom() {
    _transformationController.value = Matrix4.identity();
    _updateZoomLevel();
  }

  void _animateToScale(double targetScale) {
    final currentScale = _transformationController.value.getMaxScaleOnAxis();
    if ((currentScale - targetScale).abs() < 0.001) return;

    final scaleRatio = targetScale / currentScale;

    // Scale around the center of the viewport
    final viewportSize = MediaQuery.of(context).size;
    final center = Offset(viewportSize.width / 2, viewportSize.height / 2);

    final currentMatrix = _transformationController.value.clone();

    // Apply scale around center
    // ignore: deprecated_member_use
    currentMatrix.translate(center.dx, center.dy);
    // ignore: deprecated_member_use
    currentMatrix.scale(scaleRatio);
    // ignore: deprecated_member_use
    currentMatrix.translate(-center.dx, -center.dy);

    _transformationController.value = currentMatrix;
    _updateZoomLevel();
  }

  void _updateZoomLevel() {
    setState(() {
      _currentZoom = _transformationController.value.getMaxScaleOnAxis();
    });
  }

  /// Get current zoom state for saving
  (double scale, double panX, double panY) getZoomState() {
    final matrix = _transformationController.value;
    final scale = matrix.getMaxScaleOnAxis();
    final translation = matrix.getTranslation();
    return (scale, translation.x, translation.y);
  }

  Future<void> _copyImage() async {
    final callback = widget.onCopyImage;
    if (callback == null) {
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    try {
      await Future<void>.sync(() => callback(widget.item));
      messenger.showSnackBar(
        const SnackBar(content: Text('クリップボードにコピーしました')),
      );
    } catch (error, stackTrace) {
      _logger.severe('copy_failure ${widget.item.filePath}', error, stackTrace);
      messenger.showSnackBar(
        const SnackBar(content: Text('コピーに失敗しました')),
      );
    }
  }

  void _toggleAlwaysOnTop() {
    final desired = !_isAlwaysOnTop;
    unawaited(_applyAlwaysOnTopAndUpdate(desired));
  }

  Future<void> _applyAlwaysOnTopAndUpdate(bool desired) async {
    final applied = await _applyAlwaysOnTop(desired);
    if (!mounted) return;
    if (applied) {
      setState(() {
        _isAlwaysOnTop = desired;
      });
      _needsSave =
          true; // Mark that bounds need to be saved (alwaysOnTop state changed)
      widget.onToggleAlwaysOnTop?.call(desired);
    } else {
      widget.onToggleAlwaysOnTop?.call(false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最前面の切り替えに失敗しました')),
      );
    }
  }

  Future<bool> _applyAlwaysOnTop(bool enable) async {
    return applyAlwaysOnTop(enable);
  }

  Future<void> _handleClose() async {
    // Delegate to onWindowClose for consistent behavior
    await onWindowClose();
  }
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

class _ToggleAlwaysOnTopIntent extends Intent {
  const _ToggleAlwaysOnTopIntent();
}

class _CopyIntent extends Intent {
  const _CopyIntent();
}

class _ToggleUIElementsIntent extends Intent {
  const _ToggleUIElementsIntent();
}

class _ZoomInIntent extends Intent {
  const _ZoomInIntent();
}

class _ZoomOutIntent extends Intent {
  const _ZoomOutIntent();
}

class _ZoomResetIntent extends Intent {
  const _ZoomResetIntent();
}
