/// Stub implementation for window bounds provider on unsupported platforms.
library;

import 'dart:ui';

/// Creates a window bounds provider stub.
///
/// Returns null on unsupported platforms.
WindowBoundsProvider? createPlatformWindowBoundsProvider() {
  return null;
}

/// Abstract interface for window bounds provider.
///
/// Duplicated here to avoid circular imports.
abstract class WindowBoundsProvider {
  Rect? readBounds();
  bool applyBounds(Rect rect);
  void dispose();
}
