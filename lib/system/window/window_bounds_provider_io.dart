/// IO platform window bounds provider factory.
library;

import 'dart:io';

import 'macos/macos_bounds_provider.dart' as macos;
import 'window_bounds_provider_stub.dart' show WindowBoundsProvider;
import 'windows/windows_bounds_provider.dart' as windows;

export 'window_bounds_provider_stub.dart' show WindowBoundsProvider;

/// Creates a platform-specific window bounds provider.
///
/// Returns Windows provider on Windows, macOS provider on macOS, null otherwise.
WindowBoundsProvider? createPlatformWindowBoundsProvider() {
  if (Platform.isWindows) {
    return windows.createWindowBoundsProvider();
  }
  if (Platform.isMacOS) {
    return macos.createWindowBoundsProvider();
  }
  return null;
}
