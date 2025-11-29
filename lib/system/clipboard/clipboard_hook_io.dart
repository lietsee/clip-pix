/// IO platform clipboard hook factory.
///
/// Provides Windows-specific hook on Windows, null on other platforms.
library;

import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';

import 'windows/windows_clipboard_hook.dart' as windows;

export 'clipboard_hook_stub.dart' show ClipboardHook;

/// Creates a platform-specific clipboard hook if available.
///
/// Returns Windows hook on Windows, null on other platforms.
ClipboardHook? createClipboardHook(
  FutureOr<void> Function() onEvent,
  Logger logger,
) {
  if (Platform.isWindows) {
    return windows.createClipboardHook(onEvent, logger);
  }
  return null;
}

/// Abstract interface for clipboard hooks.
abstract class ClipboardHook {
  Future<bool> start();
  Future<void> stop();
}
