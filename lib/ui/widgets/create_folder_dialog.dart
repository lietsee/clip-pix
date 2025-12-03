import 'package:flutter/material.dart';

/// 新規フォルダを作成するダイアログ
class CreateFolderDialog extends StatefulWidget {
  const CreateFolderDialog({
    super.key,
    required this.existingNames,
  });

  /// 既存のフォルダ名（重複チェック用）
  final Set<String> existingNames;

  @override
  State<CreateFolderDialog> createState() => _CreateFolderDialogState();
}

class _CreateFolderDialogState extends State<CreateFolderDialog> {
  late final TextEditingController _controller;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final name = _controller.text.trim();
    setState(() {
      if (name.isEmpty) {
        _errorMessage = null;
      } else if (widget.existingNames.contains(name)) {
        _errorMessage = '同じ名前のフォルダが既に存在します';
      } else if (name.contains('/') || name.contains('\\')) {
        _errorMessage = 'フォルダ名に / や \\ は使用できません';
      } else {
        _errorMessage = null;
      }
    });
  }

  bool get _canCreate {
    final name = _controller.text.trim();
    return name.isNotEmpty && _errorMessage == null;
  }

  void _handleCreate() {
    if (_canCreate) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }

  void _handleCancel() {
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('新規フォルダ作成'),
      content: SizedBox(
        width: 300,
        child: TextField(
          controller: _controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'フォルダ名',
            hintText: 'フォルダ名を入力',
            border: const OutlineInputBorder(),
            errorText: _errorMessage,
          ),
          onSubmitted: (_) {
            if (_canCreate) {
              _handleCreate();
            }
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: _handleCancel,
          child: const Text('キャンセル'),
        ),
        ElevatedButton(
          onPressed: _canCreate ? _handleCreate : null,
          child: const Text('OK'),
        ),
      ],
    );
  }
}
