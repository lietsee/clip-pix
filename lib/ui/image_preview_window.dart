import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import '../data/models/image_item.dart';

class ImagePreviewWindow extends StatefulWidget {
  const ImagePreviewWindow({
    super.key,
    required this.item,
    this.initialAlwaysOnTop = false,
    this.onClose,
    this.onToggleAlwaysOnTop,
    this.onCopyImage,
  });

  final ImageItem item;
  final bool initialAlwaysOnTop;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onToggleAlwaysOnTop;
  final Future<void> Function(ImageItem item)? onCopyImage;

  @override
  State<ImagePreviewWindow> createState() => _ImagePreviewWindowState();
}

class _ImagePreviewWindowState extends State<ImagePreviewWindow> {
  final Logger _logger = Logger('ImagePreviewWindow');
  late bool _isAlwaysOnTop;
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    _isAlwaysOnTop = widget.initialAlwaysOnTop;
    if (_isAlwaysOnTop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_applyAlwaysOnTop(true)) {
          setState(() {
            _isAlwaysOnTop = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    if (_isAlwaysOnTop) {
      _applyAlwaysOnTop(false);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.escape): const _CloseIntent(),
      const SingleActivator(LogicalKeyboardKey.keyW, control: true):
          const _CloseIntent(),
      const SingleActivator(
        LogicalKeyboardKey.keyF,
        control: true,
        shift: true,
      ): const _ToggleAlwaysOnTopIntent(),
      const SingleActivator(LogicalKeyboardKey.keyC, control: true):
          const _CopyIntent(),
    };

    return Shortcuts(
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
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            appBar: _buildAppBar(context),
            body: Stack(
              children: [
                Positioned.fill(child: _buildImageView()),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: _buildOverlayControls(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final title = p.basename(widget.item.filePath);
    return AppBar(
      title: Text(title, overflow: TextOverflow.ellipsis),
      actions: [
        IconButton(
          tooltip: _isAlwaysOnTop
              ? '最前面表示を解除 (Ctrl+Shift+F)'
              : '最前面表示 (Ctrl+Shift+F)',
          onPressed: _toggleAlwaysOnTop,
          icon: Icon(
            _isAlwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
            color:
                _isAlwaysOnTop ? Theme.of(context).colorScheme.onPrimary : null,
          ),
          color: _isAlwaysOnTop ? Theme.of(context).colorScheme.primary : null,
        ),
        IconButton(
          tooltip: '閉じる (Esc)',
          onPressed: _handleClose,
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }

  Widget _buildOverlayControls(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        FloatingActionButton.small(
          heroTag: null,
          backgroundColor:
              _isAlwaysOnTop ? colorScheme.primary : colorScheme.surfaceVariant,
          foregroundColor:
              _isAlwaysOnTop ? colorScheme.onPrimary : colorScheme.onSurface,
          tooltip: _isAlwaysOnTop ? '最前面を解除' : '常に手前に表示',
          onPressed: _toggleAlwaysOnTop,
          child: Icon(
            _isAlwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
          ),
        ),
        const SizedBox(height: 12),
        FloatingActionButton.small(
          heroTag: null,
          tooltip: 'クリップボードにコピー (Ctrl+C)',
          onPressed: _copyImage,
          child: const Icon(Icons.copy),
        ),
      ],
    );
  }

  Widget _buildImageView() {
    final file = File(widget.item.filePath);
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: Image.file(
        file,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            _logger.severe('Failed to load preview image', error, stackTrace);
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
    );
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
    final applied = _applyAlwaysOnTop(desired);
    if (applied) {
      setState(() {
        _isAlwaysOnTop = desired;
      });
      widget.onToggleAlwaysOnTop?.call(desired);
    } else {
      widget.onToggleAlwaysOnTop?.call(false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('最前面の切り替えに失敗しました')),
      );
    }
  }

  bool _applyAlwaysOnTop(bool enable) {
    if (!Platform.isWindows) {
      return true;
    }
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) {
      _logger.warning('Failed to resolve window handle for preview window');
      return false;
    }
    final result = SetWindowPos(
      hwnd,
      enable ? HWND_TOPMOST : HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );
    if (result == 0) {
      final error = GetLastError();
      _logger.severe('SetWindowPos failed error=$error');
      return false;
    }
    return true;
  }

  void _handleClose() {
    if (_isClosing) {
      return;
    }
    _isClosing = true;
    widget.onClose?.call();
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
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
