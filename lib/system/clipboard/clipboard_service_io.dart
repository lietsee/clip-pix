/// Platform-specific factory implementation for dart:io platforms
///
/// This file handles platform detection and returns the appropriate
/// ClipboardReader/ClipboardWriter implementation.
library;

import 'dart:io' show Platform;

import 'clipboard_service.dart';
import 'macos/macos_clipboard_reader.dart';
import 'macos/macos_clipboard_writer.dart';
import 'windows/windows_clipboard_reader.dart';
import 'windows/windows_clipboard_writer.dart';

/// Creates a ClipboardReader for the current platform.
///
/// - Windows: Returns [WindowsClipboardReader]
/// - macOS: Returns [MacOSClipboardReader]
/// - Other: Throws [UnsupportedError]
ClipboardReader createReader() {
  if (Platform.isWindows) {
    return WindowsClipboardReader();
  }
  if (Platform.isMacOS) {
    return MacOSClipboardReader();
  }
  throw UnsupportedError(
    'ClipboardReader is not supported on ${Platform.operatingSystem}',
  );
}

/// Creates a ClipboardWriter for the current platform.
///
/// - Windows: Returns [WindowsClipboardWriter]
/// - macOS: Returns [MacOSClipboardWriter]
/// - Other: Throws [UnsupportedError]
ClipboardWriter createWriter() {
  if (Platform.isWindows) {
    return WindowsClipboardWriter();
  }
  if (Platform.isMacOS) {
    return MacOSClipboardWriter();
  }
  throw UnsupportedError(
    'ClipboardWriter is not supported on ${Platform.operatingSystem}',
  );
}
