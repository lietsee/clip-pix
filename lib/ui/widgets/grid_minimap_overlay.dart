import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/models/content_item.dart';
import '../../system/grid_layout_layout_engine.dart';
import '../../system/state/grid_layout_store.dart';
import '../../system/state/image_library_state.dart';

/// Service to display minimap overlay on the right edge of the screen
class MinimapOverlayService {
  OverlayEntry? _overlayEntry;
  final ValueNotifier<MinimapState> _stateNotifier =
      ValueNotifier(MinimapState.empty());

  /// Check if the minimap overlay is currently visible and mounted
  bool get isVisible => _overlayEntry?.mounted ?? false;

  /// Show minimap overlay
  void show({
    required BuildContext context,
    required ScrollController scrollController,
    required GridLayoutStore layoutStore,
  }) {
    if (isVisible) {
      return; // Already showing and mounted
    }

    // Clean up any stale overlay entry that is not mounted
    if (_overlayEntry != null && !_overlayEntry!.mounted) {
      _overlayEntry = null;
    }

    _stateNotifier.value = MinimapState(
      scrollController: scrollController,
      layoutStore: layoutStore,
      visible: true,
    );

    _overlayEntry = OverlayEntry(
      builder: (context) => _MinimapWidget(stateNotifier: _stateNotifier),
    );

    Navigator.of(context).overlay!.insert(_overlayEntry!);
  }

  /// Hide and remove the minimap overlay
  void hide() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _stateNotifier.value = MinimapState.empty();
  }

  /// Update the hovered card ID for minimap highlighting
  void updateHoveredCard(String? cardId) {
    if (!isVisible) return;
    final current = _stateNotifier.value;
    if (current.hoveredCardId != cardId) {
      _stateNotifier.value = current.copyWith(hoveredCardId: cardId);
    }
  }

  void dispose() {
    hide();
    _stateNotifier.dispose();
  }
}

class MinimapState {
  final ScrollController? scrollController;
  final GridLayoutStore? layoutStore;
  final bool visible;
  final String? hoveredCardId;

  MinimapState({
    required this.scrollController,
    required this.layoutStore,
    required this.visible,
    this.hoveredCardId,
  });

  factory MinimapState.empty() {
    return MinimapState(
      scrollController: null,
      layoutStore: null,
      visible: false,
      hoveredCardId: null,
    );
  }

  MinimapState copyWith({String? hoveredCardId}) {
    return MinimapState(
      scrollController: scrollController,
      layoutStore: layoutStore,
      visible: visible,
      hoveredCardId: hoveredCardId,
    );
  }
}

class _MinimapWidget extends StatefulWidget {
  const _MinimapWidget({required this.stateNotifier});

  final ValueNotifier<MinimapState> stateNotifier;

  @override
  State<_MinimapWidget> createState() => _MinimapWidgetState();
}

class _MinimapWidgetState extends State<_MinimapWidget> {
  static const double _minimapHeightPercent = 0.25; // 25% of screen height
  static const double _minimapPaddingBottom = 16.0;
  static const double _minimapPaddingRight = 16.0;

  @override
  void initState() {
    super.initState();
    final state = widget.stateNotifier.value;
    state.scrollController?.addListener(_onScroll);
    state.layoutStore?.addListener(_onLayoutChange);
  }

  @override
  void dispose() {
    final state = widget.stateNotifier.value;
    state.scrollController?.removeListener(_onScroll);
    state.layoutStore?.removeListener(_onLayoutChange);
    super.dispose();
  }

  void _onScroll() {
    if (mounted) {
      setState(() {});
    }
  }

  void _onLayoutChange() {
    if (mounted) {
      setState(() {});
    }
  }

  Size _calculateContentDimensions(LayoutSnapshot snapshot) {
    if (snapshot.entries.isEmpty) return const Size(1, 1);

    double maxWidth = 0;
    double maxHeight = 0;
    for (final entry in snapshot.entries) {
      if (entry.rect.right > maxWidth) maxWidth = entry.rect.right;
      if (entry.rect.bottom > maxHeight) maxHeight = entry.rect.bottom;
    }
    return Size(maxWidth, maxHeight);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MinimapState>(
      valueListenable: widget.stateNotifier,
      builder: (context, state, child) {
        if (!state.visible ||
            state.scrollController == null ||
            state.layoutStore == null) {
          return const SizedBox.shrink();
        }

        final scrollController = state.scrollController!;
        final layoutStore = state.layoutStore!;
        final libraryState = context.watch<ImageLibraryState>();

        if (!scrollController.hasClients) {
          print('[Minimap] hasClients=false, scheduling retry');
          // 次フレームで再チェック
          // グリッドがビルドされて ScrollController にクライアントがアタッチされるのを待つ
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              print('[Minimap] retry: hasClients=${scrollController.hasClients}');
              setState(() {}); // 再ビルドをトリガー
            }
          });
          return const SizedBox.shrink();
        }

        final snapshot = layoutStore.latestSnapshot;
        if (snapshot == null || snapshot.entries.isEmpty) {
          print('[Minimap] snapshot empty: isNull=${snapshot == null}, entriesCount=${snapshot?.entries.length ?? 0}');
          return const SizedBox.shrink();
        }

