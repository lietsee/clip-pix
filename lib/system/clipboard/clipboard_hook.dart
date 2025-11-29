/// Platform-agnostic clipboard hook factory.
///
/// Uses conditional imports to provide Windows-specific hook on Windows,
/// and a null stub on other platforms.
library;

import 'dart:async';

import 'package:logging/logging.dart';

import 'clipboard_hook_stub.dart'
    if (dart.library.io) 'clipboard_hook_io.dart';

export 'clipboard_hook_stub.dart' show ClipboardHook;

/// Creates a platform-specific clipboard hook if available.
///
/// Returns null on platforms where native hooks are not supported.
/// On Windows, returns a Win32-based hook using SetWinEventHook.
ClipboardHook? createPlatformClipboardHook(
  FutureOr<void> Function() onEvent,
  Logger logger,
) {
  return createClipboardHook(onEvent, logger);
}
