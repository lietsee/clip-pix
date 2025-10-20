import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:logging/logging.dart';

import '../data/models/image_source_type.dart';
import 'image_saver.dart';

typedef ImageCapturedCallback = Future<void> Function(
  Uint8List imageData, {
  String? source,
  ImageSourceType sourceType,
});

typedef UrlCapturedCallback = Future<void> Function(String url);

enum ClipboardMonitorMode { hook, polling }

enum _ClipboardEventType { image, url }

class _ClipboardEvent {
  _ClipboardEvent.image({
    required this.timestamp,
    required this.imageData,
    this.source,
    required this.sourceType,
  })  : type = _ClipboardEventType.image,
        url = null;

  _ClipboardEvent.url({
    required this.timestamp,
    required this.url,
  })  : type = _ClipboardEventType.url,
        imageData = null,
        source = null,
        sourceType = ImageSourceType.web;

  final DateTime timestamp;
  final _ClipboardEventType type;
  final Uint8List? imageData;
  final String? source;
  final ImageSourceType sourceType;
  final String? url;
}

abstract class ClipboardMonitorGuard {
  void setGuardToken(String token, Duration ttl);
  void clearGuardToken();
}

class ClipboardMonitor implements ClipboardMonitorGuard {
  ClipboardMonitor({
    required Directory? Function() getSelectedFolder,
    required ImageCapturedCallback onImageCaptured,
    required UrlCapturedCallback onUrlCaptured,
    Logger? logger,
    Duration duplicateWindow = const Duration(seconds: 2),
    Duration queueResumeDelay = const Duration(milliseconds: 150),
    int maxQueueSize = 10,
  })  : _getSelectedFolder = getSelectedFolder,
        _onImageCaptured = onImageCaptured,
        _onUrlCaptured = onUrlCaptured,
        _logger = logger ?? Logger('ClipboardMonitor'),
        _duplicateWindow = duplicateWindow,
        _queueResumeDelay = queueResumeDelay,
        _maxQueueSize = maxQueueSize;

  final Directory? Function() _getSelectedFolder;
  final ImageCapturedCallback _onImageCaptured;
  final UrlCapturedCallback _onUrlCaptured;
  final Logger _logger;
  final Duration _duplicateWindow;
  final Duration _queueResumeDelay;
  final int _maxQueueSize;

  ClipboardMonitorMode _mode = ClipboardMonitorMode.hook;
  bool _isRunning = false;
  bool _isProcessing = false;
  bool _isImageSaverBusy = false;
  final Queue<_ClipboardEvent> _eventQueue = Queue<_ClipboardEvent>();
  final Map<String, DateTime> _recentHashes = <String, DateTime>{};

  String? _guardToken;
  DateTime? _guardExpiry;

  Timer? _pollingTimer;
  String? _lastPolledTextSignature;

  ClipboardMonitorMode get mode => _mode;