        final screenSize = MediaQuery.of(context).size;
        final contentDimensions = _calculateContentDimensions(snapshot);
        final aspectRatio = contentDimensions.width / contentDimensions.height;
        final minimapHeight = screenSize.height * _minimapHeightPercent;
        final minimapWidth = minimapHeight * aspectRatio;

        return Positioned(
          right: _minimapPaddingRight,
          bottom: _minimapPaddingBottom,
          child: Listener(
            onPointerSignal: (event) => _handlePointerSignal(
              event,
              minimapHeight,
              scrollController,
              snapshot,
            ),
            child: GestureDetector(
              onTapDown: (details) => _handleTap(
                details.localPosition,
                minimapHeight,
                scrollController,
                snapshot,
              ),
              onVerticalDragUpdate: (details) => _handleDrag(
                details.localPosition,
                minimapHeight,
                scrollController,
                snapshot,
              ),
              child: Container(
                width: minimapWidth,
                height: minimapHeight,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.8),
                  borderRadius: BorderRadius.circular(4),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 8,
                      offset: const Offset(-2, 0),
                    ),
                  ],
                ),
                child: CustomPaint(
                  painter: _MinimapPainter(
                    snapshot: snapshot,
                    libraryState: libraryState,
                    scrollOffset: scrollController.offset,
                    viewportHeight: scrollController.position.viewportDimension,
                    viewportWidth: screenSize.width,
                    minimapWidth: minimapWidth,
                    minimapHeight: minimapHeight,
                    hoveredCardId: state.hoveredCardId,
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _handleTap(
    Offset localPosition,
    double minimapHeight,
    ScrollController scrollController,
    LayoutSnapshot snapshot,
  ) {
    final totalContentHeight = _calculateTotalContentHeight(snapshot);
    final scale = minimapHeight / totalContentHeight;
    final targetScroll = localPosition.dy / scale;

    scrollController.animateTo(
      targetScroll.clamp(
        scrollController.position.minScrollExtent,
        scrollController.position.maxScrollExtent,
      ),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _handleDrag(
    Offset localPosition,
    double minimapHeight,
    ScrollController scrollController,
    LayoutSnapshot snapshot,
  ) {
    final totalContentHeight = _calculateTotalContentHeight(snapshot);
    final scale = minimapHeight / totalContentHeight;
    final targetScroll = localPosition.dy / scale;

    scrollController.jumpTo(
      targetScroll.clamp(
        scrollController.position.minScrollExtent,
        scrollController.position.maxScrollExtent,
      ),
    );
  }

  void _handlePointerSignal(
    PointerSignalEvent event,
    double minimapHeight,
    ScrollController scrollController,
    LayoutSnapshot snapshot,
  ) {
    if (event is PointerScrollEvent) {
      GestureBinding.instance.pointerSignalResolver.register(
        event,
        (resolvedEvent) {
          final scrollEvent = resolvedEvent as PointerScrollEvent;

          // Scroll sensitivity (1.0 = direct mapping)
          const scrollSensitivity = 1.0;
          final delta = scrollEvent.scrollDelta.dy * scrollSensitivity;

          // Calculate new scroll position
          final currentOffset = scrollController.offset;
          final newOffset = (currentOffset + delta).clamp(
            scrollController.position.minScrollExtent,
            scrollController.position.maxScrollExtent,
          );

          // Immediately scroll (no animation)
          scrollController.jumpTo(newOffset);
        },
      );
    }
  }

  double _calculateTotalContentHeight(LayoutSnapshot snapshot) {
    if (snapshot.entries.isEmpty) return 0;

    double maxBottom = 0;
    for (final entry in snapshot.entries) {
      final bottom = entry.rect.bottom;
      if (bottom > maxBottom) {
        maxBottom = bottom;
      }
    }
    return maxBottom;
  }
}

class _MinimapPainter extends CustomPainter {
  final LayoutSnapshot snapshot;
  final ImageLibraryState libraryState;
  final double scrollOffset;
  final double viewportHeight;
  final double viewportWidth;
  final double minimapWidth;
  final double minimapHeight;
  final String? hoveredCardId;

  _MinimapPainter({
    required this.snapshot,
    required this.libraryState,
    required this.scrollOffset,
    required this.viewportHeight,
    required this.viewportWidth,
    required this.minimapWidth,
    required this.minimapHeight,
    this.hoveredCardId,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Calculate total content dimensions
    double totalContentHeight = 0;
    double totalContentWidth = 0;
    for (final entry in snapshot.entries) {
      final bottom = entry.rect.bottom;
      final right = entry.rect.right;
      if (bottom > totalContentHeight) {
        totalContentHeight = bottom;
      }
      if (right > totalContentWidth) {
        totalContentWidth = right;
      }
    }

    if (totalContentHeight == 0 || totalContentWidth == 0) return;

    // Calculate both horizontal and vertical scales
    final scaleY = minimapHeight / totalContentHeight;
    final scaleX = minimapWidth / totalContentWidth;

    // Use smaller scale to fit content without distortion
    final scale = math.min(scaleX, scaleY);

    // Calculate horizontal centering offset
    final scaledContentWidth = totalContentWidth * scale;
    final xOffset = (minimapWidth - scaledContentWidth) / 2;

    // Create a map for quick item lookup
    final itemMap = <String, ContentItem>{};
    for (final item in libraryState.images) {
      itemMap[item.id] = item;
    }

    // Draw each card
    for (final entry in snapshot.entries) {
      final item = itemMap[entry.id];
      if (item == null) continue;

      final scaledRect = Rect.fromLTWH(
        entry.rect.left * scale + xOffset,
        entry.rect.top * scale,
        entry.rect.width * scale,
        entry.rect.height * scale,
      );

      if (item.favorite > 0) {
        // Favorite cards: filled with color + white heart
        Color fillColor;
        if (item.favorite == 1) {
          fillColor = Colors.green[400]!;
        } else if (item.favorite == 2) {
          fillColor = Colors.orange[400]!;
        } else {
          fillColor = Colors.pink[400]!;
        }

        // Draw filled rectangle
        canvas.drawRRect(
          RRect.fromRectAndRadius(scaledRect, const Radius.circular(2)),
          Paint()..color = fillColor,
        );

        // Draw white heart
        _drawHeart(canvas, scaledRect.center, scaledRect.width * 0.25);
      } else {
        // Non-favorite cards: grey border only
        canvas.drawRRect(
          RRect.fromRectAndRadius(scaledRect, const Radius.circular(2)),
          Paint()
            ..color = Colors.grey[600]!
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      }

      // Draw hover highlight if this card is hovered
      final isHovered = entry.id == hoveredCardId;
      if (isHovered) {
        final rrect =
            RRect.fromRectAndRadius(scaledRect, const Radius.circular(2));

        // Semi-transparent light blue fill
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = Colors.lightBlue.withValues(alpha: 0.4)
            ..style = PaintingStyle.fill,
        );

        // Light blue border
        canvas.drawRRect(
          rrect,
          Paint()
            ..color = Colors.lightBlue
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.0,
        );
      }
    }

    // Draw viewport indicator as yellow border box
    final viewportLeft = xOffset;
    final viewportTop = scrollOffset * scale;
    final scaledViewportWidth = viewportWidth * scale;
    final scaledViewportHeight = viewportHeight * scale;

    final viewportRect = Rect.fromLTWH(
      viewportLeft,
      viewportTop,
      scaledViewportWidth,
      scaledViewportHeight,
    ).intersect(Rect.fromLTWH(0, 0, minimapWidth, minimapHeight));

    // Semi-transparent yellow fill
    canvas.drawRect(
      viewportRect,
      Paint()
        ..color = Colors.yellow.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill,
    );

    // Yellow border
    canvas.drawRect(
      viewportRect,
      Paint()
        ..color = Colors.yellow
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  void _drawHeart(Canvas canvas, Offset center, double size) {
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final path = Path();

    // Simple heart shape using bezier curves
    final left = center.dx - size / 2;
    final right = center.dx + size / 2;
    final top = center.dy - size / 3;
    final bottom = center.dy + size / 2;

    path.moveTo(center.dx, bottom);
    path.cubicTo(
      left,
      top + size / 3,
      left,
      top,
      center.dx - size / 4,
      top,
    );
    path.cubicTo(
      center.dx,
      top - size / 6,
      center.dx,
      top - size / 6,
      center.dx,
      top,
    );
    path.cubicTo(
      center.dx,
      top - size / 6,
      center.dx,
      top - size / 6,
      center.dx + size / 4,
      top,
    );
    path.cubicTo(
      right,
      top,
      right,
      top + size / 3,
      center.dx,
      bottom,
    );
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_MinimapPainter oldDelegate) {
    final scrollChanged = oldDelegate.scrollOffset != scrollOffset;
    final snapshotChanged = oldDelegate.snapshot != snapshot;
    final viewportHeightChanged = oldDelegate.viewportHeight != viewportHeight;
    final viewportWidthChanged = oldDelegate.viewportWidth != viewportWidth;
    final hoveredCardChanged = oldDelegate.hoveredCardId != hoveredCardId;

    // Deep comparison: only repaint if IDs or favorite states actually changed
    final imagesChanged = _imagesActuallyChanged(
      oldDelegate.libraryState.images,
      libraryState.images,
    );

    return scrollChanged ||
        snapshotChanged ||
        viewportHeightChanged ||
        viewportWidthChanged ||
        hoveredCardChanged ||
        imagesChanged;
  }

  /// Deep comparison of images list: only returns true if IDs or favorite states changed
  bool _imagesActuallyChanged(
    List<ContentItem> oldImages,
    List<ContentItem> newImages,
  ) {
    if (oldImages.length != newImages.length) return true;

    for (int i = 0; i < oldImages.length; i++) {
      if (oldImages[i].id != newImages[i].id ||
          oldImages[i].favorite != newImages[i].favorite) {
        return true;
      }
    }

    return false;
  }
}
