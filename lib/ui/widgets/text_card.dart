import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/text_content_item.dart';
import '../../system/state/grid_layout_store.dart';
import 'memo_edit_dialog.dart';
import 'resize_preview_overlay.dart';
import 'text_inline_editor.dart';

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
    required this.onSaveText,
    required this.columnWidth,
    required this.columnCount,
    required this.columnGap,
    required this.backgroundColor,
    this.onSpanChange,
    this.onReorderPointerDown,
    this.onStartReorder,
    this.onReorderUpdate,
    this.onReorderEnd,
    this.onReorderCancel,
  });

  final TextContentItem item;
  final GridCardViewState viewState;
  final void Function(String id, Size newSize) onResize;
  final void Function(String id, int span)? onSpanChange;
  final void Function(String id, String memo) onEditMemo;
  final void Function(String id, int favorite) onFavoriteToggle;
  final void Function(TextContentItem item) onCopyText;
  final Future<void> Function(TextContentItem item) onOpenPreview;
  final void Function(String id, String text) onSaveText;
  final double columnWidth;
  final int columnCount;
  final double columnGap;
  final Color backgroundColor;
  final void Function(String id, int pointer)? onReorderPointerDown;
  final void Function(String id, Offset globalPosition)? onStartReorder;
  final void Function(String id, Offset globalPosition)? onReorderUpdate;
  final void Function(String id)? onReorderEnd;
  final void Function(String id)? onReorderCancel;

  @override
  State<TextCard> createState() => _TextCardState();
}

class _TextCardState extends State<TextCard> {
  bool _showControls = false;
  bool _isResizing = false;
  bool _isEditing = false;
  bool _isOpeningPreview = false;
  Size? _resizeStartSize;
  Offset? _resizeStartGlobalPosition;
  int _currentSpan = 1;
  int? _resizeStartSpan;
  Size? _previewSize;
  ResizePreviewOverlayService? _overlayService;
  String _textContent = '';
  bool _isLoading = true;
  late ValueNotifier<Size> _sizeNotifier;

  @override
  void initState() {
    super.initState();
    _currentSpan = widget.viewState.columnSpan;
    _sizeNotifier = ValueNotifier(
      Size(widget.viewState.width, widget.viewState.height),
    );
    _loadTextContent();
  }

  @override
  void didUpdateWidget(covariant TextCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.item.filePath != widget.item.filePath) {
      _loadTextContent();
    }

    // リサイズ中は外部からのサイズ同期をスキップ
    if (!_isResizing) {
      final newSize = Size(widget.viewState.width, widget.viewState.height);
      if (_sizeNotifier.value != newSize) {
        _sizeNotifier.value = newSize;
      }
    }

