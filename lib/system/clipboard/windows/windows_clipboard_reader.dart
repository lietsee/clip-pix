/// Windows-specific clipboard reader implementation
///
/// Uses Win32 API for clipboard reading operations.
/// Supports DIB, DIBV5, PNG, and Unicode text formats.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:win32/win32.dart';

import '../../../data/models/image_source_type.dart';
import '../clipboard_service.dart';

/// Windows implementation of [ClipboardReader].
///
/// Uses Win32 API to read clipboard content:
/// - `GetClipboardSequenceNumber()` for change detection
/// - `GetClipboardData()` with CF_DIBV5, CF_DIB, PNG, CF_UNICODETEXT formats
class WindowsClipboardReader implements ClipboardReader {
  int? _pngClipboardFormat;

  @override
  int getChangeCount() {
    return GetClipboardSequenceNumber();
  }

  @override
  Future<ClipboardContent?> read() async {
    final open = OpenClipboard(NULL);
    if (open == 0) {
      return null;
    }
    try {
      // Try DIBV5 first (best quality with alpha)
      final dibV5Image = _readDibV5FromClipboardLocked();
      if (dibV5Image != null) {
        return ClipboardContent(
          imageData: dibV5Image,
          sourceType: ImageSourceType.local,
        );
      }

      // Try PNG format
      final pngImage = _readPngFromClipboardLocked();
      if (pngImage != null) {
        return ClipboardContent(
          imageData: pngImage,
          sourceType: ImageSourceType.local,
        );
      }

      // Try DIB format
      final dibImage = _readDibFromClipboardLocked();
      if (dibImage != null) {
        return ClipboardContent(
          imageData: dibImage,
          sourceType: ImageSourceType.local,
        );
      }

      // Try Unicode text
      final text = _readUnicodeTextFromClipboardLocked();
      if (text != null && text.isNotEmpty) {
        return ClipboardContent(text: text);
      }

      return null;
    } finally {
      CloseClipboard();
    }
  }

  @override
  void dispose() {
    // No persistent resources to release
  }

  /// Read DIBV5 format image from clipboard (best quality with alpha support)
  Uint8List? _readDibV5FromClipboardLocked() {
    final handleValue = GetClipboardData(CF_DIBV5);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    try {
      final size = GlobalSize(handle);
      if (size <= 0) {
        return null;
      }
      final data = rawPointer.cast<ffi.Uint8>().asTypedList(size);
      return _convertDibV5ToPng(data);
    } finally {
      GlobalUnlock(handle);
    }
  }

  /// Read PNG format image from clipboard
  Uint8List? _readPngFromClipboardLocked() {
    final format = _ensurePngFormat();
    if (format == 0) {
      return null;
    }
    final handleValue = GetClipboardData(format);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    final size = GlobalSize(handle);
    if (size <= 0) {
      GlobalUnlock(handle);
      return null;
    }
    final pointer = rawPointer.cast<ffi.Uint8>();
    final data = pointer.asTypedList(size);
    final bytes = Uint8List.fromList(data);
    GlobalUnlock(handle);
    return bytes;
  }

  /// Read DIB format image from clipboard
  Uint8List? _readDibFromClipboardLocked() {
    final handleValue = GetClipboardData(CF_DIB);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    try {
      final size = GlobalSize(handle);
      if (size <= 0) {
        return null;
      }
      final data = rawPointer.cast<ffi.Uint8>().asTypedList(size);
      final bytes = Uint8List.fromList(data);
      return _convertDibToPng(bytes);
    } finally {
      GlobalUnlock(handle);
    }
  }

  /// Read Unicode text from clipboard
  String? _readUnicodeTextFromClipboardLocked() {
    final handleValue = GetClipboardData(CF_UNICODETEXT);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    final pointer = rawPointer.cast<Utf16>();
    final text = pointer.toDartString();
    GlobalUnlock(handle);
    return text;
  }

