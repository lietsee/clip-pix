import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';
import 'package:window_manager/window_manager.dart';

import '../../data/models/text_content_item.dart';

/// テキストコンテンツを別ウィンドウで表示・編集する
class TextPreviewWindow extends StatefulWidget {
  const TextPreviewWindow({
    super.key,
    required this.item,
    this.initialAlwaysOnTop = false,
    this.onClose,
    this.onToggleAlwaysOnTop,
    this.onSave,
  });

  final TextContentItem item;
  final bool initialAlwaysOnTop;
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

  void _handleClose() {
    if (_isClosing) return;
    _isClosing = true;
    if (_hasUnsavedChanges) {
      _handleSave();
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
    };

    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
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
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: const Color(0xFF72CC82),
              appBar: _buildAppBar(context),
              body: Positioned.fill(
                child: _buildTextEditor(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    final title = p.basename(widget.item.filePath);
    return PreferredSize(
      preferredSize: const Size.fromHeight(kToolbarHeight),
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
        Container(
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
      ],
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
