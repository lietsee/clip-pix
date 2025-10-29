import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// カード上でテキストを直接編集するインラインエディタ
class TextInlineEditor extends StatefulWidget {
  const TextInlineEditor({
    super.key,
    required this.initialText,
    required this.onSave,
    required this.onCancel,
  });

  final String initialText;
  final void Function(String text) onSave;
  final VoidCallback onCancel;

  @override
  State<TextInlineEditor> createState() => _TextInlineEditorState();
}

class _TextInlineEditorState extends State<TextInlineEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _focusNode = FocusNode();
    // フォーカスを自動的に設定
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Colors.blue, width: 2),
        borderRadius: BorderRadius.circular(4),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // ヘッダー
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              border: Border(
                bottom: BorderSide(color: Colors.blue.shade200),
              ),
            ),
            child: Row(
              children: [
                const Icon(Icons.edit, size: 16, color: Colors.blue),
                const SizedBox(width: 8),
                const Text(
                  'テキスト編集 (Ctrl+Enter: 保存, ESC: キャンセル)',
                  style: TextStyle(fontSize: 12, color: Colors.black87),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  onPressed: widget.onCancel,
                  tooltip: 'キャンセル (ESC)',
                ),
              ],
            ),
          ),
          // テキストフィールド
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: KeyboardListener(
                focusNode: FocusNode(),
                onKeyEvent: _handleKeyEvent,
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: null,
                  expands: true,
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    hintText: 'テキストを入力してください...',
                  ),
                  style: const TextStyle(fontSize: 14),
                ),
              ),
            ),
          ),
          // フッター
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey.shade50,
              border: Border(
                top: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: widget.onCancel,
                  child: const Text('キャンセル'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _handleSave,
                  child: const Text('保存'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    // Ctrl+Enter で保存
    if (event.logicalKey == LogicalKeyboardKey.enter &&
        HardwareKeyboard.instance.isControlPressed) {
      _handleSave();
      return;
    }

    // ESC でキャンセル
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      widget.onCancel();
      return;
    }
  }

  void _handleSave() {
    widget.onSave(_controller.text);
  }
}