    if (oldWidget.columnWidth != widget.columnWidth ||
        oldWidget.columnGap != widget.columnGap ||
        oldWidget.columnCount != widget.columnCount) {
      _currentSpan = widget.viewState.columnSpan;
    }
    if (oldWidget.viewState.columnSpan != widget.viewState.columnSpan) {
      _currentSpan = widget.viewState.columnSpan;
    }
  }

  @override
  void dispose() {
    _overlayService?.dispose();
    _overlayService = null;
    _sizeNotifier.dispose();
    super.dispose();
  }

  Future<void> _loadTextContent() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final file = File(widget.item.filePath);
      if (await file.exists()) {
        final content = await file.readAsString();
        if (!mounted) return;
        setState(() {
          _textContent = content;
          _isLoading = false;
        });
      } else {
        if (!mounted) return;
        setState(() {
          _textContent = 'ファイルが見つかりません';
          _isLoading = false;
        });
      }
    } catch (error) {
      if (!mounted) return;
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
        onTap: _isEditing ? null : _handleSingleTap,
        onDoubleTap: _isEditing ? null : _handleDoubleTap,
        child: ValueListenableBuilder<Size>(
          valueListenable: _sizeNotifier,
          builder: (context, size, child) {
            return Container(
              width: size.width,
              height: size.height,
              decoration: BoxDecoration(
                color: widget.backgroundColor,
                border: Border.all(color: Colors.grey.shade300, width: 1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Stack(
                children: [
                  // テキストコンテンツ
                  if (!_isEditing)
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
                  // インラインエディタ
                  if (_isEditing)
                    Positioned.fill(
                      child: TextInlineEditor(
                        initialText: _textContent,
                        onSave: _handleSaveText,
                        onCancel: _handleCancelEdit,
                      ),
                    ),
                  // ホバーコントロール
                  if (_showControls && !_isResizing && !_isEditing)
                    _buildHoverControls(),
                  // リサイズハンドル
                  if (_showControls || _isResizing) _buildResizeHandle(),
                ],
              ),
            );
          },
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
        // 並べ替えアイコン（下部中央）
        Positioned(
          left: 0,
          right: 0,
          bottom: 8,
          child: Center(
            child: Listener(
              onPointerDown: (event) {
                widget.onReorderPointerDown
                    ?.call(widget.item.id, event.pointer);
              },
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onPanStart: (details) {
                  widget.onStartReorder?.call(
                    widget.item.id,
                    details.globalPosition,
                  );
                },
                onPanUpdate: (details) {
                  widget.onReorderUpdate?.call(
                    widget.item.id,
                    details.globalPosition,
                  );
                },
                onPanEnd: (_) {
                  widget.onReorderEnd?.call(widget.item.id);
                },
                onPanCancel: () {
                  widget.onReorderCancel?.call(widget.item.id);
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0x33000000),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.drag_indicator,
                    size: 18,
                    color: Colors.white,
                  ),
                ),
              ),
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
    setState(() {
      _isEditing = true;
    });
  }

  void _handleDoubleTap() async {
    if (_isOpeningPreview) return;
    _isOpeningPreview = true;
    try {
      await widget.onOpenPreview(widget.item);
    } finally {
      _isOpeningPreview = false;
    }
  }

  void _handleSaveText(String text) async {
    widget.onSaveText(widget.item.id, text);
    setState(() {
      _textContent = text;
      _isEditing = false;
    });
  }

  void _handleCancelEdit() {
    setState(() {
      _isEditing = false;
    });
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
    // Get card's global position
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final globalOffset = box.localToGlobal(Offset.zero);
    final currentSize = Size(widget.viewState.width, widget.viewState.height);

    setState(() {
      _isResizing = true;
      _resizeStartSize = currentSize;
      _resizeStartGlobalPosition = details.globalPosition;
      _resizeStartSpan = _currentSpan;
    });

    // Create and show overlay
    _overlayService = ResizePreviewOverlayService();
    _overlayService!.show(
      context: context,
      globalRect: Rect.fromLTWH(
        globalOffset.dx,
        globalOffset.dy,
        currentSize.width,
        currentSize.height,
      ),
      columnSpan: _currentSpan,
    );
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    if (_resizeStartSize == null || _resizeStartGlobalPosition == null) {
      return;
    }

    final delta = details.globalPosition - _resizeStartGlobalPosition!;
    final targetWidth =
        (_resizeStartSize!.width + delta.dx).clamp(100.0, 1920.0);
    final snappedSpan = _snapSpan(targetWidth);
    final snappedWidth = _widthForSpan(snappedSpan);
    final newHeight =
        (_resizeStartSize!.height + delta.dy).clamp(100.0, 1080.0);

    // Get card's current global position (might have scrolled)
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final globalOffset = box.localToGlobal(Offset.zero);

    // Update overlay
    _overlayService?.update(
      globalRect: Rect.fromLTWH(
        globalOffset.dx,
        globalOffset.dy,
        snappedWidth,
        newHeight,
      ),
      columnSpan: snappedSpan,
    );

    // Update local state for span tracking
    final newSize = Size(snappedWidth, newHeight);
    if (snappedSpan != _currentSpan || _previewSize != newSize) {
      setState(() {
        _currentSpan = snappedSpan;
        _previewSize = newSize;
      });
    }
  }

  void _handleResizeEnd(DragEndDetails details) {
    // Hide overlay
    _overlayService?.hide();
    _overlayService?.dispose();
    _overlayService = null;

    // プレビューサイズを最終サイズとして適用
    final finalSize = _previewSize ?? _sizeNotifier.value;
    _sizeNotifier.value = finalSize;

    setState(() {
      _isResizing = false;
      _resizeStartSize = null;
      _resizeStartGlobalPosition = null;
      _previewSize = null;
    });

    // ドラッグ終了時にGridLayoutStoreに永続化
    widget.onResize(widget.item.id, finalSize);

    if (_resizeStartSpan != null && _currentSpan != _resizeStartSpan) {
      widget.onSpanChange?.call(widget.item.id, _currentSpan);
    }
    _resizeStartSpan = null;
  }

  int _snapSpan(double targetWidth) {
    if (widget.columnCount <= 1) {
      return 1;
    }
    int bestSpan = 1;
    double bestDiff = double.infinity;
    for (int span = 1; span <= widget.columnCount; span++) {
      final width = _widthForSpan(span);
      final diff = (width - targetWidth).abs();
      if (diff < bestDiff - 0.1) {
        bestDiff = diff;
        bestSpan = span;
      }
    }
    return bestSpan.clamp(1, widget.columnCount);
  }

  double _widthForSpan(int span) {
    final clamped = span.clamp(1, widget.columnCount);
    return widget.columnWidth * clamped +
        widget.columnGap * (clamped - 1).clamp(0, double.infinity);
  }
}
