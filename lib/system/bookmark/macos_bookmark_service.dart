/// macOS implementation of [BookmarkService] using MethodChannel.
///
/// Communicates with native Swift code via MethodChannel to access
/// Security-Scoped Bookmarks for persistent folder access.
library;

import 'package:flutter/services.dart';

import 'bookmark_service.dart';

/// macOS implementation of [BookmarkService].
///
/// Uses MethodChannel to communicate with native Swift code that
/// manages Security-Scoped Bookmarks for folder access persistence.
class MacOSBookmarkService implements BookmarkService {
  /// MethodChannel for communicating with native Swift code.
  static const _channel = MethodChannel('com.clip_pix/bookmark');

  @override
  Future<String?> saveBookmark(String path) async {
    try {
      final result = await _channel.invokeMethod<String>(
        'saveBookmark',
        {'path': path},
      );
      return result;
    } on PlatformException catch (_) {
      return null;
    }
  }

  @override
  Future<BookmarkResolveResult?> resolveBookmark(String bookmarkData) async {
    try {
      final result = await _channel.invokeMethod<Map<Object?, Object?>>(
        'resolveBookmark',
        {'bookmarkData': bookmarkData},
      );
      if (result == null) {
        return null;
      }
      final path = result['path'] as String?;
      final isStale = result['isStale'] as bool? ?? false;
      if (path == null) {
        return null;
      }
      return BookmarkResolveResult(path: path, isStale: isStale);
    } on PlatformException catch (_) {
      return null;
    }
  }

  @override
  Future<void> stopAccess(String path) async {
    try {
      await _channel.invokeMethod<void>(
        'stopAccess',
        {'path': path},
      );
    } on PlatformException catch (_) {
      // Ignore errors
    }
  }

  @override
  Future<void> stopAllAccess() async {
    try {
      await _channel.invokeMethod<void>('stopAllAccess');
    } on PlatformException catch (_) {
      // Ignore errors
    }
  }

  @override
  void dispose() {
    // Resources are managed by the native side
  }
}
