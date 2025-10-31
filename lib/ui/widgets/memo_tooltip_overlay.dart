import 'package:flutter/material.dart';

/// Service to display memo tooltip overlay above/below image cards
class MemoTooltipOverlayService {
  OverlayEntry? _overlayEntry;
  final ValueNotifier<_TooltipState> _stateNotifier =
      ValueNotifier(_TooltipState.empty());

  /// Show memo tooltip near the specified card rectangle
  void show({
    required BuildContext context,
    required Rect cardRect,
    required String memo,
  }) {
    if (_overlayEntry != null) {
      hide();
    }

    _stateNotifier.value = _TooltipState(
      cardRect: cardRect,
      memo: memo,
      visible: true,
    );

    _overlayEntry = OverlayEntry(
      builder: (context) => _MemoTooltipWidget(stateNotifier: _stateNotifier),
    );

    Navigator.of(context).overlay!.insert(_overlayEntry!);
  }

  /// Hide and remove the tooltip overlay
  void hide() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _stateNotifier.value = _TooltipState.empty();
  }

  void dispose() {
    hide();
    _stateNotifier.dispose();
  }
}

class _TooltipState {
  final Rect cardRect;
  final String memo;
  final bool visible;

  _TooltipState({
    required this.cardRect,
    required this.memo,
    required this.visible,
  });

  factory _TooltipState.empty() {
    return _TooltipState(
      cardRect: Rect.zero,
      memo: '',
      visible: false,
    );
  }
}

class _MemoTooltipWidget extends StatelessWidget {
  const _MemoTooltipWidget({required this.stateNotifier});

  final ValueNotifier<_TooltipState> stateNotifier;

  static const double _maxWidth = 300.0;
  static const double _padding = 12.0;
  static const double _verticalPadding = 10.0;
  static const double _offset = 8.0;
  static const double _borderRadius = 8.0;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_TooltipState>(
      valueListenable: stateNotifier,
      builder: (context, state, child) {
        if (!state.visible || state.memo.isEmpty) {
          return const SizedBox.shrink();
        }

        final screenSize = MediaQuery.of(context).size;

        // Calculate tooltip position
        final position = _calculatePosition(
          cardRect: state.cardRect,
          screenSize: screenSize,
        );

        return Positioned(
          left: position.left,
          top: position.top,
          child: Material(
            color: Colors.transparent,
            child: Container(
              constraints: const BoxConstraints(maxWidth: _maxWidth),
              padding: const EdgeInsets.symmetric(
                horizontal: _padding,
                vertical: _verticalPadding,
              ),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.85),
                borderRadius: BorderRadius.circular(_borderRadius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.3),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                state.memo,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Calculate tooltip position to avoid covering card controls
  _TooltipPosition _calculatePosition({
    required Rect cardRect,
    required Size screenSize,
  }) {
    // Estimate tooltip height (rough approximation)
    final estimatedHeight = 60.0;

    final spaceAbove = cardRect.top;

    // Prefer showing above the card
    final showAbove = spaceAbove > estimatedHeight + _offset;

    final top = showAbove
        ? cardRect.top - estimatedHeight - _offset
        : cardRect.bottom + _offset;

    // Center horizontally relative to card, but keep within screen bounds
    final cardCenterX = cardRect.left + cardRect.width / 2;
    final tooltipHalfWidth = _maxWidth / 2;

    double left = cardCenterX - tooltipHalfWidth;

    // Clamp to screen bounds with padding
    const screenPadding = 16.0;
    if (left < screenPadding) {
      left = screenPadding;
    } else if (left + _maxWidth > screenSize.width - screenPadding) {
      left = screenSize.width - _maxWidth - screenPadding;
    }

    return _TooltipPosition(left: left, top: top);
  }
}

class _TooltipPosition {
  final double left;
  final double top;

  _TooltipPosition({required this.left, required this.top});
}