  /// Convert DIBV5 format to PNG
  Uint8List? _convertDibV5ToPng(Uint8List dibBytes) {
    const int biAlphabitfields = 6;
    if (dibBytes.length < 124) {
      return null;
    }
    final byteData = ByteData.view(dibBytes.buffer);
    final headerSize = byteData.getUint32(0, Endian.little);
    if (headerSize < 124 || headerSize > dibBytes.length) {
      return null;
    }
    final width = byteData.getInt32(4, Endian.little);
    final heightRaw = byteData.getInt32(8, Endian.little);
    final planes = byteData.getUint16(12, Endian.little);
    final bitCount = byteData.getUint16(14, Endian.little);
    final compression = byteData.getUint32(16, Endian.little);
    var imageSize = byteData.getUint32(20, Endian.little);
    final redMask = byteData.getUint32(40, Endian.little);
    final greenMask = byteData.getUint32(44, Endian.little);
    final blueMask = byteData.getUint32(48, Endian.little);
    final alphaMask = byteData.getUint32(52, Endian.little);
    final pixelDataOffset = byteData.getUint32(96, Endian.little);

    if (planes != 1) {
      return null;
    }
    if (compression != biAlphabitfields) {
      return null;
    }
    if (bitCount != 32) {
      return null;
    }

    final widthAbs = width.abs();
    final heightAbs = heightRaw.abs();
    if (widthAbs == 0 || heightAbs == 0) {
      return null;
    }

    final stride = widthAbs * 4;
    if (imageSize == 0) {
      imageSize = stride * heightAbs;
    }
    final pixelOffset = headerSize + pixelDataOffset;
    if (pixelOffset + imageSize > dibBytes.length) {
      return null;
    }

    final pixels = dibBytes.sublist(pixelOffset, pixelOffset + imageSize);
    final output = Uint8List(widthAbs * heightAbs * 4);
    final bottomUp = heightRaw > 0;

    for (var y = 0; y < heightAbs; y++) {
      final srcY = bottomUp ? heightAbs - 1 - y : y;
      final srcRowStart = srcY * stride;
      final dstRowStart = y * widthAbs * 4;
      for (var x = 0; x < widthAbs; x++) {
        final srcIndex = srcRowStart + x * 4;
        if (srcIndex + 4 > pixels.length) {
          return null;
        }
        final pixel = ByteData.sublistView(pixels, srcIndex, srcIndex + 4)
            .getUint32(0, Endian.little);
        final red = _applyMask(pixel, redMask);
        final green = _applyMask(pixel, greenMask);
        final blue = _applyMask(pixel, blueMask);
        final alpha = alphaMask == 0 ? 0xFF : _applyMask(pixel, alphaMask);
        final dstIndex = dstRowStart + x * 4;
        output[dstIndex] = red;
        output[dstIndex + 1] = green;
        output[dstIndex + 2] = blue;
        output[dstIndex + 3] = alpha;
      }
    }

    final image = img.Image.fromBytes(
      width: widthAbs,
      height: heightAbs,
      bytes: output.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  int _applyMask(int pixel, int mask) {
    if (mask == 0) {
      return 0;
    }
    var m = mask;
    var shift = 0;
    while ((m & 1) == 0) {
      m >>= 1;
      shift++;
    }
    final component = (pixel & mask) >> shift;
    final bits = _maskBitCount(mask);
    if (bits >= 8) {
      return component & 0xFF;
    }
    return ((component * 255) ~/ ((1 << bits) - 1)) & 0xFF;
  }

  int _maskBitCount(int mask) {
    var m = mask;
    var count = 0;
    while (m != 0) {
      if ((m & 1) == 1) {
        count++;
      }
      m >>= 1;
    }
    return count;
  }

  /// Convert DIB format to PNG
  Uint8List? _convertDibToPng(Uint8List dibBytes) {
    const int biRgb = 0;
    const int biBitfields = 3;

    if (dibBytes.length < 40) {
      return null;
    }
    final byteData = ByteData.view(dibBytes.buffer);
    final headerSize = byteData.getUint32(0, Endian.little);
    if (headerSize < 40 || headerSize > dibBytes.length) {
      return null;
    }

    final width = byteData.getInt32(4, Endian.little);
    final heightRaw = byteData.getInt32(8, Endian.little);
    final planes = byteData.getUint16(12, Endian.little);
    final bitCount = byteData.getUint16(14, Endian.little);
    final compression = byteData.getUint32(16, Endian.little);
    var imageSize = byteData.getUint32(20, Endian.little);

    if (planes != 1) {
      return null;
    }
    if (bitCount != 24 && bitCount != 32) {
      return null;
    }
    if (compression != biRgb && compression != biBitfields) {
      return null;
    }

    final widthAbs = width.abs();
    final heightAbs = heightRaw.abs();
    if (widthAbs == 0 || heightAbs == 0) {
      return null;
    }

    final bytesPerPixel = bitCount ~/ 8;
    final stride = ((widthAbs * bytesPerPixel + 3) ~/ 4) * 4;
    final pixelOffset = headerSize;
    if (imageSize == 0) {
      imageSize = stride * heightAbs;
    }
    if (pixelOffset + imageSize > dibBytes.length) {
      return null;
    }

    final pixels = dibBytes.sublist(pixelOffset, pixelOffset + imageSize);
    final output = Uint8List(widthAbs * heightAbs * 4);
    final bottomUp = heightRaw > 0;

    for (var y = 0; y < heightAbs; y++) {
      final srcY = bottomUp ? heightAbs - 1 - y : y;
      final srcRowStart = srcY * stride;
      final dstRowStart = y * widthAbs * 4;
      for (var x = 0; x < widthAbs; x++) {
        final srcIndex = srcRowStart + x * bytesPerPixel;
        if (srcIndex + bytesPerPixel > pixels.length) {
          return null;
        }
        final blue = pixels[srcIndex];
        final green = pixels[srcIndex + 1];
        final red = pixels[srcIndex + 2];
        final alpha = bytesPerPixel == 4 ? pixels[srcIndex + 3] : 0xFF;
        final dstIndex = dstRowStart + x * 4;
        output[dstIndex] = red;
        output[dstIndex + 1] = green;
        output[dstIndex + 2] = blue;
        output[dstIndex + 3] = alpha;
      }
    }

    final image = img.Image.fromBytes(
      width: widthAbs,
      height: heightAbs,
      bytes: output.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  /// Register and cache PNG clipboard format
  int _ensurePngFormat() {
    final cached = _pngClipboardFormat;
    if (cached != null) {
      return cached;
    }
    final name = 'PNG'.toNativeUtf16();
    try {
      final format = RegisterClipboardFormat(name);
      if (format != 0) {
        _pngClipboardFormat = format;
      }
      return format;
    } finally {
      calloc.free(name);
    }
  }
}
