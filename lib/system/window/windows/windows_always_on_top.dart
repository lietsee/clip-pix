/// Windows implementation of always-on-top functionality using Win32 API.
library;

import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Applies always-on-top state using Win32 SetWindowPos.
bool applyAlwaysOnTop(bool enable) {
  try {
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) {
      debugPrint('[AlwaysOnTop] Windows: failed to get window handle');
      return false;
    }

    final flag = enable ? HWND_TOPMOST : HWND_NOTOPMOST;
    final result = SetWindowPos(
      hwnd,
      flag,
      0,
      0,
      0,
      0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );

    if (result == 0) {
      final error = GetLastError();
      debugPrint('[AlwaysOnTop] Windows: SetWindowPos failed, error=$error');
      return false;
    }

    debugPrint('[AlwaysOnTop] Windows: set to $enable');
    return true;
  } catch (e) {
    debugPrint('[AlwaysOnTop] Windows error: $e');
    return false;
  }
}
