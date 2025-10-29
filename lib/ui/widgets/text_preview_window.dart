import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../data/models/text_content_item.dart';

/// テキストコンテンツを別ウィンドウで表示・編集するダイアログ
class TextPreviewWindow extends StatefulWidget {
  const TextPreviewWindow({
    super.key,
    required this.item,
    required this.onSave,
  });

  final TextContentItem item;
  final void Function(String id, String text) onSave;

  @override
  State<TextPreviewWindow> createState() => _TextPreviewWindowState();
}

class _TextPreviewWindowState extends State<TextPreviewWindow> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  late double _fontSize;
  Timer? _autoSaveTimer;
  String _initialText = '';
  bool _isLoading = true;
  bool _hasUnsavedChanges = false;

  @override
  void initState() {
    super.initState();
    _fontSize = widget.item.fontSize;
    _controller = TextEditingController();
    _focusNode = FocusNode();
    _loadTextContent();
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
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
    if (_hasUnsavedChanges) {
      widget.onSave(widget.item.id, _controller.text);
      setState(() {
        _initialText = _controller.text;
        _hasUnsavedChanges = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('保存しました'),
          duration: Duration(seconds: 1),
        ),
      );
    }
  }

  void _handleClose() {
    if (_hasUnsavedChanges) {
      // 未保存の変更がある場合は保存してから閉じる
      _handleSave();
    }
    Navigator.of(context).pop();
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
    return Dialog(
      child: Container(
        width: 800,
        height: 600,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            // ヘッダー
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.blue.shade200),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.text_fields, size: 20, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.item.filePath.split('/').last,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_hasUnsavedChanges)
                    const Padding(
                      padding: EdgeInsets.only(right: 8),
                      child: Text(
                        '未保存',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.orange,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  // フォントサイズ調整
                  IconButton(
                    icon: const Icon(Icons.zoom_out, size: 20),
                    onPressed: _handleZoomOut,
                    tooltip: 'フォントサイズを小さく',
                  ),
                  Text(
                    '${_fontSize.toInt()}',
                    style: const TextStyle(fontSize: 14),
                  ),
                  IconButton(
                    icon: const Icon(Icons.zoom_in, size: 20),
                    onPressed: _handleZoomIn,
                    tooltip: 'フォントサイズを大きく',
                  ),
                  const SizedBox(width: 8),
                  // 保存ボタン
                  ElevatedButton.icon(
                    onPressed: _hasUnsavedChanges ? _handleSave : null,
                    icon: const Icon(Icons.save, size: 18),
                    label: const Text('保存'),
                  ),
                  const SizedBox(width: 8),
                  // 閉じるボタン
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    onPressed: _handleClose,
                    tooltip: '閉じる',
                  ),
                ],
              ),
            ),
            // テキストエディタ
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        maxLines: null,
                        expands: true,
                        onChanged: (_) => _handleTextChange(),
                        decoration: const InputDecoration(
                          border: OutlineInputBorder(),
                          hintText: 'テキストを入力してください...',
                        ),
                        style: TextStyle(
                          fontSize: _fontSize,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
            ),
            // フッター
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                border: Border(
                  top: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.grey),
                  const SizedBox(width: 8),
                  const Text(
                    '変更は2秒後に自動保存されます',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const Spacer(),
                  Text(
                    '${_controller.text.length} 文字',
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
