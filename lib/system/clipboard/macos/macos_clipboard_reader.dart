/// macOS implementation of [ClipboardReader] using MethodChannel.
///
/// Communicates with native Swift code via MethodChannel to access NSPasteboard.
library;

import 'package:flutter/services.dart';

import '../clipboard_service.dart';

/// macOS implementation of [ClipboardReader].
///
/// Uses MethodChannel to communicate with native Swift code that
/// accesses NSPasteboard for clipboard operations.
class MacOSClipboardReader implements ClipboardReader {
  /// MethodChannel for communicating with native Swift code.
  static const _channel = MethodChannel('com.clip_pix/clipboard');

  /// Cached change count for synchronous access.
  int _cachedChangeCount = 0;

  /// Flag to prevent concurrent cache updates.
  bool _updateInProgress = false;

  @override
  int getChangeCount() {
    // Fire-and-forget async update to keep cache fresh
    if (!_updateInProgress) {
      _updateInProgress = true;
      _refreshChangeCount();
    }
    return _cachedChangeCount;
  }

  /// Asynchronously refreshes the cached change count from native code.
  Future<void> _refreshChangeCount() async {
    try {
      final count = await _channel.invokeMethod<int>('getChangeCount') ?? 0;
      _cachedChangeCount = count;
    } on PlatformException catch (_) {
      // Ignore errors - cache will remain stale
    } finally {
      _updateInProgress = false;
    }
  }

  @override
  Future<void> ensureInitialized() async {
    if (_cachedChangeCount == 0 && !_updateInProgress) {
      _updateInProgress = true;
      await _refreshChangeCount();
    }
  }

  @override
  Future<ClipboardContent?> read() async {
    try {
      // Update change count
      final changeCount =
          await _channel.invokeMethod<int>('getChangeCount') ?? 0;
      _cachedChangeCount = changeCount;

      // Try to read image first (PNG preferred)
      final imageData =
          await _channel.invokeMethod<Uint8List>('readImage');
      if (imageData != null && imageData.isNotEmpty) {
        return ClipboardContent(imageData: imageData);
      }

      // Try to read text
      final text = await _channel.invokeMethod<String>('readText');
      if (text != null && text.isNotEmpty) {
        return ClipboardContent(text: text);
      }

      return null;
    } on PlatformException catch (_) {
      // Platform method not available or failed
      return null;
    }
  }

  @override
  void dispose() {
    // No resources to release
  }
}
