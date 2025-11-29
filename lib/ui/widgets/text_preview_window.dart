import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../../data/models/text_content_item.dart';
import '../../data/text_preview_state_repository.dart';
import '../../system/window/always_on_top_helper.dart';

/// テキストコンテンツを別ウィンドウで表示・編集する
class TextPreviewWindow extends StatefulWidget {
  const TextPreviewWindow({
    super.key,
    required this.item,
    this.initialAlwaysOnTop = false,
    this.repository,
    this.onClose,
    this.onToggleAlwaysOnTop,
    this.onSave,
  });

  final TextContentItem item;
  final bool initialAlwaysOnTop;
  final TextPreviewStateRepository? repository;
  final VoidCallback? onClose;
  final ValueChanged<bool>? onToggleAlwaysOnTop;
  final void Function(String id, String text)? onSave;

  @override
  State<TextPreviewWindow> createState() => _TextPreviewWindowState();
}

class _TextPreviewWindowState extends State<TextPreviewWindow>
    with WindowListener {
  final Logger _logger = Logger('TextPreviewWindow');
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late double _fontSize;
  Timer? _autoSaveTimer;
  String _initialText = '';
  bool _isLoading = true;
  bool _hasUnsavedChanges = false;
  late bool _isAlwaysOnTop;
  bool _isClosing = false;
  bool _showUIElements = true;
  Timer? _autoHideTimer;

  // Window bounds saving state
  Timer? _boundsDebounceTimer;
  bool _needsSave = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _fontSize = widget.item.fontSize;
    _controller = TextEditingController();
    _focusNode = FocusNode();
    _isAlwaysOnTop = widget.initialAlwaysOnTop;
    _loadTextContent();
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

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    _autoHideTimer?.cancel();
    _boundsDebounceTimer?.cancel();
    windowManager.removeListener(this);
    if (_isAlwaysOnTop) {
      // Fire-and-forget since window is closing
      unawaited(_applyAlwaysOnTop(false));
    }
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadTextContent() async {
    try {
      final file = File(widget.item.filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        setState(() {
          _initialText = content;
          _controller.text = content;
          _isLoading = false;
        });
      } else {
        setState(() {
          _initialText = '';
          _controller.text = 'ファイルが見つかりません';
          _isLoading = false;
        });
      }
    } catch (error) {
      setState(() {
        _initialText = '';
        _controller.text = 'エラー: $error';
        _isLoading = false;
      });
    }
  }

  void _handleTextChange() {
    // 変更があったかチェック
    if (_controller.text != _initialText) {
      setState(() {
        _hasUnsavedChanges = true;
      });
      _scheduleAutoSave();
    }
  }

  void _scheduleAutoSave() {
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(seconds: 2), () {
      _handleSave();
    });
  }

  void _handleSave() {
    _autoSaveTimer?.cancel();
    if (_hasUnsavedChanges && widget.onSave != null) {
      widget.onSave!(widget.item.id, _controller.text);
      setState(() {
        _initialText = _controller.text;
        _hasUnsavedChanges = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('保存しました'),
            duration: Duration(seconds: 1),
          ),
        );
      }
    }
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
    debugPrint('[TextPreviewWindow] onWindowResized triggered');
    _triggerDebouncedSave();
  }

  @override
  void onWindowMoved() {
    debugPrint('[TextPreviewWindow] onWindowMoved triggered');
    _triggerDebouncedSave();
  }

  @override
  Future<void> onWindowClose() async {
    debugPrint('[TextPreviewWindow] onWindowClose triggered');
    if (_isClosing) return;
    _isClosing = true;

    _boundsDebounceTimer?.cancel(); // Cancel any pending debounced save

    if (_hasUnsavedChanges) {
      _handleSave(); // Save text content
    }

    // Save window bounds only if there are unsaved changes or debounce timer was active
    if (_needsSave || _boundsDebounceTimer != null) {
      debugPrint(
          '[TextPreviewWindow] Saving bounds on close (needsSave: $_needsSave, timerActive: ${_boundsDebounceTimer != null})');
      await _saveBounds(flush: true);
    } else {
      debugPrint(
          '[TextPreviewWindow] Skipping bounds save on close (already saved)');
    }

    widget.onClose?.call();
  }

  Future<void> _handleClose() async {
    // Delegate to onWindowClose for consistent behavior
    await onWindowClose();
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

  void _handleZoomIn() {
    setState(() {
      _fontSize = (_fontSize + 2).clamp(10.0, 72.0);
    });
  }

  void _handleZoomOut() {
    setState(() {
      _fontSize = (_fontSize - 2).clamp(10.0, 72.0);
    });
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
      final isBottomArea = position.dy > size.height * 0.9;

      if (isTopArea || isBottomArea) {
        _showTemporarily();
      }
    }
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
      const SingleActivator(LogicalKeyboardKey.keyS, control: true):
          const _SaveIntent(),
      const SingleActivator(LogicalKeyboardKey.f11):
          const _ToggleUIElementsIntent(),
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
              _SaveIntent: CallbackAction<_SaveIntent>(onInvoke: (_) {
                _handleSave();
                return null;
              }),
              _ToggleUIElementsIntent:
                  CallbackAction<_ToggleUIElementsIntent>(onInvoke: (_) {
                _toggleUIElements();
                return null;
              }),
            },
            child: Focus(
              autofocus: true,
              child: Scaffold(
                backgroundColor: const Color(0xFF72CC82),
                appBar: _buildAppBar(context),
                body: Stack(
                  children: [
                    _buildTextEditor(),
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
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
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
            backgroundColor: const Color(0xFF5BA570),
            elevation: 2,
            title: Row(
              children: [
                Expanded(
                  child: Text(title, overflow: TextOverflow.ellipsis),
                ),
                if (_hasUnsavedChanges)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Chip(
                      label: Text(
                        '未保存',
                        style: TextStyle(fontSize: 11),
                      ),
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
              ],
            ),
            actions: [
              IconButton(
                tooltip: 'フォントサイズを小さく',
                onPressed: _handleZoomOut,
                icon: const Icon(Icons.zoom_out),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(
                  child: Text(
                    '${_fontSize.toInt()}',
                    style: const TextStyle(
                        fontSize: 14, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'フォントサイズを大きく',
                onPressed: _handleZoomIn,
                icon: const Icon(Icons.zoom_in),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '保存 (Ctrl+S)',
                onPressed: _hasUnsavedChanges ? _handleSave : null,
                icon: const Icon(Icons.save),
              ),
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

  Widget _buildTextEditor() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              onChanged: (_) => _handleTextChange(),
              decoration: InputDecoration(
                border: const OutlineInputBorder(),
                hintText: 'テキストを入力してください...',
                filled: true,
                fillColor: const Color(0xFF72CC82),
                hintStyle: TextStyle(
                  color: Colors.black.withOpacity(0.5),
                ),
              ),
              style: TextStyle(
                color: Colors.black,
                fontSize: _fontSize,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
        _buildFooter(),
      ],
    );
  }

  Widget _buildFooter() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      height: _showUIElements ? 48 : 0,
      child: AnimatedOpacity(
        opacity: _showUIElements ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: const BoxDecoration(
            color: Color(0xFF72CC82),
            border: Border(
              top: BorderSide(color: Color(0xFF5BA570)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 16,
                color: Colors.white.withOpacity(0.8),
              ),
              const SizedBox(width: 8),
              const Text(
                '変更は2秒後に自動保存されます',
                style: TextStyle(fontSize: 12, color: Colors.white),
              ),
              const Spacer(),
              Text(
                '${_controller.text.length} 文字',
                style: const TextStyle(fontSize: 12, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CloseIntent extends Intent {
  const _CloseIntent();
}

class _ToggleAlwaysOnTopIntent extends Intent {
  const _ToggleAlwaysOnTopIntent();
}

class _SaveIntent extends Intent {
  const _SaveIntent();
}

class _ToggleUIElementsIntent extends Intent {
  const _ToggleUIElementsIntent();
}
