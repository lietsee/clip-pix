/// IO platform window bounds provider factory.
library;

import 'dart:io';
import 'dart:ui';

import 'macos/macos_bounds_provider.dart' as macos;
import 'windows/windows_bounds_provider.dart' as windows;

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

/// Abstract interface for window bounds provider.
abstract class WindowBoundsProvider {
  Rect? readBounds();
  bool applyBounds(Rect rect);
  void dispose();
}
