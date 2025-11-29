/// macOS implementation of [ClipboardWriter] using MethodChannel.
///
/// Communicates with native Swift code via MethodChannel to access NSPasteboard.
library;

import 'package:flutter/services.dart';

import '../clipboard_service.dart';

/// macOS implementation of [ClipboardWriter].
///
/// Uses MethodChannel to communicate with native Swift code that
/// accesses NSPasteboard for clipboard write operations.
class MacOSClipboardWriter implements ClipboardWriter {
  /// MethodChannel for communicating with native Swift code.
  static const _channel = MethodChannel('com.clip_pix/clipboard');

  @override
  Future<void> writeImage(Uint8List imageData) async {
    try {
      await _channel.invokeMethod('writeImage', {'data': imageData});
    } on PlatformException catch (e) {
      throw ClipboardWriteException('Failed to write image: ${e.message}');
    }
  }

  @override
  Future<void> writeText(String text) async {
    try {
      await _channel.invokeMethod('writeText', {'text': text});
    } on PlatformException catch (e) {
      throw ClipboardWriteException('Failed to write text: ${e.message}');
    }
  }

  @override
  void dispose() {
    // No resources to release
  }
}

/// Exception thrown when clipboard write operation fails.
class ClipboardWriteException implements Exception {
  const ClipboardWriteException(this.message);
  final String message;

  @override
  String toString() => 'ClipboardWriteException: $message';
}
