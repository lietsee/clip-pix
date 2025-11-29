/// Security-Scoped Bookmarks service for macOS folder access persistence.
///
/// On macOS, sandboxed apps lose access to user-selected folders after restart.
/// This service provides an abstraction for creating and resolving security-scoped
/// bookmarks to persist folder access across app restarts.
library;

import 'dart:io';

import 'macos_bookmark_service.dart';

/// Result of resolving a security-scoped bookmark.
class BookmarkResolveResult {
  const BookmarkResolveResult({
    required this.path,
    required this.isStale,
  });

  /// The resolved path.
  final String path;

  /// Whether the bookmark is stale (folder may have been moved/renamed).
  /// If true, the bookmark should be re-saved.
  final bool isStale;
}

/// Abstract interface for bookmark services.
///
/// Platform-specific implementations:
/// - macOS: [MacOSBookmarkService] (Security-Scoped Bookmarks via MethodChannel)
/// - Windows: Not needed (no sandbox restrictions)
abstract class BookmarkService {
  /// Creates a security-scoped bookmark for the given path.
  ///
  /// Returns Base64-encoded bookmark data, or null if creation fails.
  Future<String?> saveBookmark(String path);

  /// Resolves a security-scoped bookmark and starts accessing the resource.
  ///
  /// Returns the resolved path and stale status, or null if resolution fails.
  /// After successful resolution, the app has access to the folder until
  /// [stopAccess] is called or the app terminates.
  Future<BookmarkResolveResult?> resolveBookmark(String bookmarkData);

  /// Stops accessing a security-scoped resource.
  ///
  /// Should be called when the folder is no longer needed to release resources.
  Future<void> stopAccess(String path);

  /// Stops accessing all security-scoped resources.
  Future<void> stopAllAccess();

  /// Releases resources.
  void dispose();
}

/// Factory for creating platform-specific bookmark services.
class BookmarkServiceFactory {
  /// Creates the appropriate bookmark service for the current platform.
  ///
  /// Returns [MacOSBookmarkService] on macOS, or a no-op implementation on other platforms.
  static BookmarkService create() {
    if (Platform.isMacOS) {
      return MacOSBookmarkService();
    }
    return _NoOpBookmarkService();
  }
}

/// No-op implementation for platforms that don't need bookmark services.
class _NoOpBookmarkService implements BookmarkService {
  @override
  Future<String?> saveBookmark(String path) async => null;

  @override
  Future<BookmarkResolveResult?> resolveBookmark(String bookmarkData) async =>
      null;

  @override
  Future<void> stopAccess(String path) async {}

  @override
  Future<void> stopAllAccess() async {}

  @override
  void dispose() {}
}
