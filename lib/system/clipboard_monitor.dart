import 'dart:async';
import 'dart:collection';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:win32/win32.dart';

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

const int _eventSystemClipboard = 0x00000006;
const int _wineventOutOfContext = 0x0000;
const int _wineventSkipOwnProcess = 0x0002;

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
  Timer? _sequenceWatcher;
  int? _lastSequenceNumber;
  int? _baselineSequenceNumber;
  bool _hasSequenceAdvanced = false;
  bool _sequenceCheckInProgress = false;
  final Set<String> _sessionHashes = <String>{};
  _Win32ClipboardHook? _hook;
  int? _pngClipboardFormat;

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
    _baselineSequenceNumber = GetClipboardSequenceNumber();
    _hasSequenceAdvanced = false;
    _startSequenceWatcher();
    await _initializeHook();
  }

  Future<void> stop() async {
    if (!_isRunning) {
      return;
    }
    _isRunning = false;
    await _disposeHook();
    _pollingTimer?.cancel();
    _pollingTimer = null;
    _stopSequenceWatcher();
    _eventQueue.clear();
    _lastSequenceNumber = null;
    _baselineSequenceNumber = null;
    _hasSequenceAdvanced = false;
    _sessionHashes.clear();
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

    if (_sessionHashes.contains(hash)) {
      _logger.fine('Clipboard image ignored due to session duplicate hash');
      return;
    }
    _recentHashes[hash] = DateTime.now();
    _sessionHashes.add(hash);
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
    if (!Platform.isWindows) {
      _logger.info(
          'Clipboard hook unsupported on ${Platform.operatingSystem}; using polling');
      _activatePollingFallback();
      return;
    }

    _hook ??= _Win32ClipboardHook(_handleHookEvent, _logger);
    final success = await _hook!.start();
    if (success) {
      _pollingTimer?.cancel();
      _pollingTimer = null;
      _mode = ClipboardMonitorMode.hook;
      _logger.info('Clipboard hook initialized');
    } else {
      _logger.warning(
          'Clipboard hook initialization failed, falling back to polling');
      await _hook?.stop();
      _hook = null;
      _activatePollingFallback();
    }
  }

  Future<void> _disposeHook() async {
    await _hook?.stop();
    _hook = null;
  }

  void _activatePollingFallback() {
    _mode = ClipboardMonitorMode.polling;
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _pollClipboard(),
    );
  }

  Future<void> _handleHookEvent() async {
    await _processClipboardSnapshot();
  }

  Future<void> _pollClipboard() async {
    await _processClipboardSnapshot();
  }

  Future<void> _processClipboardSnapshot() async {
    if (!_isRunning) {
      return;
    }
    if (_sequenceCheckInProgress) {
      return;
    }
    _sequenceCheckInProgress = true;
    try {
      final currentSequence = GetClipboardSequenceNumber();
      if (!_hasSequenceAdvanced) {
        if (_baselineSequenceNumber == null) {
          _baselineSequenceNumber = currentSequence;
          _logger.fine('Clipboard baseline sequence set to $currentSequence');
          return;
        }
        if (currentSequence == _baselineSequenceNumber) {
          _logger.fine('Skipping clipboard snapshot (baseline sequence)');
          return;
        }
        _hasSequenceAdvanced = true;
      }
      if (currentSequence != 0) {
        _lastSequenceNumber = currentSequence;
      }
      final snapshot = _readClipboardSnapshot();
      if (snapshot == null) {
        return;
      }
      if (snapshot.imageData != null) {
        await handleClipboardImage(snapshot.imageData!,
            sourceType: snapshot.sourceType);
        return;
      }
      if (snapshot.text != null) {
        await handleClipboardUrl(snapshot.text!);
      }
    } catch (error, stackTrace) {
      _logger.warning(
          'Failed to process clipboard snapshot', error, stackTrace);
    } finally {
      _sequenceCheckInProgress = false;
    }
  }

  _ClipboardSnapshot? _readClipboardSnapshot() {
    final open = OpenClipboard(NULL);
    if (open == 0) {
      final code = GetLastError();
      _logger.fine('OpenClipboard failed with code $code');
      return null;
    }
    try {
      _logAvailableFormats();
      final dibV5Image = _readDibV5FromClipboardLocked();
      if (dibV5Image != null) {
        return _ClipboardSnapshot(
            imageData: dibV5Image, sourceType: ImageSourceType.local);
      }
      final image = _readPngFromClipboardLocked();
      if (image != null) {
        return _ClipboardSnapshot(
            imageData: image, sourceType: ImageSourceType.local);
      }
      final dibImage = _readDibFromClipboardLocked();
      if (dibImage != null) {
        return _ClipboardSnapshot(
            imageData: dibImage, sourceType: ImageSourceType.local);
      }
      final text = _readUnicodeTextFromClipboardLocked();
      if (text != null && text.isNotEmpty) {
        return _ClipboardSnapshot(text: text);
      }
      return null;
    } finally {
      CloseClipboard();
    }
  }

  void _logAvailableFormats() {
    var format = EnumClipboardFormats(0);
    if (format == 0) {
      _logger.fine('Clipboard contains no additional formats');
      return;
    }
    final formats = <String>[];
    const known = {
      CF_BITMAP: 'CF_BITMAP',
      CF_DIB: 'CF_DIB',
      CF_DIBV5: 'CF_DIBV5',
      CF_UNICODETEXT: 'CF_UNICODETEXT',
    };
    while (format != 0) {
      final name = known[format] ?? format.toString();
      formats.add(name);
      format = EnumClipboardFormats(format);
    }
    _logger.fine('Clipboard formats enumerated: ${formats.join(', ')}');
  }

  Uint8List? _readDibV5FromClipboardLocked() {
    final handleValue = GetClipboardData(CF_DIBV5);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    try {
      final size = GlobalSize(handle);
      if (size <= 0) {
        return null;
      }
      final data = rawPointer.cast<ffi.Uint8>().asTypedList(size);
      return _convertDibV5ToPng(data);
    } finally {
      GlobalUnlock(handle);
    }
  }

  Uint8List? _readPngFromClipboardLocked() {
    final format = _ensurePngFormat();
    if (format == 0) {
      return null;
    }
    final handleValue = GetClipboardData(format);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    final size = GlobalSize(handle);
    if (size <= 0) {
      GlobalUnlock(handle);
      return null;
    }
    final pointer = rawPointer.cast<ffi.Uint8>();
    final data = pointer.asTypedList(size);
    final bytes = Uint8List.fromList(data);
    GlobalUnlock(handle);
    return bytes;
  }

  Uint8List? _readDibFromClipboardLocked() {
    final handleValue = GetClipboardData(CF_DIB);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    try {
      final size = GlobalSize(handle);
      if (size <= 0) {
        return null;
      }
      final data = rawPointer.cast<ffi.Uint8>().asTypedList(size);
      final bytes = Uint8List.fromList(data);
      return _convertDibToPng(bytes);
    } finally {
      GlobalUnlock(handle);
    }
  }

  String? _readUnicodeTextFromClipboardLocked() {
    final handleValue = GetClipboardData(CF_UNICODETEXT);
    if (handleValue == 0) {
      return null;
    }
    final handle = ffi.Pointer<ffi.Void>.fromAddress(handleValue);
    final rawPointer = GlobalLock(handle);
    if (rawPointer.address == 0) {
      return null;
    }
    final pointer = rawPointer.cast<Utf16>();
    final text = pointer.toDartString();
    GlobalUnlock(handle);
    return text;
  }

  Uint8List? _convertDibV5ToPng(Uint8List dibBytes) {
    const int biAlphabitfields = 6;
    if (dibBytes.length < 124) {
      return null;
    }
    final byteData = ByteData.view(dibBytes.buffer);
    final headerSize = byteData.getUint32(0, Endian.little);
    if (headerSize < 124 || headerSize > dibBytes.length) {
      return null;
    }
    final width = byteData.getInt32(4, Endian.little);
    final heightRaw = byteData.getInt32(8, Endian.little);
    final planes = byteData.getUint16(12, Endian.little);
    final bitCount = byteData.getUint16(14, Endian.little);
    final compression = byteData.getUint32(16, Endian.little);
    var imageSize = byteData.getUint32(20, Endian.little);
    final redMask = byteData.getUint32(40, Endian.little);
    final greenMask = byteData.getUint32(44, Endian.little);
    final blueMask = byteData.getUint32(48, Endian.little);
    final alphaMask = byteData.getUint32(52, Endian.little);
    final pixelDataOffset = byteData.getUint32(96, Endian.little);

    if (planes != 1) {
      return null;
    }
    if (compression != biAlphabitfields) {
      return null;
    }
    if (bitCount != 32) {
      return null;
    }

    final widthAbs = width.abs();
    final heightAbs = heightRaw.abs();
    if (widthAbs == 0 || heightAbs == 0) {
      return null;
    }

    final stride = widthAbs * 4;
    if (imageSize == 0) {
      imageSize = stride * heightAbs;
    }
    final pixelOffset = headerSize + pixelDataOffset;
    if (pixelOffset + imageSize > dibBytes.length) {
      return null;
    }

    final pixels = dibBytes.sublist(pixelOffset, pixelOffset + imageSize);
    final output = Uint8List(widthAbs * heightAbs * 4);
    final bottomUp = heightRaw > 0;

    for (var y = 0; y < heightAbs; y++) {
      final srcY = bottomUp ? heightAbs - 1 - y : y;
      final srcRowStart = srcY * stride;
      final dstRowStart = y * widthAbs * 4;
      for (var x = 0; x < widthAbs; x++) {
        final srcIndex = srcRowStart + x * 4;
        if (srcIndex + 4 > pixels.length) {
          return null;
        }
        final pixel = ByteData.sublistView(pixels, srcIndex, srcIndex + 4)
            .getUint32(0, Endian.little);
        final red = _applyMask(pixel, redMask);
        final green = _applyMask(pixel, greenMask);
        final blue = _applyMask(pixel, blueMask);
        final alpha = alphaMask == 0 ? 0xFF : _applyMask(pixel, alphaMask);
        final dstIndex = dstRowStart + x * 4;
        output[dstIndex] = red;
        output[dstIndex + 1] = green;
        output[dstIndex + 2] = blue;
        output[dstIndex + 3] = alpha;
      }
    }

    final image = img.Image.fromBytes(
      width: widthAbs,
      height: heightAbs,
      bytes: output.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  int _applyMask(int pixel, int mask) {
    if (mask == 0) {
      return 0;
    }
    var shift = 0;
    while ((mask & 1) == 0) {
      mask >>= 1;
      shift++;
    }
    final component = (pixel & mask) >> shift;
    final bits = _maskBitCount(mask);
    if (bits >= 8) {
      return component & 0xFF;
    }
    return ((component * 255) ~/ ((1 << bits) - 1)) & 0xFF;
  }

  int _maskBitCount(int mask) {
    var count = 0;
    while (mask != 0) {
      if ((mask & 1) == 1) {
        count++;
      }
      mask >>= 1;
    }
    return count;
  }

  Uint8List? _convertDibToPng(Uint8List dibBytes) {
    const int biRgb = 0;
    const int biBitfields = 3;

    if (dibBytes.length < 40) {
      return null;
    }
    final byteData = ByteData.view(dibBytes.buffer);
    final headerSize = byteData.getUint32(0, Endian.little);
    if (headerSize < 40 || headerSize > dibBytes.length) {
      return null;
    }

    final width = byteData.getInt32(4, Endian.little);
    final heightRaw = byteData.getInt32(8, Endian.little);
    final planes = byteData.getUint16(12, Endian.little);
    final bitCount = byteData.getUint16(14, Endian.little);
    final compression = byteData.getUint32(16, Endian.little);
    var imageSize = byteData.getUint32(20, Endian.little);

    if (planes != 1) {
      return null;
    }
    if (bitCount != 24 && bitCount != 32) {
      return null;
    }
    if (compression != biRgb && compression != biBitfields) {
      return null;
    }

    final widthAbs = width.abs();
    final heightAbs = heightRaw.abs();
    if (widthAbs == 0 || heightAbs == 0) {
      return null;
    }

    final bytesPerPixel = bitCount ~/ 8;
    final stride = ((widthAbs * bytesPerPixel + 3) ~/ 4) * 4;
    final pixelOffset = headerSize;
    if (imageSize == 0) {
      imageSize = stride * heightAbs;
    }
    if (pixelOffset + imageSize > dibBytes.length) {
      return null;
    }

    final pixels = dibBytes.sublist(pixelOffset, pixelOffset + imageSize);
    final output = Uint8List(widthAbs * heightAbs * 4);
    final bottomUp = heightRaw > 0;

    for (var y = 0; y < heightAbs; y++) {
      final srcY = bottomUp ? heightAbs - 1 - y : y;
      final srcRowStart = srcY * stride;
      final dstRowStart = y * widthAbs * 4;
      for (var x = 0; x < widthAbs; x++) {
        final srcIndex = srcRowStart + x * bytesPerPixel;
        if (srcIndex + bytesPerPixel > pixels.length) {
          return null;
        }
        final blue = pixels[srcIndex];
        final green = pixels[srcIndex + 1];
        final red = pixels[srcIndex + 2];
        final alpha = bytesPerPixel == 4 ? pixels[srcIndex + 3] : 0xFF;
        final dstIndex = dstRowStart + x * 4;
        output[dstIndex] = red;
        output[dstIndex + 1] = green;
        output[dstIndex + 2] = blue;
        output[dstIndex + 3] = alpha;
      }
    }

    final image = img.Image.fromBytes(
      width: widthAbs,
      height: heightAbs,
      bytes: output.buffer,
      numChannels: 4,
    );
    return Uint8List.fromList(img.encodePng(image));
  }

  int _ensurePngFormat() {
    final cached = _pngClipboardFormat;
    if (cached != null) {
      return cached;
    }
    final name = 'PNG'.toNativeUtf16();
    try {
      final format = RegisterClipboardFormat(name);
      if (format == 0) {
        final code = GetLastError();
        _logger.fine('RegisterClipboardFormat failed with code $code');
      } else {
        _pngClipboardFormat = format;
      }
      return format;
    } finally {
      calloc.free(name);
    }
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

  void _startSequenceWatcher() {
    _sequenceWatcher ??= Timer.periodic(
      const Duration(milliseconds: 400),
      (_) => _checkClipboardSequence(),
    );
  }

  void _stopSequenceWatcher() {
    _sequenceWatcher?.cancel();
    _sequenceWatcher = null;
  }

  Future<void> _checkClipboardSequence() async {
    if (!_isRunning) {
      return;
    }
    final sequence = GetClipboardSequenceNumber();
    if (sequence == 0) {
      return;
    }
    if (_baselineSequenceNumber != null &&
        !_hasSequenceAdvanced &&
        sequence == _baselineSequenceNumber) {
      return;
    }
    if (_lastSequenceNumber != null && _lastSequenceNumber == sequence) {
      return;
    }
    _lastSequenceNumber = sequence;
    if (_baselineSequenceNumber != null &&
        sequence != _baselineSequenceNumber) {
      _hasSequenceAdvanced = true;
    }
    _logger.fine('Clipboard sequence changed: $sequence');
    await _processClipboardSnapshot();
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

class _ClipboardSnapshot {
  const _ClipboardSnapshot(
      {this.imageData, this.text, this.sourceType = ImageSourceType.local});

  final Uint8List? imageData;
  final String? text;
  final ImageSourceType sourceType;
}

class _Win32ClipboardHook {
  _Win32ClipboardHook(this._onEvent, this._logger);

  final FutureOr<void> Function() _onEvent;
  final Logger _logger;

  Isolate? _isolate;
  SendPort? _controlPort;
  StreamSubscription<dynamic>? _subscription;
  Completer<void>? _stoppedCompleter;

  Future<bool> start() async {
    if (_isolate != null) {
      return true;
    }

    final readyCompleter = Completer<bool>();
    final stoppedCompleter = Completer<void>();
    _stoppedCompleter = stoppedCompleter;

    final eventPort = ReceivePort();
    _subscription = eventPort.listen((message) {
      if (message is SendPort) {
        _controlPort = message;
        return;
      }
      if (message is List && message.isNotEmpty) {
        final type = message[0];
        switch (type) {
          case 'ready':
            if (!readyCompleter.isCompleted) {
              readyCompleter
                  .complete((message.length > 1 ? message[1] : false) as bool);
            }
            break;
          case 'event':
            Future.microtask(() => _onEvent());
            break;
          case 'error':
            final code = message.length > 1 ? message[1] : null;
            _logger.warning('Clipboard hook error code=$code');
            break;
          case 'stopped':
            if (!stoppedCompleter.isCompleted) {
              stoppedCompleter.complete();
            }
            break;
        }
      }
    });

    _isolate = await Isolate.spawn<_HookInitMessage>(
      _clipboardHookIsolate,
      _HookInitMessage(eventPort.sendPort),
      debugName: 'clipboard_hook',
    );

    final success = await readyCompleter.future;
    if (!success) {
      await stop();
    }
    return success;
  }

  Future<void> stop() async {
    final control = _controlPort;
    _controlPort = null;
    final stopped = _stoppedCompleter;

    if (control != null) {
      control.send('stop');
      if (stopped != null && !stopped.isCompleted) {
        try {
          await stopped.future.timeout(const Duration(seconds: 1));
        } catch (_) {}
      }
    }

    await _subscription?.cancel();
    _subscription = null;
    _stoppedCompleter = null;

    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
  }
}

class _HookInitMessage {
  const _HookInitMessage(this.mainPort);

  final SendPort mainPort;
}

class _HookState {
  _HookState({
    required this.mainPort,
    required this.unhook,
  });

  final SendPort mainPort;
  final _UnhookWinEventDart unhook;
  ffi.Pointer<ffi.Void> hookHandle = ffi.Pointer.fromAddress(0);

  static _HookState? instance;
}

typedef _SetWinEventHookNative = ffi.Pointer<ffi.Void> Function(
  ffi.Uint32 eventMin,
  ffi.Uint32 eventMax,
  ffi.Pointer<ffi.Void> hmodWinEventProc,
  ffi.Pointer<ffi.NativeFunction<_WinEventProcNative>> lpfnWinEventProc,
  ffi.Uint32 idProcess,
  ffi.Uint32 idThread,
  ffi.Uint32 dwFlags,
);

typedef _SetWinEventHookDart = ffi.Pointer<ffi.Void> Function(
  int eventMin,
  int eventMax,
  ffi.Pointer<ffi.Void> hmodWinEventProc,
  ffi.Pointer<ffi.NativeFunction<_WinEventProcNative>> lpfnWinEventProc,
  int idProcess,
  int idThread,
  int dwFlags,
);

typedef _UnhookWinEventNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void> hWinEventHook);
typedef _UnhookWinEventDart = int Function(ffi.Pointer<ffi.Void> hWinEventHook);

typedef _WinEventProcNative = ffi.Void Function(
  ffi.Pointer<ffi.Void> hWinEventHook,
  ffi.Uint32 event,
  ffi.Pointer<ffi.Void> hwnd,
  ffi.Int32 idObject,
  ffi.Int32 idChild,
  ffi.Uint32 dwEventThread,
  ffi.Uint32 dwmsEventTime,
);

final ffi.Pointer<ffi.NativeFunction<_WinEventProcNative>> _callbackPointer =
    ffi.Pointer.fromFunction<_WinEventProcNative>(_winEventProc);

void _clipboardHookIsolate(_HookInitMessage message) {
  final mainPort = message.mainPort;
  final controlPort = ReceivePort();
  mainPort.send(controlPort.sendPort);

  final user32 = ffi.DynamicLibrary.open('user32.dll');
  final setWinEventHook =
      user32.lookupFunction<_SetWinEventHookNative, _SetWinEventHookDart>(
    'SetWinEventHook',
  );
  final unhookWinEvent =
      user32.lookupFunction<_UnhookWinEventNative, _UnhookWinEventDart>(
    'UnhookWinEvent',
  );

  _HookState.instance = _HookState(mainPort: mainPort, unhook: unhookWinEvent);

  final hookHandle = setWinEventHook(
    _eventSystemClipboard,
    _eventSystemClipboard,
    ffi.Pointer.fromAddress(0),
    _callbackPointer,
    0,
    0,
    _wineventOutOfContext | _wineventSkipOwnProcess,
  );

  if (hookHandle.address == 0) {
    final error = GetLastError();
    mainPort.send(['ready', false, error]);
    controlPort.close();
    _HookState.instance = null;
    return;
  }

  _HookState.instance!.hookHandle = hookHandle;
  mainPort.send(['ready', true]);

  controlPort.listen((message) {
    if (message == 'stop') {
      try {
        final handle = _HookState.instance?.hookHandle;
        if (handle != null && handle.address != 0) {
          _HookState.instance?.unhook(handle);
        }
      } finally {
        mainPort.send(['stopped']);
        controlPort.close();
        _HookState.instance = null;
      }
    }
  });
}

void _winEventProc(
  ffi.Pointer<ffi.Void> hWinEventHook,
  int event,
  ffi.Pointer<ffi.Void> hwnd,
  int idObject,
  int idChild,
  int dwEventThread,
  int dwmsEventTime,
) {
  if (event == _eventSystemClipboard) {
    _HookState.instance?.mainPort.send(['event']);
  }
}
