import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Service for persisting and restoring window position and size.
///
/// Uses Win32 API directly for reliable window bounds on Windows.
/// Window bounds are stored in a JSON file in the current directory.
///
/// Uses [WidgetsBindingObserver.didChangeMetrics] to detect window changes.
class WindowBoundsService with WidgetsBindingObserver {
  WindowBoundsService() : _logger = Logger('WindowBoundsService');

  final Logger _logger;
  Timer? _debounce;
  late final String _configPath;
  Rect? _lastKnownBounds;
  Rect? _pendingBounds; // Cached bounds from didChangeMetrics callback

  static const _configFileName = 'clip_pix_settings.json';
  static const _debounceDuration = Duration(milliseconds: 200);

  /// Returns true if window bounds persistence is supported on this platform.
  /// Currently only Windows is supported (uses Win32 API directly).
  bool get _isSupported => Platform.isWindows;

  void init() {
    if (!_isSupported) {
      debugPrint('[WindowBoundsService] init skipped; platform unsupported');
      return;
    }
    _configPath = _resolveConfigPath();
    _logger.info('Window bounds config path: $_configPath');
    debugPrint('[WindowBoundsService] init -> $_configPath');
    WidgetsBinding.instance.addObserver(this);
    // Note: WindowListener is not used because it doesn't work on Windows
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
    _logger.info('Window bounds service disposed');
    debugPrint('[WindowBoundsService] dispose');
  }

  // WidgetsBindingObserver implementation

  /// Called when window metrics change (size, position, etc.)
  /// This is more reliable than WindowListener on Windows.
  @override
  void didChangeMetrics() {
    debugPrint('[WindowBoundsService] didChangeMetrics');
    // Read bounds immediately during callback
    _readAndCacheBounds();
    _scheduleBoundsPersist();
  }

  /// Read bounds immediately and cache for later persistence.
  void _readAndCacheBounds() {
    final rect = _readWindowRect();
    if (rect != null) {
      _pendingBounds = rect;
      _lastKnownBounds = rect;
      debugPrint('[WindowBoundsService] cached: $rect');
    }
  }

  void _scheduleBoundsPersist() {
    if (!_isSupported) {
      return;
    }
    _logger.info('Window bounds changed; scheduling persist');
    debugPrint('[WindowBoundsService] scheduling persist');
    _debounce?.cancel();
    _debounce = Timer(_debounceDuration, () {
      _debounce = null;
      unawaited(_persistCurrentBounds());
    });
  }

  Future<void> _restoreBounds() async {
    final file = File(_configPath);
    _logger.info('Restoring window bounds from $_configPath');
    debugPrint('[WindowBoundsService] restore from $_configPath');
    if (!await file.exists()) {
      _logger.info('No window bounds file found');
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
      // Note: Don't set _lastKnownBounds here - it should only be updated
      // when we successfully read the current window bounds after resize/move.
      _logger.info('Attempting to restore window bounds: $desired');
      for (var attempt = 0; attempt < 5; attempt++) {
        debugPrint(
            '[WindowBoundsService] apply attempt ${attempt + 1} -> $desired');
        final success = _applyBounds(desired);
        if (success) {
          _logger.info('Bounds restored on attempt ${attempt + 1}');
          debugPrint('[WindowBoundsService] applied bounds');
          return;
        }
        debugPrint('[WindowBoundsService] apply attempt ${attempt + 1} failed');
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
      _logger.warning('Failed to apply stored window bounds after retries');
    } catch (error, stackTrace) {
      _logger.warning('Failed to restore window bounds', error, stackTrace);
    }
  }

  Future<void> _persistCurrentBounds() async {
    // Use cached bounds (read during didChangeMetrics callback is more reliable)
    final rect = _pendingBounds ?? _lastKnownBounds;
    if (rect == null) {
      _logger.warning('No valid bounds available to persist');
      debugPrint('[WindowBoundsService] skip persist; no valid bounds');
      return;
    }
    await _writeBoundsToFile(rect);
    _pendingBounds = null; // Clear after writing
  }

  Future<void> _writeBoundsToFile(Rect rect) async {
    final map = <String, double>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
    _logger.info('Persisting window bounds: $map');
    debugPrint('[WindowBoundsService] persisting: $map');
    final file = File(_configPath);
    try {
      final jsonString = const JsonEncoder.withIndent('  ').convert(map);
      await file.writeAsString(jsonString, flush: true);
      _logger.info('Persisted window bounds: $map');
    } catch (error, stackTrace) {
      _logger.warning('Failed to persist window bounds', error, stackTrace);
    }
  }

  /// Read current window bounds using Win32 API
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
        _logger.finer(
            'GetWindowRect failed for handle 0x${hwnd.toRadixString(16)}');
        return null;
      }
      final rect = rectPointer.ref;
      final width = rect.right - rect.left;
      final height = rect.bottom - rect.top;
      if (width <= 0 || height <= 0) {
        _logger.finer('Read rect has non-positive dimensions: $rect');
        return null;
      }
      final result = Rect.fromLTWH(
        rect.left.toDouble(),
        rect.top.toDouble(),
        width.toDouble(),
        height.toDouble(),
      );
      debugPrint('[WindowBoundsService] read: $result');
      return result;
    } finally {
      calloc.free(rectPointer);
    }
  }

  /// Apply bounds to window using Win32 API
  bool _applyBounds(Rect rect) {
    final hwnd = _resolveWindowHandle();
    if (hwnd == 0) {
      _logger.finer('Cannot apply bounds; window handle missing');
      debugPrint('[WindowBoundsService] apply bounds failed; hwnd=0');
      return false;
    }
    _logger
        .finer('Applying bounds to handle 0x${hwnd.toRadixString(16)}: $rect');
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
    final hwnd = FindWindow(className, nullptr.cast<Utf16>());
    calloc.free(className);
    if (hwnd != 0) {
      debugPrint(
          '[WindowBoundsService] found hwnd via class: 0x${hwnd.toRadixString(16)}');
      return hwnd;
    }
    final fallback = GetForegroundWindow();
    if (fallback == 0) {
      _logger.finer('FindWindow and GetForegroundWindow both failed');
      debugPrint('[WindowBoundsService] hwnd fallback failed');
    }
    debugPrint(
        '[WindowBoundsService] fallback hwnd 0x${fallback.toRadixString(16)}');
    return fallback;
  }

  String _resolveConfigPath() {
    final baseDir = Directory.current.path;
    return p.join(baseDir, _configFileName);
  }
}
