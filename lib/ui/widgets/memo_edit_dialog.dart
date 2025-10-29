import 'package:flutter/material.dart';

/// 画像のメモを編集するダイアログ
class MemoEditDialog extends StatefulWidget {
  const MemoEditDialog({
    super.key,
    required this.initialMemo,
    required this.fileName,
  });

  final String initialMemo;
  final String fileName;

  @override
  State<MemoEditDialog> createState() => _MemoEditDialogState();
}

class _MemoEditDialogState extends State<MemoEditDialog> {
  late final TextEditingController _controller;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialMemo);
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasChanges = _controller.text != widget.initialMemo;
    if (hasChanges != _hasChanges) {
      setState(() {
        _hasChanges = hasChanges;
      });
    }
  }

  void _handleSave() {
    Navigator.of(context).pop(_controller.text);
  }

  void _handleCancel() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('メモを編集'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.fileName,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.grey[600],
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              maxLines: 5,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'メモ',
                hintText: '画像に関するメモを入力してください',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _handleCancel,
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: _hasChanges ? _handleSave : null,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
