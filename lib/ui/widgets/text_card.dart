import 'dart:io';

import 'package:flutter/material.dart';

import '../../data/models/text_content_item.dart';
import '../../system/state/grid_layout_store.dart';
import '../image_card.dart' show ResizeCorner;
import 'resize_preview_overlay.dart';
import 'text_inline_editor.dart';

/// テキストコンテンツを表示するカード
class TextCard extends StatefulWidget {
  const TextCard({
    super.key,
    required this.item,
    required this.viewState,
    required this.onResize,
    required this.onFavoriteToggle,
    required this.onCopyText,
    required this.onOpenPreview,
    required this.onSaveText,
    required this.columnWidth,
    required this.columnCount,
    required this.columnGap,
    required this.backgroundColor,
    this.isDeletionMode = false,
    this.isSelected = false,
    this.isHighlighted = false,
    this.onDelete,
    this.onSelectionToggle,
    this.onSpanChange,
    this.onReorderPointerDown,
    this.onStartReorder,
    this.onReorderUpdate,
    this.onReorderEnd,
    this.onReorderCancel,
    this.onHoverChanged,
    this.debugIndex,
  });

  final TextContentItem item;
  final GridCardViewState viewState;
  final void Function(String id, Size newSize, {ResizeCorner? corner}) onResize;
  final void Function(String id, int span)? onSpanChange;
  final void Function(String id, int favorite) onFavoriteToggle;
  final void Function(TextContentItem item) onCopyText;
  final Future<void> Function(TextContentItem item) onOpenPreview;
  final void Function(String id, String text) onSaveText;
  final double columnWidth;
  final int columnCount;
  final double columnGap;
  final Color backgroundColor;
  final bool isDeletionMode;
  final bool isSelected;
  final bool isHighlighted;
  final void Function(TextContentItem item)? onDelete;
  final void Function(String id)? onSelectionToggle;
  final void Function(String id, int pointer)? onReorderPointerDown;
  final void Function(String id, Offset globalPosition)? onStartReorder;
  final void Function(String id, Offset globalPosition)? onReorderUpdate;
  final void Function(String id)? onReorderEnd;
  final void Function(String id)? onReorderCancel;
  final void Function(bool isHovered)? onHoverChanged;

  /// デバッグ用: カードの配列インデックス（debugShowCardIndex=trueの時に中央に表示）
  final int? debugIndex;

  @override
  State<TextCard> createState() => _TextCardState();
}

