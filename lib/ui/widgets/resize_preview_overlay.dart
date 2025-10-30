import 'package:flutter/material.dart';

/// Service for managing resize preview overlay that appears above all cards
class ResizePreviewOverlayService {
  OverlayEntry? _overlayEntry;
  final ValueNotifier<_OverlayState> _stateNotifier = ValueNotifier(
    _OverlayState(
      rect: Rect.zero,
      columnSpan: 1,
      visible: false,
    ),
  );

  /// Show overlay at given global position with initial size
  void show({
    required BuildContext context,
    required Rect globalRect,
    required int columnSpan,
  }) {
    hide(); // Remove existing if any

    _stateNotifier.value = _OverlayState(
      rect: globalRect,
      columnSpan: columnSpan,
      visible: true,
    );

    _overlayEntry = OverlayEntry(
      builder: (context) => _ResizePreviewOverlayWidget(
        stateNotifier: _stateNotifier,
      ),
    );

    Navigator.of(context).overlay!.insert(_overlayEntry!);
  }

  /// Update overlay size and position during drag
  void update({
    required Rect globalRect,
    required int columnSpan,
  }) {
    if (!_stateNotifier.value.visible) return;

    _stateNotifier.value = _OverlayState(
      rect: globalRect,
      columnSpan: columnSpan,
      visible: true,
    );
  }

  /// Hide and remove overlay
  void hide() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _stateNotifier.value = _stateNotifier.value.copyWith(visible: false);
  }

  void dispose() {
    hide();
    _stateNotifier.dispose();
  }
}

class _OverlayState {
  final Rect rect;
  final int columnSpan;
  final bool visible;

  _OverlayState({
    required this.rect,
    required this.columnSpan,
    required this.visible,
  });

  _OverlayState copyWith({Rect? rect, int? columnSpan, bool? visible}) {
    return _OverlayState(
      rect: rect ?? this.rect,
      columnSpan: columnSpan ?? this.columnSpan,
      visible: visible ?? this.visible,
    );
  }
}

class _ResizePreviewOverlayWidget extends StatelessWidget {
  const _ResizePreviewOverlayWidget({
    required this.stateNotifier,
  });

  final ValueNotifier<_OverlayState> stateNotifier;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_OverlayState>(
      valueListenable: stateNotifier,
      builder: (context, state, _) {
        if (!state.visible) return const SizedBox.shrink();

        return Positioned(
          left: state.rect.left,
          top: state.rect.top,
          width: state.rect.width,
          height: state.rect.height,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.1),
                border: Border.all(
                  color: Colors.blue.withOpacity(0.6),
                  width: 2,
                  strokeAlign: BorderSide.strokeAlignInside,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.blue.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '${state.rect.width.toInt()} × ${state.rect.height.toInt()} px\n列: ${state.columnSpan}',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
