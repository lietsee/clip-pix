/// IO platform implementation for always-on-top functionality.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

import 'windows/windows_always_on_top.dart' as windows;

/// Applies always-on-top state to the current window.
///
/// - Windows: Uses Win32 SetWindowPos API
/// - macOS: Uses window_manager package
/// - Other: Returns false (unsupported)
Future<bool> platformApplyAlwaysOnTop(bool enable) async {
  if (Platform.isWindows) {
    return windows.applyAlwaysOnTop(enable);
  }

  if (Platform.isMacOS) {
    try {
      await windowManager.setAlwaysOnTop(enable);
      debugPrint('[AlwaysOnTop] macOS: set to $enable');
      return true;
    } catch (e) {
      debugPrint('[AlwaysOnTop] macOS error: $e');
      return false;
    }
  }

  return false;
}
