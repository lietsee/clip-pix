/// Windows-specific clipboard writer implementation
///
/// Uses Win32 API for clipboard writing operations.
/// Supports PNG image and Unicode text formats.
library;

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import '../clipboard_service.dart';

/// Windows implementation of [ClipboardWriter].
///
/// Uses Win32 API to write clipboard content:
/// - `SetClipboardData()` with PNG format for images
/// - `SetClipboardData()` with CF_UNICODETEXT for text
class WindowsClipboardWriter implements ClipboardWriter {
  int? _pngClipboardFormat;

  @override
  Future<void> writeImage(Uint8List imageData) async {
    final format = _ensurePngFormat();
    const maxAttempts = 3;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final opened = OpenClipboard(NULL);
      if (opened != 0) {
        try {
          if (EmptyClipboard() == 0) {
            final error = HRESULT_FROM_WIN32(GetLastError());
            throw WindowsException(error);
          }
          final handle = _bytesToGlobal(imageData);
          final result = SetClipboardData(format, handle.address);
          if (result == 0) {
            final error = HRESULT_FROM_WIN32(GetLastError());
            GlobalFree(handle);
            throw WindowsException(error);
          }
          return;
        } finally {
          CloseClipboard();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final error = HRESULT_FROM_WIN32(GetLastError());
    throw WindowsException(error);
  }

  @override
  Future<void> writeText(String text) async {
    const maxAttempts = 3;

    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      final opened = OpenClipboard(NULL);
      if (opened != 0) {
        try {
          if (EmptyClipboard() == 0) {
            final error = HRESULT_FROM_WIN32(GetLastError());
            throw WindowsException(error);
          }
          final handle = _stringToGlobal(text);
          final result = SetClipboardData(CF_UNICODETEXT, handle.address);
          if (result == 0) {
            final error = HRESULT_FROM_WIN32(GetLastError());
            GlobalFree(handle);
            throw WindowsException(error);
          }
          return;
        } finally {
          CloseClipboard();
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    final error = HRESULT_FROM_WIN32(GetLastError());
    throw WindowsException(error);
  }

  @override
  void dispose() {
    // No persistent resources to release
  }

  /// Allocate global memory and copy bytes into it
  ffi.Pointer<ffi.Void> _bytesToGlobal(Uint8List bytes) {
    final handle = GlobalAlloc(GMEM_MOVEABLE, bytes.length).cast<ffi.Void>();
    if (handle.address == 0) {
      final error = HRESULT_FROM_WIN32(GetLastError());
      throw WindowsException(error);
    }
    final pointer = GlobalLock(handle).cast<ffi.Uint8>();
    if (pointer.address == 0) {
      final error = HRESULT_FROM_WIN32(GetLastError());
      GlobalFree(handle);
      throw WindowsException(error);
    }
    final buffer = pointer.asTypedList(bytes.length);
    buffer.setAll(0, bytes);
    GlobalUnlock(handle);
    return handle;
  }

  /// Allocate global memory and copy UTF-16 string into it
  ffi.Pointer<ffi.Void> _stringToGlobal(String text) {
    final nativeString = text.toNativeUtf16();
    final charCount = text.length + 1; // Include null terminator
    final byteLength = charCount * 2; // UTF-16 is 2 bytes per character
    final handle = GlobalAlloc(GMEM_MOVEABLE, byteLength).cast<ffi.Void>();
    if (handle.address == 0) {
      calloc.free(nativeString);
      final error = HRESULT_FROM_WIN32(GetLastError());
      throw WindowsException(error);
    }
    final pointer = GlobalLock(handle).cast<ffi.Uint16>();
    if (pointer.address == 0) {
      calloc.free(nativeString);
      GlobalFree(handle);
      final error = HRESULT_FROM_WIN32(GetLastError());
      throw WindowsException(error);
    }
    // Copy the UTF-16 string data using asTypedList
    final buffer = pointer.asTypedList(charCount);
    final sourceBuffer = nativeString.cast<ffi.Uint16>().asTypedList(charCount);
    buffer.setAll(0, sourceBuffer);
    GlobalUnlock(handle);
    calloc.free(nativeString);
    return handle;
  }

  /// Register and cache PNG clipboard format
  int _ensurePngFormat() {
    final cached = _pngClipboardFormat;
    if (cached != null) {
      return cached;
    }
    final formatName = 'PNG'.toNativeUtf16();
    try {
      final format = RegisterClipboardFormat(formatName);
      if (format == 0) {
        final error = HRESULT_FROM_WIN32(GetLastError());
        throw WindowsException(error);
      }
      _pngClipboardFormat = format;
      return format;
    } finally {
      calloc.free(formatName);
    }
  }
}
