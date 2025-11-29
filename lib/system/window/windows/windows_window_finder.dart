/// Windows implementation of window finder using Win32 API.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Check if a window with the given title hash is open.
bool isWindowOpen(String titleHash) {
  try {
    final titlePtr = TEXT(titleHash);
    // Search by window title only (class name = nullptr)
    final hwnd = FindWindow(Pointer.fromAddress(0), titlePtr);
    calloc.free(titlePtr);

    debugPrint(
        '[WindowFinder] isWindowOpen: titleHash="$titleHash", hwnd=$hwnd');

    if (hwnd == 0) {
      return false;
    }

    // Verify the window handle is still valid
    final isValid = IsWindow(hwnd) != 0;
    debugPrint('[WindowFinder] IsWindow result: $isValid for hwnd=$hwnd');

    return isValid;
  } catch (e) {
    debugPrint('[WindowFinder] Error checking window existence: $e');
    return false;
  }
}

/// Activate (bring to front) a window with the given title hash.
void activateWindow(String titleHash) {
  try {
    final titlePtr = TEXT(titleHash);
    // Search by window title only (class name = nullptr)
    final hwnd = FindWindow(Pointer.fromAddress(0), titlePtr);
    calloc.free(titlePtr);

    if (hwnd == 0) {
      debugPrint('[WindowFinder] Window not found: $titleHash');
      return;
    }

    // Verify window is still valid
    if (IsWindow(hwnd) == 0) {
      debugPrint(
          '[WindowFinder] IsWindow returned invalid: $titleHash (hwnd=$hwnd)');
      return;
    }

    // Restore if minimized
    if (IsIconic(hwnd) != 0) {
      final restoreResult = ShowWindow(hwnd, SW_RESTORE);
      debugPrint('[WindowFinder] ShowWindow(SW_RESTORE) result: $restoreResult');
    }

    // Get thread IDs for input attachment
    final foregroundHwnd = GetForegroundWindow();
    final foregroundThreadId = GetWindowThreadProcessId(
        foregroundHwnd, Pointer<Uint32>.fromAddress(0));
    final targetThreadId =
        GetWindowThreadProcessId(hwnd, Pointer<Uint32>.fromAddress(0));

    debugPrint(
        '[WindowFinder] Thread IDs: foreground=$foregroundThreadId, target=$targetThreadId');

    // Attach input if different threads
    int attachResult = 0;
    if (foregroundThreadId != targetThreadId && foregroundThreadId != 0) {
      attachResult = AttachThreadInput(foregroundThreadId, targetThreadId, 1);
      debugPrint('[WindowFinder] AttachThreadInput result: $attachResult');
    }

    // Multiple activation attempts for reliability
    final bringToTopResult = BringWindowToTop(hwnd);
    final showResult = ShowWindow(hwnd, SW_SHOW);
    final setForegroundResult = SetForegroundWindow(hwnd);
    final setFocusResult = SetFocus(hwnd);

    debugPrint('[WindowFinder] Activation results: '
        'BringWindowToTop=$bringToTopResult, ShowWindow=$showResult, '
        'SetForegroundWindow=$setForegroundResult, SetFocus=$setFocusResult');

    // Detach input
    if (foregroundThreadId != targetThreadId && foregroundThreadId != 0) {
      final detachResult =
          AttachThreadInput(foregroundThreadId, targetThreadId, 0);
      debugPrint('[WindowFinder] DetachThreadInput result: $detachResult');
    }

    debugPrint('[WindowFinder] Activated window: $titleHash (hwnd=$hwnd)');
  } catch (e) {
    debugPrint('[WindowFinder] Error activating window: $e');
  }
}
