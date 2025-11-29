import Cocoa
import FlutterMacOS

/// Flutter plugin for clipboard access on macOS.
///
/// Provides MethodChannel interface for:
/// - Reading change count (for polling)
/// - Reading images and text
/// - Writing images and text
public class ClipboardPlugin: NSObject, FlutterPlugin {

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "com.clip_pix/clipboard",
            binaryMessenger: registrar.messenger
        )
        let instance = ClipboardPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getChangeCount":
            result(NSPasteboard.general.changeCount)

        case "readImage":
            readImage(result: result)

        case "readText":
            readText(result: result)

        case "writeImage":
            if let args = call.arguments as? [String: Any],
               let data = args["data"] as? FlutterStandardTypedData {
                writeImage(data: data.data, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'data' argument", details: nil))
            }

        case "writeText":
            if let args = call.arguments as? [String: Any],
               let text = args["text"] as? String {
                writeText(text: text, result: result)
            } else {
                result(FlutterError(code: "INVALID_ARGS", message: "Missing 'text' argument", details: nil))
            }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Read Operations

    private func readImage(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general

        // Try PNG first (preferred format)
        if let data = pasteboard.data(forType: .png) {
            result(FlutterStandardTypedData(bytes: data))
            return
        }

        // Try TIFF and convert to PNG
        if let data = pasteboard.data(forType: .tiff),
           let image = NSImage(data: data),
           let pngData = image.pngData() {
            result(FlutterStandardTypedData(bytes: pngData))
            return
        }

        // No image found
        result(nil)
    }

    private func readText(result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general

        if let text = pasteboard.string(forType: .string) {
            result(text)
        } else {
            result(nil)
        }
    }

    // MARK: - Write Operations

    private func writeImage(data: Data, result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let success = pasteboard.setData(data, forType: .png)
        if success {
            result(true)
        } else {
            result(FlutterError(code: "WRITE_FAILED", message: "Failed to write image to clipboard", details: nil))
        }
    }

    private func writeText(text: String, result: @escaping FlutterResult) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let success = pasteboard.setString(text, forType: .string)
        if success {
            result(true)
        } else {
            result(FlutterError(code: "WRITE_FAILED", message: "Failed to write text to clipboard", details: nil))
        }
    }
}

// MARK: - NSImage Extension

extension NSImage {
    /// Converts NSImage to PNG data.
    func pngData() -> Data? {
        guard let tiffData = tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}
