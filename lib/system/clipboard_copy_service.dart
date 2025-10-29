import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

import '../data/models/image_item.dart';
import '../data/models/text_content_item.dart';
import 'clipboard_monitor.dart';

class ClipboardCopyService {
  ClipboardCopyService({
    Duration guardTtl = const Duration(seconds: 2),
    Duration guardClearDelay = const Duration(seconds: 1),
    Logger? logger,
  })  : _guardTtl = guardTtl,
        _guardClearDelay = guardClearDelay,
        _logger = logger ?? Logger('ClipboardCopyService');

  final Duration _guardTtl;
  final Duration _guardClearDelay;
  final Logger _logger;

  ClipboardMonitorGuard? _guard;
  final Queue<ImageItem> _queue = Queue<ImageItem>();
  bool _isProcessing = false;
  Timer? _guardClearTimer;
  int? _pngClipboardFormat;

  void registerMonitor(ClipboardMonitorGuard guard) {
    _guard = guard;
  }

  Future<void> copyImage(ImageItem item) async {
    _queue.addLast(item);
    await _processQueue();
  }

  Future<void> copyText(TextContentItem item) async {
    final file = File(item.filePath);
    if (!await file.exists()) {
      throw FileSystemException('Text file not found', item.filePath);
    }

    final String text = await file.readAsString();
    _issueGuardToken();

    try {
      await _setClipboardText(text);
      _logger.info('Clipboard text copied: ${item.filePath}');
    } finally {
      _scheduleGuardClear();
    }
  }

  Future<void> _processQueue() async {
    if (_isProcessing) {
      return;
    }
    _isProcessing = true;

    while (_queue.isNotEmpty) {
      final item = _queue.removeFirst();
      try {
        await _performCopy(item);
      } catch (error, stackTrace) {
        _logger.severe('Failed to copy image to clipboard', error, stackTrace);
        rethrow;
      }
    }

    _isProcessing = false;
  }

  Future<void> _performCopy(ImageItem item) async {
    final file = File(item.filePath);
    if (!await file.exists()) {
      throw FileSystemException('Image file not found', item.filePath);
    }

    final Uint8List bytes = await file.readAsBytes();
    _issueGuardToken();

    try {
      await _setClipboardImage(bytes);
      _logger.info('Clipboard image copied: ${item.filePath}');
    } finally {
      _scheduleGuardClear();
    }
  }

  String _issueGuardToken() {
    final guard = _guard;
    final token = _generateToken();
    if (guard != null) {
      guard.setGuardToken(token, _guardTtl);
    } else {
      _logger.fine('Clipboard guard not registered');
    }
    return token;
  }

  void _scheduleGuardClear() {
    _guardClearTimer?.cancel();
    _guardClearTimer = Timer(_guardClearDelay, () {
      final guard = _guard;
      guard?.clearGuardToken();
    });
  }

  Future<void> _setClipboardImage(Uint8List bytes) async {
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
          final handle = _bytesToGlobal(bytes);
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

  Future<void> _setClipboardText(String text) async {
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

  String _generateToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(values);
  }
}
