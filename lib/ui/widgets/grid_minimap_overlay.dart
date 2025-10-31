import 'dart:math' as math;

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

  /// Show minimap overlay
  void show({
    required BuildContext context,
    required ScrollController scrollController,
    required GridLayoutStore layoutStore,
  }) {
    if (_overlayEntry != null) {
      return; // Already showing
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

  void dispose() {
    hide();
    _stateNotifier.dispose();
  }
}

class MinimapState {
  final ScrollController? scrollController;
  final GridLayoutStore? layoutStore;
  final bool visible;

  MinimapState({
    required this.scrollController,
    required this.layoutStore,
    required this.visible,
  });

  factory MinimapState.empty() {
    return MinimapState(
      scrollController: null,
      layoutStore: null,
      visible: false,
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
          return const SizedBox.shrink();
        }

        final snapshot = layoutStore.latestSnapshot;
        if (snapshot == null || snapshot.entries.isEmpty) {
          return const SizedBox.shrink();
        }

        final screenSize = MediaQuery.of(context).size;
        final aspectRatio = screenSize.width / screenSize.height;
        final minimapHeight = screenSize.height * _minimapHeightPercent;
        final minimapWidth = minimapHeight * aspectRatio;

        return Positioned(
          right: _minimapPaddingRight,
          bottom: _minimapPaddingBottom,
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
                  minimapWidth: minimapWidth,
                  minimapHeight: minimapHeight,
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
  final double minimapWidth;
  final double minimapHeight;

  _MinimapPainter({
    required this.snapshot,
    required this.libraryState,
    required this.scrollOffset,
    required this.viewportHeight,
    required this.minimapWidth,
    required this.minimapHeight,
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
    }

    // Draw viewport indicator on right edge
    const indicatorWidth = 4.0;
    final viewportTop = scrollOffset * scale;
    final viewportBottom = (scrollOffset + viewportHeight) * scale;

    final viewportRect = Rect.fromLTWH(
      minimapWidth - indicatorWidth,
      viewportTop,
      indicatorWidth,
      viewportBottom - viewportTop,
    );

    // Fill
    canvas.drawRect(
      viewportRect,
      Paint()
        ..color = Colors.blue.withValues(alpha: 0.2)
        ..style = PaintingStyle.fill,
    );

    // Border
    canvas.drawRect(
      viewportRect,
      Paint()
        ..color = Colors.blue[300]!
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
    return oldDelegate.scrollOffset != scrollOffset ||
        oldDelegate.snapshot != snapshot ||
        oldDelegate.viewportHeight != viewportHeight ||
        oldDelegate.libraryState.images.length != libraryState.images.length;
  }
}
