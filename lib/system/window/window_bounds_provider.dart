/// Platform-agnostic window bounds provider.
///
/// Uses conditional imports to provide platform-specific implementations.
library;

import 'dart:ui';

import 'window_bounds_provider_stub.dart'
    if (dart.library.io) 'window_bounds_provider_io.dart';

/// Abstract interface for reading and writing window bounds.
abstract class WindowBoundsProvider {
  /// Read current window bounds.
  /// Returns null if bounds cannot be read.
  Rect? readBounds();

  /// Apply bounds to window.
  /// Returns true if successful.
  bool applyBounds(Rect rect);

  /// Dispose of any resources.
  void dispose();
}

/// Creates a platform-specific window bounds provider.
///
/// Returns null on unsupported platforms.
WindowBoundsProvider? createWindowBoundsProvider() {
  return createPlatformWindowBoundsProvider();
}
