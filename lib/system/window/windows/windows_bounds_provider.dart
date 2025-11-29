/// Windows implementation of window bounds provider using Win32 API.
library;

import 'dart:ffi';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:win32/win32.dart';

/// Creates a Windows window bounds provider.
WindowBoundsProvider createWindowBoundsProvider() {
  return _WindowsWindowBoundsProvider();
}

/// Abstract interface for window bounds provider.
abstract class WindowBoundsProvider {
  Rect? readBounds();
  bool applyBounds(Rect rect);
  void dispose();
}

class _WindowsWindowBoundsProvider implements WindowBoundsProvider {
  @override
  Rect? readBounds() {
    final hwnd = _resolveWindowHandle();
    if (hwnd == 0) {
      return null;
    }
    final rectPointer = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rectPointer) == 0) {
        return null;
      }
      final rect = rectPointer.ref;
      final width = rect.right - rect.left;
      final height = rect.bottom - rect.top;
      if (width <= 0 || height <= 0) {
        return null;
      }
      final result = Rect.fromLTWH(
        rect.left.toDouble(),
        rect.top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      );
      debugPrint('[WindowsBoundsProvider] read: $result');
      return result;
    } finally {
      calloc.free(rectPointer);
    }
  }

  @override
  bool applyBounds(Rect rect) {
    final hwnd = _resolveWindowHandle();
    if (hwnd == 0) {
      debugPrint('[WindowsBoundsProvider] apply bounds failed; hwnd=0');
      return false;
    }
    final width = rect.width.round();
    final height = rect.height.round();
    final left = rect.left.round();
    final top = rect.top.round();
    final result = SetWindowPos(
      hwnd,
      NULL,
      left,
      top,
      width,
      height,
      SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
    );
    return result != 0;
  }

  @override
  void dispose() {
    // No resources to release
  }

  int _resolveWindowHandle() {
    final className = TEXT('FLUTTER_RUNNER_WIN32_WINDOW');
    final hwnd = FindWindow(className, nullptr.cast<Utf16>());
    calloc.free(className);
    if (hwnd != 0) {
      return hwnd;
    }
    return GetForegroundWindow();
  }
}