class _TextCardState extends State<TextCard>
    with SingleTickerProviderStateMixin {
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
  ResizeCorner? _resizeCorner;
  Offset? _anchorPosition;
  String _textContent = '';
  bool _isLoading = true;
  late ValueNotifier<Size> _sizeNotifier;
  late AnimationController _highlightController;
  late Animation<double> _highlightAnimation;

  @override
  void initState() {
    super.initState();
    _currentSpan = widget.viewState.columnSpan;
    _sizeNotifier = ValueNotifier(
      Size(widget.viewState.width, widget.viewState.height),
    );
    _loadTextContent();

    // パルスアニメーション用コントローラー（2秒間で3回パルス）
    _highlightController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 667),
    );
    _highlightAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _highlightController, curve: Curves.easeInOut),
    );
    if (widget.isHighlighted) {
      _highlightController.repeat(reverse: true);
    }
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
    // ハイライト状態の変更を検知してアニメーション制御
    if (oldWidget.isHighlighted != widget.isHighlighted) {
      debugPrint('[TextCard] highlight_changed: ${widget.item.id.split('/').last}, '
          'old=${oldWidget.isHighlighted}, new=${widget.isHighlighted}');
      if (widget.isHighlighted) {
        _highlightController.repeat(reverse: true);
      } else {
        _highlightController.stop();
        _highlightController.reset();
      }
    }
  }

  @override
  void dispose() {
    _overlayService?.dispose();
    _overlayService = null;
    _sizeNotifier.dispose();
    _highlightController.dispose();
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
      onEnter: (_) {
        setState(() => _showControls = true);
        widget.onHoverChanged?.call(true);
      },
      onExit: (_) {
        setState(() => _showControls = false);
        widget.onHoverChanged?.call(false);
      },
      child: GestureDetector(
        onTap: null, // 編集はホバーボタンからのみ
        onDoubleTap: (_isEditing || widget.isDeletionMode) ? null : _handleDoubleTap,
        child: ValueListenableBuilder<Size>(
          valueListenable: _sizeNotifier,
          builder: (context, size, child) {
            return AnimatedBuilder(
              animation: _highlightAnimation,
              builder: (context, cardChild) {
                final borderOpacity = widget.isHighlighted
                    ? _highlightAnimation.value
                    : 0.0;
                return Container(
                  width: size.width,
                  height: size.height,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.blue.withOpacity(borderOpacity),
                      width: 3,
                    ),
                  ),
                  child: cardChild,
                );
              },
              child: Container(
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
                  // 削除モード時のチェックボックス（左上、常時表示）
                  if (widget.isDeletionMode && !_isEditing)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _buildSelectionCheckbox(),
                    ),
                  // お気に入りボタン（左下）
                  // 一括削除モード時: favorite > 0 の場合のみ常時表示、通常時: ホバー時のみ表示
                  if (widget.isDeletionMode && widget.item.favorite > 0)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: ElevatedButton(
                        onPressed: _handleFavoriteToggle,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(36, 36),
                          padding: EdgeInsets.zero,
                          backgroundColor:
                              _backgroundColorForFavorite(widget.item.favorite)
                                      ?.withOpacity(0.9) ??
                                  Colors.white.withOpacity(0.9),
                        ),
                        child: Icon(
                          Icons.favorite,
                          size: 20,
                          color: Colors.white,
                        ),
                      ),
                    )
                  else if (!widget.isDeletionMode &&
                      _showControls &&
                      !_isResizing &&
                      !_isEditing)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      child: ElevatedButton(
                        onPressed: _handleFavoriteToggle,
                        style: ElevatedButton.styleFrom(
                          minimumSize: const Size(36, 36),
                          padding: EdgeInsets.zero,
                          backgroundColor:
                              _backgroundColorForFavorite(widget.item.favorite)
                                      ?.withOpacity(0.9) ??
                                  Colors.white.withOpacity(0.9),
                        ),
                        child: Icon(
                          widget.item.favorite > 0
                              ? Icons.favorite
                              : Icons.favorite_border,
                          size: 20,
                          color: widget.item.favorite > 0
                              ? Colors.white
                              : Colors.grey,
                        ),
                      ),
                    ),
                  // リサイズハンドル（4コーナー）
                  if (_showControls || _isResizing) ...[
                    Positioned(
                      top: 0,
                      left: 0,
                      child: _buildResizeHandle(ResizeCorner.topLeft),
                    ),
                    Positioned(
                      top: 0,
                      right: 0,
                      child: _buildResizeHandle(ResizeCorner.topRight),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      child: _buildResizeHandle(ResizeCorner.bottomLeft),
                    ),
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: _buildResizeHandle(ResizeCorner.bottomRight),
                    ),
                  ],
                ],
              ),
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
        // テキスト編集ボタン（左上）- 一括削除モード時は非表示
        if (!widget.isDeletionMode)
          Positioned(
            top: 8,
            left: 8,
            child: ElevatedButton(
              onPressed: _handleSingleTap,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(36, 36),
                padding: EdgeInsets.zero,
                backgroundColor: Colors.white.withOpacity(0.9),
              ),
              child: Icon(
                Icons.edit,
                size: 20,
                color: Colors.blue.shade700,
              ),
            ),
          ),
        // 削除ボタン（右上）- 削除モード時は常時表示のチェックボックスが代わりに表示される
        if (!widget.isDeletionMode)
          Positioned(
            top: 8,
            right: 8,
            child: _buildDeleteButton(),
          ),
        // 並べ替えアイコン（下部中央）- 一括削除モード時は非表示
        if (!widget.isDeletionMode)
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
        // デバッグ用: カード順序番号表示
        if (widget.debugIndex != null) _buildDebugIndexOverlay(),
      ],
    );
  }

  /// デバッグ用: カード中央に配列インデックスを表示
  Widget _buildDebugIndexOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black54,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${widget.debugIndex}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildResizeHandle(ResizeCorner corner) {
    final MouseCursor cursor;
    switch (corner) {
      case ResizeCorner.topLeft:
        cursor = SystemMouseCursors.resizeUpLeft;
      case ResizeCorner.topRight:
        cursor = SystemMouseCursors.resizeUpRight;
      case ResizeCorner.bottomLeft:
        cursor = SystemMouseCursors.resizeDownLeft;
      case ResizeCorner.bottomRight:
        cursor = SystemMouseCursors.resizeDownRight;
    }

    return GestureDetector(
      onPanStart: (details) => _handleResizeStart(details, corner),
      onPanUpdate: _handleResizeUpdate,
      onPanEnd: _handleResizeEnd,
      child: MouseRegion(
        cursor: cursor,
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

  void _handleResizeStart(DragStartDetails details, ResizeCorner corner) {
    // Get card's global position
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;

    final globalOffset = box.localToGlobal(Offset.zero);
    final currentSize = Size(widget.viewState.width, widget.viewState.height);

    // 対角のコーナーをアンカーとして計算
    Offset anchor;
    switch (corner) {
      case ResizeCorner.bottomRight:
        anchor = globalOffset; // 左上固定
      case ResizeCorner.bottomLeft:
        anchor = Offset(globalOffset.dx + currentSize.width, globalOffset.dy); // 右上固定
      case ResizeCorner.topRight:
        anchor = Offset(globalOffset.dx, globalOffset.dy + currentSize.height); // 左下固定
      case ResizeCorner.topLeft:
        anchor = Offset(globalOffset.dx + currentSize.width, globalOffset.dy + currentSize.height); // 右下固定
    }

    setState(() {
      _isResizing = true;
      _resizeStartSize = currentSize;
      _resizeStartGlobalPosition = details.globalPosition;
      _resizeStartSpan = _currentSpan;
      _resizeCorner = corner;
      _anchorPosition = anchor;
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
    if (_resizeStartSize == null ||
        _resizeStartGlobalPosition == null ||
        _resizeCorner == null ||
        _anchorPosition == null) {
      return;
    }

    final delta = details.globalPosition - _resizeStartGlobalPosition!;

    // コーナーに応じてデルタを調整
    double adjustedDx;
    double adjustedDy;
    switch (_resizeCorner!) {
      case ResizeCorner.bottomRight:
        adjustedDx = delta.dx;
        adjustedDy = delta.dy;
      case ResizeCorner.bottomLeft:
        adjustedDx = -delta.dx;
        adjustedDy = delta.dy;
      case ResizeCorner.topRight:
        adjustedDx = delta.dx;
        adjustedDy = -delta.dy;
      case ResizeCorner.topLeft:
        adjustedDx = -delta.dx;
        adjustedDy = -delta.dy;
    }

    final targetWidth =
        (_resizeStartSize!.width + adjustedDx).clamp(100.0, 1920.0);
    final snappedSpan = _snapSpan(targetWidth);
    final snappedWidth = _widthForSpan(snappedSpan);
    final newHeight =
        (_resizeStartSize!.height + adjustedDy).clamp(100.0, 1080.0);

    // プレビュー矩形をアンカーベースで計算
    final previewRect = _calculatePreviewRect(Size(snappedWidth, newHeight));

    // Update overlay
    _overlayService?.update(
      globalRect: previewRect,
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

  /// アンカー位置とコーナーに基づいてプレビュー矩形を計算
  Rect _calculatePreviewRect(Size size) {
    final anchor = _anchorPosition!;
    switch (_resizeCorner!) {
      case ResizeCorner.bottomRight:
        return Rect.fromLTWH(anchor.dx, anchor.dy, size.width, size.height);
      case ResizeCorner.bottomLeft:
        return Rect.fromLTWH(anchor.dx - size.width, anchor.dy, size.width, size.height);
      case ResizeCorner.topRight:
        return Rect.fromLTWH(anchor.dx, anchor.dy - size.height, size.width, size.height);
      case ResizeCorner.topLeft:
        return Rect.fromLTWH(anchor.dx - size.width, anchor.dy - size.height, size.width, size.height);
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

    // コーナーを保存してからリセット
    final corner = _resizeCorner;

    setState(() {
      _isResizing = false;
      _resizeStartSize = null;
      _resizeStartGlobalPosition = null;
      _previewSize = null;
      _resizeCorner = null;
      _anchorPosition = null;
    });

    // ドラッグ終了時にGridLayoutStoreに永続化（cornerパラメータを渡す）
    widget.onResize(widget.item.id, finalSize, corner: corner);

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

  Widget _buildDeleteButton() {
    return ElevatedButton(
      onPressed:
          widget.onDelete != null ? () => widget.onDelete!(widget.item) : null,
      style: ElevatedButton.styleFrom(
        minimumSize: const Size(36, 36),
        padding: EdgeInsets.zero,
        backgroundColor: Colors.white.withOpacity(0.9),
      ),
      child: Icon(
        Icons.delete_outline,
        size: 20,
        color: Colors.red.shade700,
      ),
    );
  }

  Widget _buildSelectionCheckbox() {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: widget.isSelected
            ? Theme.of(context).colorScheme.primary
            : Colors.white.withOpacity(0.9),
        border: Border.all(
          color: Theme.of(context).colorScheme.primary,
          width: 2,
        ),
      ),
      child: widget.isSelected
          ? Icon(
              Icons.check,
              size: 20,
              color: Theme.of(context).colorScheme.onPrimary,
            )
          : null,
    ).withInkWell(
      onTap: widget.onSelectionToggle != null
          ? () => widget.onSelectionToggle!(widget.item.id)
          : null,
    );
  }
}

extension on Widget {
  Widget withInkWell({VoidCallback? onTap}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: this,
      ),
    );
  }
}
