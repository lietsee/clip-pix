import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

/// Service for persisting and restoring window position and size.
///
/// Uses the `window_manager` package for cross-platform support (Windows/macOS).
/// Window bounds are stored in a JSON file in the current directory.
///
/// Implements [WindowListener] to receive window resize/move events directly,
/// avoiding race conditions with [windowManager.getBounds()] during resize.
class WindowBoundsService
    with WidgetsBindingObserver
    implements WindowListener {
  WindowBoundsService() : _logger = Logger('WindowBoundsService');

  final Logger _logger;
  Timer? _debounce;
  late final String _configPath;
  Rect? _lastKnownBounds;

  static const _configFileName = 'clip_pix_settings.json';
  static const _debounceDuration = Duration(milliseconds: 200);

  /// Returns true if window bounds persistence is supported on this platform.
  bool get _isSupported => Platform.isWindows || Platform.isMacOS;

  void init() {
    if (!_isSupported) {
      debugPrint('[WindowBoundsService] init skipped; platform unsupported');
      return;
    }
    _configPath = _resolveConfigPath();
    _logger.info('Window bounds config path: $_configPath');
    debugPrint('[WindowBoundsService] init -> $_configPath');
    WidgetsBinding.instance.addObserver(this);
    windowManager.addListener(this);
    unawaited(windowManager.setPreventClose(true));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_restoreBounds());
    });
  }

  void dispose() {
    if (!_isSupported) {
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    windowManager.removeListener(this);
    _debounce?.cancel();
    _debounce = null;
    _logger.info('Window bounds service disposed');
    debugPrint('[WindowBoundsService] dispose');
  }

  // WindowListener implementation

  @override
  void onWindowResized() {
    _scheduleBoundsPersist();
  }

  @override
  void onWindowMoved() {
    _scheduleBoundsPersist();
  }

  @override
  void onWindowClose() {
    _logger.info('Window closing; persisting final bounds');
    debugPrint('[WindowBoundsService] onWindowClose -> persisting');
    _debounce?.cancel();

    // Persist bounds with timeout to avoid blocking window close indefinitely
    _persistCurrentBounds().then((_) {
      _logger.info('Bounds persisted, destroying window');
      debugPrint('[WindowBoundsService] bounds persisted, destroying window');
      windowManager.destroy();
    }).timeout(
      const Duration(seconds: 2),
      onTimeout: () {
        _logger.warning('Persist timed out, forcing destroy');
        debugPrint('[WindowBoundsService] persist timed out, forcing destroy');
        windowManager.destroy();
      },
    );
  }

  // Empty implementations for other WindowListener methods
  @override
  void onWindowFocus() {}

  @override
  void onWindowBlur() {}

  @override
  void onWindowMaximize() {}

  @override
  void onWindowUnmaximize() {}

  @override
  void onWindowMinimize() {}

  @override
  void onWindowRestore() {}

  @override
  void onWindowResize() {}

  @override
  void onWindowMove() {}

  @override
  void onWindowEnterFullScreen() {}

  @override
  void onWindowLeaveFullScreen() {}

  @override
  void onWindowEvent(String eventName) {}

  @override
  void onWindowDocked() {}

  @override
  void onWindowUndocked() {}

  void _scheduleBoundsPersist() {
    if (!_isSupported) {
      return;
    }
    _logger.info('Window bounds changed; scheduling persist');
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
        final success = await _applyBounds(desired);
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
    final rect = await _readWindowRect();
    if (rect == null) {
      // Fallback: use last known valid bounds
      if (_lastKnownBounds != null) {
        _logger.info('Using last known bounds: $_lastKnownBounds');
        debugPrint(
            '[WindowBoundsService] fallback to last known: $_lastKnownBounds');
        await _writeBoundsToFile(_lastKnownBounds!);
      } else {
        _logger.warning('No valid bounds available to persist');
        debugPrint('[WindowBoundsService] skip persist; no valid bounds');
      }
      return;
    }
    _lastKnownBounds = rect;
    await _writeBoundsToFile(rect);
  }

  Future<void> _writeBoundsToFile(Rect rect) async {
    final map = <String, double>{
      'left': rect.left,
      'top': rect.top,
      'width': rect.width,
      'height': rect.height,
    };
    _logger.info('Persisting window bounds: $map');
    final file = File(_configPath);
    try {
      final jsonString = const JsonEncoder.withIndent('  ').convert(map);
      await file.writeAsString(jsonString, flush: true);
      _logger.info('Persisted window bounds: $map');
      debugPrint('[WindowBoundsService] persisted bounds $map');
    } catch (error, stackTrace) {
      _logger.warning('Failed to persist window bounds', error, stackTrace);
    }
  }

  /// Read current window bounds using window_manager
  ///
  /// Uses [getPosition] and [getSize] separately instead of [getBounds] to avoid
  /// null reference errors that occur when getBounds() returns incomplete data.
  Future<Rect?> _readWindowRect() async {
    try {
      final position = await windowManager.getPosition();
      final size = await windowManager.getSize();

      _logger.fine('Read position: $position, size: $size');

      if (size.width <= 0 || size.height <= 0) {
        _logger.warning('Read rect has non-positive dimensions: $size');
        return null;
      }

      return Rect.fromLTWH(position.dx, position.dy, size.width, size.height);
    } catch (error) {
      _logger.warning('Failed to read window bounds: $error');
      return null;
    }
  }

  /// Apply bounds to window using window_manager
  Future<bool> _applyBounds(Rect rect) async {
    try {
      _logger.finer('Applying bounds: $rect');
      await windowManager.setBounds(rect);
      return true;
    } catch (error) {
      _logger.finer('Failed to apply bounds: $error');
      return false;
    }
  }

  String _resolveConfigPath() {
    final baseDir = Directory.current.path;
    return p.join(baseDir, _configFileName);
  }
}