  Future<void> start() async {
    if (_isRunning) {
      return;
    }
    final folder = _getSelectedFolder();
    if (folder == null) {
      _logger.info('Clipboard monitor start skipped: no selected folder');
      return;
    }
    _isRunning = true;
    await _initializeHook();
  }

  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }
    _isRunning = false;
    _disposeHook();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _eventQueue.clear();
    _lastPolledTextSignature = null;
  }

  Future<void> onFolderChanged(Directory? directory) async {
    if (directory == null) {
      await stop();
      return;
    }
    if (_isRunning) {
      await stop();
    }
    await start();
  }

  void onSaveCompleted(SaveResult result) {
    _isImageSaverBusy = false;
    _scheduleQueueDrain();
  }

  @override
  void setGuardToken(String token, Duration ttl) {
    _guardToken = token;
    _guardExpiry = DateTime.now().add(ttl);
  }

  @override
  void clearGuardToken() {
    _guardToken = null;
    _guardExpiry = null;
  }

  bool get _isGuardActive {
    final expiry = _guardExpiry;
    final token = _guardToken;
    if (expiry == null || token == null) {
      return false;
    }
    if (DateTime.now().isAfter(expiry)) {
      clearGuardToken();
      return false;
    }
    return true;
  }

  Future<void> handleClipboardImage(
    Uint8List imageData, {
    String? source,
    ImageSourceType sourceType = ImageSourceType.local,
  }) async {
    if (!_isRunning) {
      return;
    }
    if (_isGuardActive) {
      _logger.fine('Clipboard image ignored due to guard token $_guardToken');
      return;
    }

    final hash = _hashBytes(imageData);
    if (_isDuplicate(hash)) {
      _logger.fine('Duplicate clipboard image ignored');
      return;
    }

    _recentHashes[hash] = DateTime.now();
    _enqueueEvent(
      _ClipboardEvent.image(
        timestamp: DateTime.now(),
        imageData: imageData,
        source: source,
        sourceType: sourceType,
      ),
    );
  }

  Future<void> handleClipboardUrl(String url) async {
    if (!_isRunning) {
      return;
    }
    if (_isGuardActive) {
      _logger.fine('Clipboard URL ignored due to guard token $_guardToken');
      return;
    }

    final normalized = _normalizeUrl(url);
    if (normalized == null) {
      _logger.fine('Clipboard text is not a valid URL: $url');
      return;
    }

    final hash = normalized;
    if (_isDuplicate(hash)) {
      _logger.fine('Duplicate clipboard URL ignored');
      return;
    }

    _recentHashes[hash] = DateTime.now();
    _enqueueEvent(
      _ClipboardEvent.url(
        timestamp: DateTime.now(),
        url: normalized,
      ),
    );
  }

  void dispose() {
    stop();
  }

  Future<void> _initializeHook() async {
    _logger.info('Clipboard hook not yet implemented; using polling fallback');
    _activatePollingFallback();
  }

  void _disposeHook() {
    // Hook resources will be released once implemented.
  }

  void _activatePollingFallback() {
    _mode = ClipboardMonitorMode.polling;
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollClipboard(),
    );
  }

  void _enqueueEvent(_ClipboardEvent event) {
    if (_eventQueue.length >= _maxQueueSize) {
      final dropped = _eventQueue.removeFirst();
      _logger
          .warning('queue_drop oldest=${dropped.timestamp.toIso8601String()}');
    }
    _eventQueue.add(event);
    _scheduleQueueDrain();
  }

  void _scheduleQueueDrain() {
    if (_isProcessing || _isImageSaverBusy) {
      return;
    }
    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isProcessing || _isImageSaverBusy) {
      return;
    }
    if (_eventQueue.isEmpty) {
      return;
    }

    _isProcessing = true;
    while (_eventQueue.isNotEmpty && !_isImageSaverBusy) {
      final event = _eventQueue.removeFirst();
      switch (event.type) {
        case _ClipboardEventType.image:
          final imageData = event.imageData!;
          _isImageSaverBusy = true;
          await _onImageCaptured(
            imageData,
            source: event.source,
            sourceType: event.sourceType,
          );
          break;
        case _ClipboardEventType.url:
          final url = event.url!;
          _isImageSaverBusy = true;
          await _onUrlCaptured(url);
          if (_isImageSaverBusy) {
            _isImageSaverBusy = false;
          }
          break;
      }
    }
    _isProcessing = false;

    if (_eventQueue.isNotEmpty && !_isImageSaverBusy) {
      await Future<void>.delayed(_queueResumeDelay);
      _processQueue();
    }
  }

  Future<void> _pollClipboard() async {
    if (!_isRunning) {
      return;
    }
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text;
      if (text != null && text.isNotEmpty) {
        if (text != _lastPolledTextSignature) {
          _lastPolledTextSignature = text;
          await handleClipboardUrl(text);
        }
      }
    } catch (error, stackTrace) {
      _logger.fine('Clipboard poll failed', error, stackTrace);
    }
  }

  bool _isDuplicate(String hash) {
    final now = DateTime.now();
    _recentHashes.removeWhere(
      (key, value) => now.difference(value) > _duplicateWindow,
    );
    return _recentHashes.containsKey(hash);
  }

  String _hashBytes(Uint8List bytes) {
    final digest = sha1.convert(bytes);
    return digest.toString();
  }

  String? _normalizeUrl(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return null;
    }
    return uri.toString();
  }
}
