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
    // Persist any final bounds synchronously.
    unawaited(_persistCurrentBounds());
  }

  @override
  void didChangeMetrics() {
    if (!_isSupported) {
      return;
    }
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
      return;
    }
    final desired = Rect.fromLTWH(left, top, width, height);
    // Attempt several times in case the native window isn't ready yet.
    for (var attempt = 0; attempt < 5; attempt++) {
      if (_applyBounds(desired)) {
        _restoredBounds = desired;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  Future<void> _persistCurrentBounds() async {
    final rect = _readWindowRect();
    if (rect == null) {
      return;
    }
    if (_restoredBounds != null &&
        (rect.width <= 0 || rect.height <= 0)) {
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
      _restoredBounds = rect;
    } catch (error, stackTrace) {
      _logger.warning('Failed to persist window bounds', error, stackTrace);
    }
  }

  Rect? _readWindowRect() {
    final hwnd = GetActiveWindow();
    if (hwnd == 0) {
      return null;
    }
    final rectPointer = calloc<RECT>();
    try {
      if (GetWindowRect(hwnd, rectPointer) == 0) {
        return null;
      }
      final rect = rectPointer.ref;
      final width = rect.right - rect.left;
      final height = rect.bottom - rect.top;
      if (width <= 0 || height <= 0) {
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
    final hwnd = GetActiveWindow();
    if (hwnd == 0) {
      return false;
    }
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
    return result != 0;
  }
}
