import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'window/window_bounds_provider.dart';

/// Service for persisting and restoring window position and size.
///
/// Uses platform-specific providers:
/// - Windows: Win32 API (via WindowBoundsProvider)
/// - macOS: window_manager package (via WindowBoundsProvider)
///
/// Window bounds are stored in a JSON file in the current directory.
/// Uses [WidgetsBindingObserver.didChangeMetrics] to detect window changes.
class WindowBoundsService with WidgetsBindingObserver {
  WindowBoundsService() : _logger = Logger('WindowBoundsService');

  final Logger _logger;
  Timer? _debounce;
  late final String _configPath;
  Rect? _lastKnownBounds;
  Rect? _pendingBounds; // Cached bounds from didChangeMetrics callback
  WindowBoundsProvider? _provider;

  static const _configFileName = 'clip_pix_settings.json';
  static const _debounceDuration = Duration(milliseconds: 200);

  /// Returns true if window bounds persistence is supported on this platform.
  bool get _isSupported => Platform.isWindows;

  void init() {
    if (!_isSupported) {
      debugPrint('[WindowBoundsService] init skipped; platform unsupported');
      return;
    }

    _provider = createWindowBoundsProvider();
    if (_provider == null) {
      debugPrint('[WindowBoundsService] init skipped; provider unavailable');
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
    if (!_isSupported || _provider == null) {
      return;
    }
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _debounce = null;
    _provider?.dispose();
    _provider = null;
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
    final rect = _provider?.readBounds();
    if (rect != null) {
      _pendingBounds = rect;
      _lastKnownBounds = rect;
      debugPrint('[WindowBoundsService] cached: $rect');
    }
  }

  void _scheduleBoundsPersist() {
    if (!_isSupported || _provider == null) {
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
        final success = _provider?.applyBounds(desired) ?? false;
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

  String _resolveConfigPath() {
    final baseDir = Directory.current.path;
    return p.join(baseDir, _configFileName);
  }
}
