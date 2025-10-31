import 'package:flutter/material.dart';

/// Service to display memo tooltip overlay to the right/left of image cards
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

  static const double _defaultWidth = 200.0;
  static const double _maxWidth = 400.0;
  static const double _padding = 12.0;
  static const double _verticalPadding = 10.0;
  static const double _horizontalOffset = 8.0;
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
              constraints: const BoxConstraints(
                minWidth: _defaultWidth,
                maxWidth: _maxWidth,
              ),
              width: _defaultWidth,
              padding: const EdgeInsets.symmetric(
                horizontal: _padding,
                vertical: _verticalPadding,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFFA8F0C8),
                borderRadius: BorderRadius.circular(_borderRadius),
                boxShadow: [
                  BoxShadow(
                    color: Colors.grey.withValues(alpha: 0.2),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: RichText(
                text: TextSpan(
                  children: [
                    const TextSpan(
                      text: '[MEMO]\n',
                      style: TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text: state.memo,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Calculate tooltip position to the right or left of card
  _TooltipPosition _calculatePosition({
    required Rect cardRect,
    required Size screenSize,
  }) {
    // Estimate tooltip height (rough approximation based on memo length)
    final estimatedHeight = 80.0;

    const screenPadding = 16.0;

    // Check if there's enough space on the right
    final spaceOnRight =
        screenSize.width - cardRect.right - _horizontalOffset - screenPadding;
    final showOnRight = spaceOnRight >= _defaultWidth;

    // Position horizontally
    final left = showOnRight
        ? cardRect.right + _horizontalOffset
        : cardRect.left - _defaultWidth - _horizontalOffset;

    // Center vertically relative to card
    final cardCenterY = cardRect.top + cardRect.height / 2;
    double top = cardCenterY - estimatedHeight / 2;

    // Clamp to screen bounds vertically
    if (top < screenPadding) {
      top = screenPadding;
    } else if (top + estimatedHeight > screenSize.height - screenPadding) {
      top = screenSize.height - estimatedHeight - screenPadding;
    }

    return _TooltipPosition(left: left, top: top);
  }
}

class _TooltipPosition {
  final double left;
  final double top;

  _TooltipPosition({required this.left, required this.top});
}
