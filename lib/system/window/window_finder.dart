/// Platform-agnostic helper for finding and activating windows.
library;

import 'window_finder_stub.dart'
    if (dart.library.io) 'window_finder_io.dart';

/// Check if a window with the given title hash is open.
///
/// Returns true if found, false otherwise.
/// On unsupported platforms, always returns false.
bool isWindowOpen(String titleHash) {
  return platformIsWindowOpen(titleHash);
}

/// Activate (bring to front) a window with the given title hash.
///
/// On unsupported platforms, this is a no-op.
void activateWindow(String titleHash) {
  platformActivateWindow(titleHash);
}
