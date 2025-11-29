import Cocoa
import FlutterMacOS

/// Flutter plugin for Security-Scoped Bookmarks on macOS.
///
/// Provides MethodChannel interface for:
/// - Creating security-scoped bookmarks from folder paths
/// - Resolving bookmarks to restore access after app restart
/// - Managing security-scoped resource access
public class BookmarkPlugin: NSObject, FlutterPlugin {

    /// Currently accessed security-scoped URLs (need to call stopAccessingSecurityScopedResource on cleanup)
    private var accessedURLs: [String: URL] = [:]

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.clip_pix/bookmark",
            binaryMessenger: registrar.messenger
        )
        let instance = BookmarkPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "saveBookmark":
            if let args = call.arguments as? [String: Any],
               let path = args["path"] as? String {
                saveBookmark(path: path, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path' argument", details: nil))
            }

        case "resolveBookmark":
            if let args = call.arguments as? [String: Any],
               let bookmarkData = args["bookmarkData"] as? String {
                resolveBookmark(bookmarkData: bookmarkData, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'bookmarkData' argument", details: nil))
            }

        case "stopAccess":
            if let args = call.arguments as? [String: Any],
               let path = args["path"] as? String {
                stopAccess(path: path, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'path' argument", details: nil))
            }

        case "stopAllAccess":
            stopAllAccess(result: result)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Bookmark Operations

    /// Creates a security-scoped bookmark from a folder path.
    /// Returns Base64-encoded bookmark data.
    private func saveBookmark(path: String, result: @escaping FlutterResult) {
        let url = URL(fileURLWithPath: path)

        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let base64String = bookmarkData.base64EncodedString()
            result(base64String)
        } catch {
            result(FlutterError(
                code: "BOOKMARK_FAILED",
                message: "Failed to create bookmark: \(error.localizedDescription)",
                details: nil
            ))
        }
    }

    /// Resolves a security-scoped bookmark and starts accessing the resource.
    /// Returns the resolved path, or error if bookmark is invalid/stale.
    private func resolveBookmark(bookmarkData: String, result: @escaping FlutterResult) {
        guard let data = Data(base64Encoded: bookmarkData) else {
            result(FlutterError(
                code: "INVALID_BOOKMARK",
                message: "Invalid Base64 bookmark data",
                details: nil
            ))
            return
        }

        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                // Bookmark is stale but URL might still be valid
                // Caller should re-save the bookmark
                result([
                    "path": url.path,
                    "isStale": true
                ])
                return
            }

            // Start accessing the security-scoped resource
            let success = url.startAccessingSecurityScopedResource()
            if success {
                accessedURLs[url.path] = url
                result([
                    "path": url.path,
                    "isStale": false
                ])
            } else {
                result(FlutterError(
                    code: "ACCESS_DENIED",
                    message: "Failed to start accessing security-scoped resource",
                    details: nil
                ))
            }
        } catch {
            result(FlutterError(
                code: "RESOLVE_FAILED",
                message: "Failed to resolve bookmark: \(error.localizedDescription)",
                details: nil
            ))
        }
    }

    /// Stops accessing a security-scoped resource.
    private func stopAccess(path: String, result: @escaping FlutterResult) {
        if let url = accessedURLs.removeValue(forKey: path) {
            url.stopAccessingSecurityScopedResource()
        }
        result(nil)
    }

    /// Stops accessing all security-scoped resources.
    private func stopAllAccess(result: @escaping FlutterResult) {
        for (_, url) in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs.removeAll()
        result(nil)
    }
}
