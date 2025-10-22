import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

class WindowBoundsService with WidgetsBindingObserver {
  WindowBoundsService() : _logger = Logger('WindowBoundsService');

  final Logger _logger;
  Timer? _debounce;
  Rect? _restoredBounds;
  late final String _configPath;

  static const _configFileName = 'clip_pix_window.json';
  static const _debounceDuration = Duration(milliseconds: 200);

  bool get _isSupported => Platform.isWindows;

  void init() {
    if (!_isSupported) {
      return;
    }
    _configPath = _resolveConfigPath();
    _logger.fine('Window bounds config path: $_configPath');
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
    // Flush synchronously on shutdown.
    try {
      _persistCurrentBounds(sync: true);
    } catch (error, stackTrace) {
      _logger.warning('Failed to persist bounds during dispose', error, stackTrace);
    }
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

  Future<void> _restoreBounds() async {
    final file = File(_configPath);
    _logger.fine('Restoring window bounds from $_configPath');
    if (!await file.exists()) {
      _logger.fine('No window bounds file found');
      return;
    }
    try {
      final jsonString = await file.readAsString();
      _logger.finer('Bounds file contents: $jsonString');
      final data = jsonDecode(jsonString);
      if (data is! Map) {
        _logger.warning('Window bounds file had unexpected format');
        return;
      }
      final left = (data['left'] as num?)?.toDouble();
      final top = (data['top'] as num?)?.toDouble();
      final width = (data['width'] as num?)?.toDouble();
      final height = (data['height'] as num?)?.toDouble();
      if (left == null ||
          top == null ||
          width == null ||
          height == null ||
          width <= 0 ||
          height <= 0) {
        _logger.warning('Stored window bounds invalid: $data');
        return;
      }
      final desired = Rect.fromLTWH(left, top, width, height);
      _logger.fine('Attempting to restore window bounds: $desired');
      for (var attempt = 0; attempt < 5; attempt++) {
        if (_applyBounds(desired)) {
          _logger.fine('Bounds restored on attempt ${attempt + 1}');
          _restoredBounds = desired;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      _logger.warning('Failed to apply stored window bounds after retries');
    } catch (error, stackTrace) {
      _logger.warning('Failed to restore window bounds', error, stackTrace);
    }
  }

  Future<void> _persistCurrentBounds({bool sync = false}) async {
    final rect = _readWindowRect();
    if (rect == null) {
      _logger.finer('Skipping persist; could not read window rect');
      return;
    }
    final map = <String, double>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
    _logger.finer('Persisting bounds map: $map');
    final file = File(_configPath);
    try {
      final jsonString = const JsonEncoder.withIndent('  ').convert(map);
      if (sync) {
        file.writeAsStringSync(jsonString, flush: true);
      } else {
        await file.writeAsString(jsonString, flush: true);
      }
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
    _logger.finer('Reading window rect for handle 0x${hwnd.toRadixString(16)}');
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
      SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
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
    if (hwnd != 0) {
      return hwnd;
    }
    final fallback = GetForegroundWindow();
    if (fallback == 0) {
      _logger.finer('FindWindow and GetForegroundWindow both failed');
    }
    return fallback;
  }

  String _resolveConfigPath() {
    final buffer = wsalloc(MAX_PATH);
    try {
      final length = GetModuleFileName(nullptr, buffer, MAX_PATH);
      String exePath;
      if (length > 0) {
        exePath = buffer.toDartString();
      } else {
        exePath = Platform.resolvedExecutable;
      }
      final exeDir = p.dirname(exePath);
      return p.join(exeDir, _configFileName);
    } finally {
      calloc.free(buffer);
    }
  }
}
