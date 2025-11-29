/// Platform-agnostic window bounds provider.
///
/// Uses conditional imports to provide platform-specific implementations.
library;

import 'window_bounds_provider_stub.dart'
    if (dart.library.io) 'window_bounds_provider_io.dart';

export 'window_bounds_provider_stub.dart' show WindowBoundsProvider;

/// Creates a platform-specific window bounds provider.
///
/// Returns null on unsupported platforms.
WindowBoundsProvider? createWindowBoundsProvider() {
  return createPlatformWindowBoundsProvider();
}
