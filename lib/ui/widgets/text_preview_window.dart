import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/models/text_content_item.dart';
import '../../data/text_preview_state_repository.dart';

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

class _TextPreviewWindowState extends State<TextPreviewWindow> {
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

  @override
  void initState() {
    super.initState();
    _fontSize = widget.item.fontSize;
    _controller = TextEditingController();
    _focusNode = FocusNode();
    _isAlwaysOnTop = widget.initialAlwaysOnTop;
    _loadTextContent();
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
    _autoSaveTimer?.cancel();
    _autoHideTimer?.cancel();
    if (_isAlwaysOnTop) {
      _applyAlwaysOnTop(false);
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

  Future<void> _handleClose() async {
    if (_isClosing) return;
    _isClosing = true;
    if (_hasUnsavedChanges) {
      _handleSave();
    }

    // Save window bounds and always-on-top state before closing
    if (widget.repository != null) {
      try {
        final bounds = await windowManager.getBounds();
        await widget.repository!.save(
          widget.item.id,
          bounds,
          alwaysOnTop: _isAlwaysOnTop,
        );

        // Flush Hive to disk before exit to ensure writes complete
        await Hive.close();

        _logger.fine(
            'Saved and flushed window bounds and state: $bounds, alwaysOnTop: $_isAlwaysOnTop');
      } catch (e, stackTrace) {
        _logger.warning('Failed to save window bounds', e, stackTrace);
      }
    }

    widget.onClose?.call();
  }

  void _toggleAlwaysOnTop() {
    final newValue = !_isAlwaysOnTop;
    if (_applyAlwaysOnTop(newValue)) {
      setState(() {
        _isAlwaysOnTop = newValue;
      });
      widget.onToggleAlwaysOnTop?.call(newValue);
    }
  }

  bool _applyAlwaysOnTop(bool enable) {
    if (!Platform.isWindows) {
      _logger.warning('Always on top is only supported on Windows');
      return false;
    }
    try {
      final hwnd = GetActiveWindow();
      if (hwnd == 0) {
        _logger.warning('Failed to get window handle');
        return false;
      }
      final flag = enable ? HWND_TOPMOST : HWND_NOTOPMOST;
      final result = SetWindowPos(
        hwnd,
        flag,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
      );
      if (result == 0) {
        _logger.warning('SetWindowPos failed');
        return false;
      }
      _logger.info('Always on top: $enable');
      return true;
    } catch (error, stackTrace) {
      _logger.warning('Failed to apply always on top', error, stackTrace);
      return false;
    }
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
