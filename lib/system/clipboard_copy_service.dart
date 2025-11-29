import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:logging/logging.dart';

import '../data/models/image_item.dart';
import '../data/models/text_content_item.dart';
import 'clipboard/clipboard_service.dart';
import 'clipboard_monitor.dart';

class ClipboardCopyService {
  ClipboardCopyService({
    Duration guardTtl = const Duration(seconds: 2),
    Duration guardClearDelay = const Duration(seconds: 1),
    ClipboardWriter? writer,
    Logger? logger,
  })  : _guardTtl = guardTtl,
        _guardClearDelay = guardClearDelay,
        _writer = writer ?? ClipboardServiceFactory.createWriter(),
        _logger = logger ?? Logger('ClipboardCopyService');

  final Duration _guardTtl;
  final Duration _guardClearDelay;
  final ClipboardWriter _writer;
  final Logger _logger;

  ClipboardMonitorGuard? _guard;
  final Queue<ImageItem> _queue = Queue<ImageItem>();
  bool _isProcessing = false;
  Timer? _guardClearTimer;

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
      await _writer.writeText(text);
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
      await _writer.writeImage(bytes);
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
      _logger
          .finest('Clipboard guard not registered (expected in preview mode)');
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

  String _generateToken() {
    final random = Random.secure();
    final values = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(values);
  }
}
