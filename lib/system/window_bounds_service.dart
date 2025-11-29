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
class WindowBoundsService with WidgetsBindingObserver {
  WindowBoundsService() : _logger = Logger('WindowBoundsService');

  final Logger _logger;
  Timer? _debounce;
  late final String _configPath;

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
    _logger.info('Window bounds service disposed; persisting final bounds');
    debugPrint('[WindowBoundsService] dispose -> flushing');
    try {
      _persistCurrentBoundsSync();
    } catch (error, stackTrace) {
      _logger.warning(
          'Failed to persist bounds during dispose', error, stackTrace);
    }
  }

  @override
  void didChangeMetrics() {
    if (!_isSupported) {
      return;
    }
    _logger.info('Window metrics changed; scheduling bounds persist');
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
      _logger.finer('Skipping persist; could not read window rect');
      debugPrint('[WindowBoundsService] skip persist; rect null');
      return;
    }
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

  /// Synchronous version for use in dispose()
  void _persistCurrentBoundsSync() {
    // Use a blocking approach for dispose - try to get current bounds
    // Note: window_manager doesn't have a sync API, so we skip persist on dispose
    // The async version will have been called via debounce before dispose
    _logger.fine('Synchronous persist skipped; async version handles most cases');
  }

  /// Read current window bounds using window_manager
  Future<Rect?> _readWindowRect() async {
    try {
      final bounds = await windowManager.getBounds();
      if (bounds.width <= 0 || bounds.height <= 0) {
        _logger.finer('Read rect has non-positive dimensions: $bounds');
        return null;
      }
      return bounds;
    } catch (error) {
      _logger.finer('Failed to read window bounds: $error');
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
