import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:hive/hive.dart';
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

class WindowBoundsService with WidgetsBindingObserver {
  WindowBoundsService(this._box) : _logger = Logger('WindowBoundsService');

  final Box<dynamic> _box;
  final Logger _logger;
  Timer? _debounce;
  Rect? _restoredBounds;

  static const _storageKey = 'window_bounds';
  static const _debounceDuration = Duration(milliseconds: 200);

  void init() {
    if (!_isSupported) {
      return;
    }
    _logger.fine('Initializing window bounds service');
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreBounds());
    });
  }

  void dispose() {
    if (!_isSupported) {
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _debounce = null;
    _logger.fine('Disposing window bounds service');
    // Persist any final bounds synchronously.
    unawaited(_persistCurrentBounds());
  }

  @override
  void didChangeMetrics() {
    if (!_isSupported) {
      return;
    }
    _logger.finer('Metrics changed; scheduling bounds persist');
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      _debounce = null;
      unawaited(_persistCurrentBounds());
    });
  }

  bool get _isSupported => Platform.isWindows;

  Future<void> _restoreBounds() async {
    final stored = _box.get(_storageKey);
    if (stored is! Map) {
      _logger.fine('No stored window bounds');
      return;
    }
    final left = (stored['left'] as num?)?.toDouble();
    final top = (stored['top'] as num?)?.toDouble();
    final width = (stored['width'] as num?)?.toDouble();
    final height = (stored['height'] as num?)?.toDouble();
    if (left == null ||
        top == null ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      _logger.warning('Stored bounds invalid: $stored');
      return;
    }
    final desired = Rect.fromLTWH(left, top, width, height);
    _logger.fine('Attempting to restore window bounds: $desired');
    // Attempt several times in case the native window isn't ready yet.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_applyBounds(desired)) {
        _logger.fine('Bounds restored on attempt ${attempt + 1}');
        _restoredBounds = desired;
        return;
      }
      _logger.finer('Bounds restore attempt ${attempt + 1} failed');
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    _logger.warning('Failed to apply stored bounds after retries');
  }

  Future<void> _persistCurrentBounds() async {
    final rect = _readWindowRect();
    if (rect == null) {
      _logger.finer('Skipping persist; unable to read window rect');
      return;
    }
    if (_restoredBounds != null &&
        (rect.width <= 0 || rect.height <= 0)) {
      _logger.warning('Skipping persist due to zero-sized rect: $rect');
      return;
    }
    final map = <String, double>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
    try {
      await _box.put(_storageKey, map);
      _logger.fine('Persisted window bounds: $map');
      _restoredBounds = rect;
    } catch (error, stackTrace) {
      _logger.warning('Failed to persist window bounds', error, stackTrace);
    }
  }

  Rect? _readWindowRect() {
    final hwnd = _resolveWindowHandle();
    if (hwnd == 0) {
      _logger.finer('Window handle not available for bounds read');
      return null;
    }
    _logger.finer('Reading window rect for handle: 0x${hwnd.toRadixString(16)}');
    final rectPointer = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rectPointer) == 0) {
        _logger.finer('GetWindowRect failed for handle 0x${hwnd.toRadixString(16)}');
        return null;
      }
      final rect = rectPointer.ref;
      final width = rect.right - rect.left;
      final height = rect.bottom - rect.top;
      if (width <= 0 || height <= 0) {
        _logger.finer('Read rect has non-positive dimensions: $rect');
        return null;
      }
      return Rect.fromLTWH(
        rect.left.toDouble(),
        rect.top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      );
    } finally {
      calloc.free(rectPointer);
    }
  }

  bool _applyBounds(Rect rect) {
    final hwnd = _resolveWindowHandle();
    if (hwnd == 0) {
      _logger.finer('Cannot apply bounds; window handle missing');
      return false;
    }
    _logger.finer('Applying bounds to handle 0x${hwnd.toRadixString(16)}: $rect');
    final width = rect.width.round();
    final height = rect.height.round();
    final left = rect.left.round();
    final top = rect.top.round();
    final result = SetWindowPos(
      hwnd,
      NULL,
      left,
      top,
      width,
      height,
      SWP_NOZORDER | SWP_NOACTIVATE,
    );
    if (result == 0) {
      _logger.finer('SetWindowPos failed with error ${GetLastError()}');
    }
    return result != 0;
  }

  int _resolveWindowHandle() {
    final className = TEXT('FLUTTER_RUNNER_WIN32_WINDOW');
    final hwnd = FindWindow(className, nullptr);
    calloc.free(className);
    if (hwnd == 0) {
      _logger.finer('FindWindow failed for FLUTTER_RUNNER_WIN32_WINDOW');
    }
    return hwnd;
  }
}
