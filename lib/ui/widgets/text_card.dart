import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/text_content_item.dart';
import '../../system/state/grid_layout_store.dart';
import 'memo_edit_dialog.dart';

/// テキストコンテンツを表示するカード
class TextCard extends StatefulWidget {
  const TextCard({
    super.key,
    required this.item,
    required this.viewState,
    required this.onResize,
    required this.onEditMemo,
    required this.onFavoriteToggle,
    required this.onCopyText,
    required this.onOpenPreview,
    required this.columnWidth,
    required this.columnCount,
    required this.columnGap,
    required this.backgroundColor,
  });

  final TextContentItem item;
  final GridCardViewState viewState;
  final void Function(String id, Size newSize) onResize;
  final void Function(String id, String memo) onEditMemo;
  final void Function(String id, int favorite) onFavoriteToggle;
  final void Function(TextContentItem item) onCopyText;
  final void Function(TextContentItem item) onOpenPreview;
  final double columnWidth;
  final int columnCount;
  final double columnGap;
  final Color backgroundColor;

  @override
  State<TextCard> createState() => _TextCardState();
}

class _TextCardState extends State<TextCard> {
  bool _showControls = false;
  bool _isResizing = false;
  Size? _resizeStartSize;
  Offset? _resizeStartGlobalPosition;
  String _textContent = '';
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTextContent();
  }

  @override
  void didUpdateWidget(covariant TextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.filePath != widget.item.filePath) {
      _loadTextContent();
    }
  }

  Future<void> _loadTextContent() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final file = File(widget.item.filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        setState(() {
          _textContent = content;
          _isLoading = false;
        });
      } else {
        setState(() {
          _textContent = 'ファイルが見つかりません';
          _isLoading = false;
        });
      }
    } catch (error) {
      setState(() {
        _textContent = 'エラー: $error';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _showControls = true),
      onExit: (_) => setState(() => _showControls = false),
      child: GestureDetector(
        onTap: _handleSingleTap,
        onDoubleTap: _handleDoubleTap,
        child: Container(
          width: widget.viewState.width,
          height: widget.viewState.height,
          decoration: BoxDecoration(
            color: widget.backgroundColor,
            border: Border.all(color: Colors.grey.shade300, width: 1),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Stack(
            children: [
              // テキストコンテンツ
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.all(12.0),
                  child: _isLoading
                      ? const Center(child: CircularProgressIndicator())
                      : SingleChildScrollView(
                          child: Text(
                            _textContent,
                            style: TextStyle(
                              fontSize: widget.item.fontSize,
                              color: Colors.black87,
                            ),
                          ),
                        ),
                ),
              ),
              // ホバーコントロール
              if (_showControls && !_isResizing) _buildHoverControls(),
              // リサイズハンドル
              if (_showControls || _isResizing) _buildResizeHandle(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHoverControls() {
    return Stack(
      children: [
        // メモボタン（左上）
        Positioned(
          top: 8,
          left: 8,
          child: ElevatedButton(
            onPressed: _handleEditMemo,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white.withOpacity(0.9),
            ),
            child: Icon(
              widget.item.memo.isEmpty ? Icons.note_add : Icons.edit_note,
              size: 20,
              color: Colors.blue.shade700,
            ),
          ),
        ),
        // コピーボタン（右上）
        Positioned(
          top: 8,
          right: 8,
          child: ElevatedButton(
            onPressed: () => widget.onCopyText(widget.item),
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              backgroundColor: Colors.white.withOpacity(0.9),
            ),
            child: Icon(
              Icons.copy,
              size: 20,
              color: Colors.blue.shade700,
            ),
          ),
        ),
        // お気に入りボタン（左下）
        Positioned(
          bottom: 8,
          left: 8,
          child: ElevatedButton(
            onPressed: _handleFavoriteToggle,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size(36, 36),
              padding: EdgeInsets.zero,
              backgroundColor: _backgroundColorForFavorite(widget.item.favorite)
                      ?.withOpacity(0.9) ??
                  Colors.white.withOpacity(0.9),
            ),
            child: Icon(
              widget.item.favorite > 0 ? Icons.favorite : Icons.favorite_border,
              size: 20,
              color: widget.item.favorite > 0 ? Colors.white : Colors.grey,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildResizeHandle() {
    return Positioned(
      bottom: 0,
      right: 0,
      child: GestureDetector(
        onPanStart: _handleResizeStart,
        onPanUpdate: _handleResizeUpdate,
        onPanEnd: _handleResizeEnd,
        child: MouseRegion(
          cursor: SystemMouseCursors.resizeDownRight,
          child: Container(
            width: 24,
            height: 24,
            color: Colors.transparent,
            child: const Icon(
              Icons.drag_handle,
              size: 16,
              color: Colors.grey,
            ),
          ),
        ),
      ),
    );
  }

  void _handleSingleTap() {
    // TODO: TextInlineEditorを開く（Phase 3で実装）
    debugPrint('TextCard: single tap on ${widget.item.id}');
  }

  void _handleDoubleTap() {
    // TODO: TextPreviewWindowを開く（Phase 3で実装）
    widget.onOpenPreview(widget.item);
  }

  Future<void> _handleEditMemo() async {
    final result = await showDialog<String>(
      context: context,
      builder: (context) => MemoEditDialog(
        initialMemo: widget.item.memo,
        fileName: widget.item.filePath.split('/').last,
      ),
    );
    if (result != null) {
      widget.onEditMemo(widget.item.id, result);
    }
  }

  void _handleFavoriteToggle() {
    final next = (widget.item.favorite + 1) % 4;
    widget.onFavoriteToggle(widget.item.id, next);
  }

  Color? _backgroundColorForFavorite(int level) {
    switch (level) {
      case 1:
        return Colors.green;
      case 2:
        return Colors.orange;
      case 3:
        return Colors.pink;
      default:
        return null;
    }
  }

  void _handleResizeStart(DragStartDetails details) {
    setState(() {
      _isResizing = true;
      _resizeStartSize = Size(widget.viewState.width, widget.viewState.height);
      _resizeStartGlobalPosition = details.globalPosition;
    });
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    if (_resizeStartSize == null || _resizeStartGlobalPosition == null) {
      return;
    }

    final delta = details.globalPosition - _resizeStartGlobalPosition!;
    final newWidth = (_resizeStartSize!.width + delta.dx).clamp(100.0, 1920.0);
    final newHeight =
        (_resizeStartSize!.height + delta.dy).clamp(100.0, 1080.0);

    widget.onResize(widget.item.id, Size(newWidth, newHeight));
  }

  void _handleResizeEnd(DragEndDetails details) {
    setState(() {
      _isResizing = false;
      _resizeStartSize = null;
      _resizeStartGlobalPosition = null;
    });
  }
}
