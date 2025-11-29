/// Stub implementation for unsupported platforms (web, etc.)
///
/// This file is imported when dart:io is not available.
library;

import 'clipboard_service.dart';

/// Creates a ClipboardReader for the current platform.
///
/// Throws [UnsupportedError] on unsupported platforms.
ClipboardReader createReader() {
  throw UnsupportedError(
    'ClipboardReader is not supported on this platform.',
  );
}

/// Creates a ClipboardWriter for the current platform.
///
/// Throws [UnsupportedError] on unsupported platforms.
ClipboardWriter createWriter() {
  throw UnsupportedError(
    'ClipboardWriter is not supported on this platform.',
  );
}
