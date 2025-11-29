/// macOS implementation of window bounds provider using window_manager.
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

/// Creates a macOS window bounds provider.
WindowBoundsProvider createWindowBoundsProvider() {
  return _MacOSWindowBoundsProvider();
}

/// Abstract interface for window bounds provider.
abstract class WindowBoundsProvider {
  Rect? readBounds();
  bool applyBounds(Rect rect);
  void dispose();
}

class _MacOSWindowBoundsProvider implements WindowBoundsProvider {
  // Cached bounds for synchronous access
  Rect? _cachedBounds;

  @override
  Rect? readBounds() {
    // window_manager is async, so we need to update cache asynchronously
    // and return cached value for synchronous calls
    _updateBoundsCache();
    return _cachedBounds;
  }

  Future<void> _updateBoundsCache() async {
    try {
      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();

      if (size.width <= 0 || size.height <= 0) {
        debugPrint('[MacOSBoundsProvider] invalid size: $size');
        return;
      }

      _cachedBounds = Rect.fromLTWH(
        position.dx,
        position.dy,
        size.width,
        size.height,
      );
      debugPrint('[MacOSBoundsProvider] read: $_cachedBounds');
    } catch (e) {
      debugPrint('[MacOSBoundsProvider] readBounds error: $e');
    }
  }

  @override
  bool applyBounds(Rect rect) {
    // window_manager is async, so we fire-and-forget
    _applyBoundsAsync(rect);
    return true; // Assume success, actual result checked in async
  }

  Future<void> _applyBoundsAsync(Rect rect) async {
    try {
      await windowManager.setPosition(Offset(rect.left, rect.top));
      await windowManager.setSize(Size(rect.width, rect.height));
      debugPrint('[MacOSBoundsProvider] applied: $rect');
    } catch (e) {
      debugPrint('[MacOSBoundsProvider] applyBounds error: $e');
    }
  }

  @override
  void dispose() {
    // No resources to release
  }
}
