/// IO platform window finder implementation.
library;

import 'dart:io';

import 'windows/windows_window_finder.dart' as windows;

/// Check if a window with the given title hash is open.
///
/// Only supported on Windows currently.
bool platformIsWindowOpen(String titleHash) {
  if (Platform.isWindows) {
    return windows.isWindowOpen(titleHash);
  }
  // macOS: Not supported yet (would need NSApplication.sharedApplication.windows)
  return false;
}

/// Activate (bring to front) a window with the given title hash.
///
/// Only supported on Windows currently.
void platformActivateWindow(String titleHash) {
  if (Platform.isWindows) {
    windows.activateWindow(titleHash);
  }
  // macOS: Not supported yet
}
